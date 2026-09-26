--!strict
-- Covers the pure half of the race HUD (P6-3). The screen itself is
-- reviewed on device through the RaceHUD preview (docs/race-hud.md).

local HudLogic = require("../src/client/UI/HudLogic")
local TestRunner = require("./TestRunner")
local Tokens = require("../src/client/UI/Tokens")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function field(counts: { number }): { HudLogic.ProgressEntry }
	local out = {}
	for i, count in counts do
		table.insert(out, { playerId = i, tasksCompleted = count })
	end
	return out
end

describe("HudLogic.standing", function()
	it("returns nil for someone not in the race", function()
		expect(HudLogic.standing(field({ 1, 2 }), 99, 3)):toBe(nil)
	end)

	it("places by count and measures the lead over 4th", function()
		-- player 1 on 5, then 4, 3, 2, 1, 0
		local s = HudLogic.standing(field({ 5, 4, 3, 2, 1, 0 }), 1, 3) :: HudLogic.Standing
		expect(s.place):toBe(1)
		expect(s.tied):toBe(false)
		expect(s.field):toBe(6)
		expect(s.gap):toBe(3)
		expect(s.qualifying):toBe(true)
	end)

	it("measures how far behind 3rd a non-qualifier is", function()
		local s = HudLogic.standing(field({ 1, 4, 3, 5, 2, 0 }), 1, 3) :: HudLogic.Standing
		expect(s.place):toBe(5)
		expect(s.gap):toBe(-2)
		expect(s.qualifying):toBe(false)
	end)

	it("shows a tie across the line as a shared place with a zero gap", function()
		-- players 3 and 4 are both on 2, straddling the line
		local s = HudLogic.standing(field({ 5, 4, 2, 2, 1, 0 }), 3, 3) :: HudLogic.Standing
		expect(s.place):toBe(3)
		expect(s.tied):toBe(true)
		expect(s.gap):toBe(0)
		expect(s.qualifying):toBe(true)
		local other = HudLogic.standing(field({ 5, 4, 2, 2, 1, 0 }), 4, 3) :: HudLogic.Standing
		expect(other.place):toBe(3)
	end)

	it("has no line when the field is no bigger than the qualifier count", function()
		local s = HudLogic.standing(field({ 0, 2, 1 }), 1, 3) :: HudLogic.Standing
		expect(s.place):toBe(3)
		expect(s.gap):toBe(nil)
		expect(HudLogic.lineState(s)):toBe("none")
	end)
end)

