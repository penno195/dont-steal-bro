--!strict
-- Covers the pure half of the UI foundation (P6-1): Tokens.luau's
-- colour claims, ColorVision.luau's maths, and Layout.luau's scale,
-- inset and thumb-zone logic. Theme.luau, UIScaleController and the
-- harness screen touch Color3/GuiService and are checked on device via
-- the harness (docs/ui-foundation.md), the same split every other spec
-- in this suite uses.
--
-- The case that matters most is the Steal/Share pair: it has to stay
-- distinguishable under every simulated colour-vision deficiency, and
-- the red/green control below proves the check has teeth.

local ColorVision = require("../src/client/UI/ColorVision")
local Layout = require("../src/client/UI/Layout")
local TestRunner = require("./TestRunner")
local Tokens = require("../src/client/UI/Tokens")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function hex(name: string): ColorVision.RGB
	return ColorVision.fromHex((Tokens.color :: any)[name])
end

describe("ColorVision", function()
	it("round-trips hex", function()
		expect(ColorVision.toHex(ColorVision.fromHex("#3a5bd9"))):toBe("#3A5BD9")
		expect(ColorVision.toHex(ColorVision.fromHex("FFB020"))):toBe("#FFB020")
	end)

	it("rejects malformed hex", function()
		expect(pcall(ColorVision.fromHex, "#FFF")):toBeFalsy()
		expect(pcall(ColorVision.fromHex, "#GGGGGG")):toBeFalsy()
	end)

	it("matches the WCAG contrast endpoints", function()
		local black, white = ColorVision.fromHex("#000000"), ColorVision.fromHex("#FFFFFF")
		expect(ColorVision.contrast(black, white)):toBeCloseTo(21, 1e-9)
		expect(ColorVision.contrast(white, black)):toBeCloseTo(21, 1e-9)
		expect(ColorVision.contrast(white, white)):toBeCloseTo(1, 1e-9)
	end)

	it("leaves greys unchanged under every simulation", function()
		-- Machado's rows each sum to ~1, so a neutral stays neutral; a
		-- regression here means a mistyped matrix entry.
		local grey = ColorVision.fromHex("#808080")
		for _, deficiency in ColorVision.DEFICIENCIES do
			expect(ColorVision.distance(grey, ColorVision.simulate(grey, deficiency))):toBeCloseTo(0, 0.01)
		end
	end)

	it("collapses a red/green pair under deuteranopia (control)", function()
		-- Proves the decision-pair test below can fail: a typical
		-- red/green pair falls far under the floor.
		local red, green = ColorVision.fromHex("#D93A3A"), ColorVision.fromHex("#3AA35A")
		expect(ColorVision.distance(red, green) > Tokens.contrast.decisionPairMinDistance):toBeTruthy()
		expect(ColorVision.simulatedDistance(red, green, "deuteranopia") < Tokens.contrast.decisionPairMinDistance):toBeTruthy()
	end)
end)

describe("Tokens: the Steal/Share pair", function()
	it("stays distinct under every colour-vision deficiency", function()
		local steal, share = hex("steal"), hex("share")
		for _, deficiency in ColorVision.DEFICIENCIES do
			local d = ColorVision.simulatedDistance(steal, share, deficiency)
			assert(
				d >= Tokens.contrast.decisionPairMinDistance,
				string.format("steal/share only %.3f apart under %s", d, deficiency)
			)
		end
	end)

	it("differs in lightness alone (greyscale-legible)", function()
		expect(ColorVision.contrast(hex("steal"), hex("share")) >= Tokens.contrast.decisionPairMinLuminanceRatio):toBeTruthy()
	end)

	it("pairs each with a different shape and icon", function()
		expect(Tokens.decision.steal.shape ~= Tokens.decision.share.shape):toBeTruthy()
		expect(Tokens.decision.steal.icon ~= Tokens.decision.share.icon):toBeTruthy()
	end)

	it("keeps each button's label readable on its fill", function()
		for _, spec in Tokens.decision do
			local ratio = ColorVision.contrast(hex(spec.color), hex(spec.on))
			assert(ratio >= Tokens.contrast.textMin, string.format("%s label contrast %.2f", spec.label, ratio))
		end
	end)

	it("stands out from the background as a UI shape", function()
		for _, name in { "steal", "share" } do
			local ratio = ColorVision.contrast(hex(name), hex("background"))
			assert(ratio >= Tokens.contrast.nonTextMin, string.format("%s vs background %.2f", name, ratio))
		end
	end)
end)

describe("Tokens: text contrast", function()
	it("meets WCAG AA for ink on every surface", function()
		for _, surface in { "background", "surface", "surfaceRaised" } do
			for _, ink in { "ink", "inkMuted" } do
				local ratio = ColorVision.contrast(hex(ink), hex(surface))
				assert(ratio >= Tokens.contrast.textMin, string.format("%s on %s is %.2f", ink, surface, ratio))
			end
		end
	end)

	it("has every elevation surface defined as a colour", function()
		for _, level in Tokens.elevation do
			expect((Tokens.color :: any)[level.surface] ~= nil):toBeTruthy()
		end
	end)
end)