describe("HudLogic labels", function()
	it("suffixes places, teens included", function()
		expect(HudLogic.placeLabel(1, false)):toBe("1st")
		expect(HudLogic.placeLabel(2, false)):toBe("2nd")
		expect(HudLogic.placeLabel(3, true)):toBe("=3rd")
		expect(HudLogic.placeLabel(4, false)):toBe("4th")
		expect(HudLogic.placeLabel(11, false)):toBe("11th")
		expect(HudLogic.placeLabel(12, false)):toBe("12th")
		expect(HudLogic.placeLabel(13, false)):toBe("13th")
		expect(HudLogic.placeLabel(21, false)):toBe("21st")
	end)

	it("signs the gap with a true minus", function()
		expect(HudLogic.gapLabel(2)):toBe("+2")
		expect(HudLogic.gapLabel(-1)):toBe("\u{2212}1")
		expect(HudLogic.gapLabel(0)):toBe("0")
		expect(HudLogic.gapLabel(nil)):toBe("")
	end)

	it("classifies the line state", function()
		local function state(counts: { number }, id: number)
			return HudLogic.lineState(HudLogic.standing(field(counts), id, 3))
		end
		expect(state({ 5, 4, 3, 2, 1, 0 }, 1)):toBe("safe")
		expect(state({ 5, 4, 2, 2, 1, 0 }, 3)):toBe("edge")
		expect(state({ 5, 4, 3, 2, 1, 0 }, 4)):toBe("out")
		expect(HudLogic.lineState(nil)):toBe("none")
	end)

	it("gives every line state a distinct colour-blind word", function()
		local seen: { [string]: boolean } = {}
		for _, s in { "safe", "edge", "out" } :: { HudLogic.LineState } do
			local word = HudLogic.lineWord(s)
			expect(#word > 0):toBe(true)
			expect(seen[word]):toBe(nil)
			seen[word] = true
		end
		expect(HudLogic.lineWord("none")):toBe("")
	end)
end)

describe("HudLogic time", function()
	it("rounds seconds left up and never goes negative", function()
		expect(HudLogic.wholeSecondsLeft(10, 9.01)):toBe(1)
		expect(HudLogic.wholeSecondsLeft(10, 8)):toBe(2)
		expect(HudLogic.wholeSecondsLeft(10, 10)):toBe(0)
		expect(HudLogic.wholeSecondsLeft(10, 12)):toBe(0)
	end)

	it("quantizes down to the step", function()
		expect(HudLogic.quantize(12.37, 0.25)):toBe(12.25)
		expect(HudLogic.quantize(0.5, 0.25)):toBe(0.5)
		expect(HudLogic.quantize(-7, 5)):toBe(-10)
		expect(HudLogic.quantize(43, 5)):toBe(40)
	end)

	it("counts completed tasks", function()
		expect(HudLogic.countDone({ { completed = true }, { completed = false }, { completed = true } })):toBe(2)
		expect(HudLogic.countDone({})):toBe(0)
	end)
end)

describe("HudLogic effects", function()
	local effects: { HudLogic.Effect } = {
		{ id = "slow-field", category = "Movement", kind = "Debuff", expiresAt = 20 },
		{ id = "sprint-boost", category = "Movement", kind = "Buff", expiresAt = 15 },
		{ id = "freeze", category = "HardControl", kind = "Debuff", expiresAt = 12 },
		{ id = "blind", category = "Vision", kind = "Debuff", expiresAt = 8 },
	}

	it("keeps running effects, soonest-ending first", function()
		local active = HudLogic.activeEffects(effects, 10)
		expect(#active):toBe(3)
		expect(active[1].id):toBe("freeze")
		expect(active[2].id):toBe("sprint-boost")
		expect(active[3].id):toBe("slow-field")
	end)

	it("draws edges for debuffs only, one per category", function()
		local categories = HudLogic.sufferingCategories(effects, 10)
		expect(#categories):toBe(2)
		expect(categories[1]):toBe("HardControl")
		expect(categories[2]):toBe("Movement")
		-- after the freeze wears off, Movement stays lit from the slow
		-- field, not from the buff
		local later = HudLogic.sufferingCategories(effects, 16)
		expect(#later):toBe(1)
		expect(later[1]):toBe("Movement")
	end)

	it("treats an effect with no kind as a debuff", function()
		local categories = HudLogic.sufferingCategories({ { id = "x", category = "Vision", expiresAt = 5 } }, 0)
		expect(categories[1]):toBe("Vision")
	end)

	it("gives each known category a distinct set of edges, not just a colour", function()
		local seen: { [string]: boolean } = {}
		for category, edge in HudLogic.EDGES do
			expect(edge.category):toBe(category)
			expect((Tokens.color :: any)[edge.color] ~= nil):toBe(true)
			local key = table.concat(edge.sides, ",") .. (if edge.pulse then "+pulse" else "")
			expect(seen[key]):toBe(nil)
			seen[key] = true
			-- a band past a fifth of the short axis starts eating the middle
			expect(edge.depth > 0 and edge.depth <= 0.2):toBe(true)
		end
	end)

	it("falls back to a quiet band for an unknown category", function()
		local edge = HudLogic.edgeFor("Gravity")
		expect(edge.category):toBe("Gravity")
		expect(edge.pulse):toBe(false)
		expect(#edge.sides):toBe(4)
	end)
end)

describe("HudLogic objective", function()
	it("finds the nearest point on the ground plane", function()
		local best, distance = HudLogic.nearest({
			{ id = "a", x = 10, z = 0 },
			{ id = "b", x = 0, z = 4 },
		}, 0, 0)
		expect((best :: HudLogic.Point).id):toBe("b")
		expect(distance):toBe(4)
		local none, far = HudLogic.nearest({}, 0, 0)
		expect(none):toBe(nil)
		expect(far):toBe(math.huge)
	end)

	it("breaks a distance tie by id so the arrow doesn't flicker", function()
		local best = HudLogic.nearest({ { id = "b", x = 3, z = 0 }, { id = "a", x = -3, z = 0 } }, 0, 0)
		expect((best :: HudLogic.Point).id):toBe("a")
	end)

	it("measures bearing clockwise from where the camera looks", function()
		-- camera looking down -Z (Roblox default)
		expect(HudLogic.bearing(0, -1, 0, -10)):toBe(0)
		expect(HudLogic.bearing(0, -1, 10, 0)):toBe(90)
		expect(HudLogic.bearing(0, -1, -10, 0)):toBe(-90)
		expect(HudLogic.bearing(0, -1, 0, 10)):toBe(180)
		-- camera turned to look down +X: a target at +X is ahead
		expect(HudLogic.bearing(1, 0, 5, 0)):toBe(0)
		expect(HudLogic.bearing(1, 0, 0, 5)):toBe(90)
		expect(HudLogic.bearing(0, -1, 0, 0)):toBe(0)
	end)
end)

describe("HudLogic.slotGesture", function()
	it("is a tap while the finger stays inside the dead zone", function()
		expect(HudLogic.slotGesture(8, 3, 12, 30)):toBe("Tap")
	end)

	it("is an aim once it has left the dead zone and the slot", function()
		expect(HudLogic.slotGesture(80, 80, 12, 30)):toBe("Aim")
	end)

	it("cancels when an aim is dragged back onto the slot", function()
		expect(HudLogic.slotGesture(80, 10, 12, 30)):toBe("Cancel")
	end)
end)

describe("HudLogic.dragToGround", function()
	-- Roblox's default camera looks down -Z, with +X to its right.
	it("maps screen-up to the camera's flattened look", function()
		local x, z = HudLogic.dragToGround(0, -40, 0, -1)
		expect(x):toBe(0)
		expect(z):toBe(-1)
	end)

	it("maps screen-right to the camera's right", function()
		local x, z = HudLogic.dragToGround(40, 0, 0, -1)
		expect(x):toBe(1)
		expect(z):toBe(0)
	end)

	it("maps screen-down to towards the camera", function()
		local x, z = HudLogic.dragToGround(0, 25, 0, -1)
		expect(x):toBe(0)
		expect(z):toBe(1)
	end)

	it("is (0, 0) for no drag or a camera looking straight down", function()
		local x, z = HudLogic.dragToGround(0, 0, 0, -1)
		expect(x):toBe(0)
		expect(z):toBe(0)
		x, z = HudLogic.dragToGround(10, 10, 0, 0)
		expect(x):toBe(0)
		expect(z):toBe(0)
	end)
end)