describe("Tokens: scales", function()
	it("keeps spacing on the 2/4-point grid", function()
		for name, px in Tokens.spacing do
			assert(px % 2 == 0, string.format("spacing.%s = %d is off-grid", name, px))
		end
	end)

	it("has every text style's floor below its size", function()
		for name, style in Tokens.type do
			assert(style.min > 0 and style.min <= style.size, string.format("type.%s min/size", name))
		end
	end)

	it("sizes the primary button above the touch minimum at scale 1", function()
		expect(Tokens.touch.primaryHeight >= Tokens.touch.minTargetPoints):toBeTruthy()
		expect(Tokens.touch.iconButton >= Tokens.touch.minTargetPoints):toBeTruthy()
	end)
end)

describe("Layout.computeScale", function()
	local config = Tokens.scale

	it("is 1 on the reference phone in either orientation", function()
		expect(Layout.computeScale(780, 360, config)):toBeCloseTo(1)
		expect(Layout.computeScale(360, 780, config)):toBeCloseTo(1)
	end)

	it("scales from the short axis", function()
		expect(Layout.computeScale(900, 540, config)):toBeCloseTo(1.5)
	end)

	it("clamps at both ends", function()
		expect(Layout.computeScale(500, 200, config)):toBeCloseTo(config.min)
		expect(Layout.computeScale(2560, 1440, config)):toBeCloseTo(config.max)
	end)

	it("falls back to the reference before the viewport is measured", function()
		expect(Layout.computeScale(0, 0, config)):toBeCloseTo(1)
	end)
end)

describe("Layout.insetRect and orientation", function()
	it("subtracts each inset", function()
		local r = Layout.insetRect(844, 390, 47, 58, 47, 21)
		expect(r.x):toBe(47)
		expect(r.y):toBe(58)
		expect(r.width):toBe(750)
		expect(r.height):toBe(311)
	end)

	it("never goes negative", function()
		local r = Layout.insetRect(10, 10, 20, 20, 0, 0)
		expect(r.width):toBe(0)
		expect(r.height):toBe(0)
	end)

	it("treats square as landscape", function()
		expect(Layout.orientationOf(500, 500)):toBe("Landscape")
		expect(Layout.orientationOf(390, 844)):toBe("Portrait")
	end)
end)

describe("Layout.minTouchRef", function()
	it("renders at the minimum after scaling", function()
		for _, scale in { 0.75, 1, 1.37, 2 } do
			local ref = Layout.minTouchRef(scale, 44)
			assert(ref * scale >= 44, string.format("scale %.2f -> %d ref px", scale, ref))
			assert((ref - 1) * scale < 44, "not the smallest size that works")
		end
	end)
end)

describe("Layout thumb zones", function()
	it("never places an action zone on a Roblox control", function()
		for orientation, zones in Layout.THUMB_ZONES do
			for _, zone in zones do
				if zone.kind == "Primary" or zone.kind == "Secondary" then
					-- A 1x1 usable rect keeps the fractions as-is.
					local unit = { x = 0, y = 0, width = 1, height = 1 }
					if orientation == "Portrait" then
						unit = { x = 0, y = 0, width = 1, height = 2 }
					end
					local r = zone.rect
					local abs = {
						x = r.x * unit.width,
						y = r.y * unit.height,
						width = r.width * unit.width,
						height = r.height * unit.height,
					}
					assert(
						not Layout.hitsReserved(abs, unit),
						string.format("%s %s zone overlaps a reserved control", orientation, zone.kind)
					)
				end
			end
		end
	end)

	it("keeps every zone inside the usable rect", function()
		for orientation, zones in Layout.THUMB_ZONES do
			for _, zone in zones do
				local r = zone.rect
				assert(
					r.x >= 0 and r.y >= 0 and r.x + r.width <= 1 + 1e-9 and r.y + r.height <= 1 + 1e-9,
					string.format("%s %s zone leaves the usable rect", orientation, zone.kind)
				)
			end
		end
	end)

	it("has at least one primary zone per orientation", function()
		for orientation, zones in Layout.THUMB_ZONES do
			local found = false
			for _, zone in zones do
				found = found or zone.kind == "Primary"
			end
			assert(found, orientation .. " has no Primary zone")
		end
	end)

	it("resolves fractions into absolute pixels within the usable rect", function()
		local zones = Layout.resolveZones({ x = 40, y = 20, width = 800, height = 400 })
		local info
		for _, zone in zones do
			if zone.kind == "Info" then
				info = zone.rect
			end
		end
		assert(info ~= nil, "no Info zone")
		expect(info.x):toBeCloseTo(40 + 0.2 * 800)
		expect(info.y):toBeCloseTo(20)
		expect(info.width):toBeCloseTo(0.6 * 800)
	end)

	it("flags a button placed on the jump button", function()
		local usable = { x = 0, y = 0, width = 800, height = 400 }
		expect(Layout.hitsReserved({ x = 720, y = 340, width = 50, height = 50 }, usable)):toBeTruthy()
		expect(Layout.hitsReserved({ x = 520, y = 300, width = 50, height = 50 }, usable)):toBeFalsy()
	end)
end)
