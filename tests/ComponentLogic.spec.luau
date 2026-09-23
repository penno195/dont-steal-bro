--!strict
-- Covers the pure half of the component library (P6-2). The Vide
-- components themselves create Instances and are reviewed on device via
-- the ComponentGallery screen (docs/components.md); this is everything
-- underneath them that can be decided without a GuiObject.

local ColorVision = require("../src/client/UI/ColorVision")
local ComponentLogic = require("../src/client/UI/Components/ComponentLogic")
local Layout = require("../src/client/UI/Layout")
local TestRunner = require("./TestRunner")
local Tokens = require("../src/client/UI/Tokens")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local colors = Tokens.color :: { [string]: string }

local function state(disabled: boolean, loading: boolean, pressed: boolean, hovered: boolean)
	return ComponentLogic.resolveState({ disabled = disabled, loading = loading, pressed = pressed, hovered = hovered })
end

describe("ComponentLogic.resolveState", function()
	it("is idle with nothing set", function()
		expect(state(false, false, false, false)):toBe("idle")
	end)

	it("ranks disabled > loading > pressed > hovered", function()
		expect(state(true, true, true, true)):toBe("disabled")
		expect(state(false, true, true, true)):toBe("loading")
		expect(state(false, false, true, true)):toBe("pressed")
		expect(state(false, false, false, true)):toBe("hovered")
	end)

	it("only fires the action from idle, hovered or pressed", function()
		expect(ComponentLogic.acceptsInput("idle")):toBe(true)
		expect(ComponentLogic.acceptsInput("hovered")):toBe(true)
		expect(ComponentLogic.acceptsInput("pressed")):toBe(true)
		expect(ComponentLogic.acceptsInput("loading")):toBe(false)
		expect(ComponentLogic.acceptsInput("disabled")):toBe(false)
	end)
end)

describe("ComponentLogic.variantStyle", function()
	local variants: { ComponentLogic.Variant } = { "primary", "secondary", "danger", "ghost" }
	local states: { ComponentLogic.State } = { "idle", "hovered", "pressed", "loading", "disabled" }

	it("only names colour tokens that exist", function()
		for _, variant in variants do
			for _, s in states do
				local style = ComponentLogic.variantStyle(variant, s)
				for _, key in { style.fill, style.ink, style.stroke } do
					assert(colors[key] ~= nil, string.format("%s/%s names missing token %q", variant, s, key))
				end
			end
		end
	end)

	it("gives every fill/ink pair WCAG AA contrast", function()
		for _, pair in ComponentLogic.inkPairs() do
			local ratio =
				ColorVision.contrast(ColorVision.fromHex(colors[pair.fill]), ColorVision.fromHex(colors[pair.ink]))
			assert(ratio >= Tokens.contrast.textMin, string.format("%s on %s is %.2f", pair.ink, pair.fill, ratio))
		end
	end)

	it("looks the same when disabled, whatever the variant", function()
		local first = ComponentLogic.variantStyle("primary", "disabled")
		for _, variant in variants do
			expect(ComponentLogic.variantStyle(variant, "disabled")):toBe(first)
		end
	end)

	it("makes every state visibly different from idle", function()
		for _, variant in variants do
			local idle = ComponentLogic.variantStyle(variant, "idle")
			for _, s in { "hovered", "pressed", "disabled" } :: { ComponentLogic.State } do
				local style = ComponentLogic.variantStyle(variant, s)
				local differs = style.fill ~= idle.fill
					or style.ink ~= idle.ink
					or style.fillTransparency ~= idle.fillTransparency
					or style.overlayTransparency ~= idle.overlayTransparency
				assert(differs, string.format("%s %s looks identical to idle", variant, s))
			end
		end
	end)

	it("shrinks the visual on press only", function()
		expect(ComponentLogic.pressScale("pressed") < 1):toBe(true)
		expect(ComponentLogic.pressScale("hovered")):toBe(1)
		expect(ComponentLogic.pressScale("loading")):toBe(1)
	end)

	it("rejects an unknown variant", function()
		expect(pcall(ComponentLogic.variantStyle, "neon" :: any, "idle")):toBeFalsy()
	end)
end)

describe("ComponentLogic.hitArea", function()
	it("renders at >= 44 points at every scale in the clamp", function()
		local scale = Tokens.scale.min
		while scale <= Tokens.scale.max + 1e-9 do
			local minRef = Layout.minTouchRef(scale, Tokens.touch.minTargetPoints)
			for _, visual in { 16, 24, 32, 44, 56 } do
				local size = ComponentLogic.hitArea(visual, minRef)
				assert(size * scale >= Tokens.touch.minTargetPoints - 1e-9, string.format("%d at %.2f", visual, scale))
			end
			scale += 0.05
		end
	end)

	it("never shrinks the visual, and centres it", function()
		local size, inset = ComponentLogic.hitArea(24, 59)
		expect(size):toBe(59)
		expect(inset):toBe(17.5)
		size, inset = ComponentLogic.hitArea(56, 44)
		expect(size):toBe(56)
		expect(inset):toBe(0)
	end)
end)

describe("ComponentLogic motion", function()
	it("collapses to zero under reduced motion", function()
		expect(ComponentLogic.duration(Tokens.motion.slow, true)):toBe(0)
		expect(ComponentLogic.duration(Tokens.motion.slow, false)):toBe(Tokens.motion.slow)
	end)
end)

describe("ComponentLogic progress and countdown", function()
	it("clamps fractions and survives bad input", function()
		expect(ComponentLogic.fraction(5, 10)):toBe(0.5)
		expect(ComponentLogic.fraction(15, 10)):toBe(1)
		expect(ComponentLogic.fraction(-1, 10)):toBe(0)
		expect(ComponentLogic.fraction(5, 0)):toBe(0)
		expect(ComponentLogic.fraction(0 / 0, 10)):toBe(0)
	end)

	it("rotates the ring halves to cover exactly the arc", function()
		local r, l = ComponentLogic.ringRotations(0)
		expect(r):toBe(0) -- right half hidden
		expect(l):toBe(180) -- left half hidden
		r, l = ComponentLogic.ringRotations(0.25)
		expect(r):toBe(90)
		expect(l):toBe(180)
		r, l = ComponentLogic.ringRotations(0.5)
		expect(r):toBe(180) -- right half full
		expect(l):toBe(180)
		r, l = ComponentLogic.ringRotations(0.75)
		expect(r):toBe(180)
		expect(l):toBe(270)
		r, l = ComponentLogic.ringRotations(1.5)
		expect(r):toBe(180)
		expect(l):toBe(360)
	end)

	it("steps urgency by seconds left", function()
		expect(ComponentLogic.urgency(20, 10, 5)):toBe("calm")
		expect(ComponentLogic.urgency(10, 10, 5)):toBe("warning")
		expect(ComponentLogic.urgency(5, 10, 5)):toBe("critical")
	end)

	it("rounds the label up so 0 means time is out", function()
		expect(ComponentLogic.countdownLabel(0.4)):toBe("1")
		expect(ComponentLogic.countdownLabel(1)):toBe("1")
		expect(ComponentLogic.countdownLabel(0)):toBe("0")
		expect(ComponentLogic.countdownLabel(-3)):toBe("0")
	end)
end)

describe("ComponentLogic.formatAmount", function()
	it("groups thousands below 10,000", function()
		expect(ComponentLogic.formatAmount(0)):toBe("0")
		expect(ComponentLogic.formatAmount(999)):toBe("999")
		expect(ComponentLogic.formatAmount(1234)):toBe("1,234")
		expect(ComponentLogic.formatAmount(9999)):toBe("9,999")
	end)

	it("abbreviates by truncating, never rounding up", function()
		expect(ComponentLogic.formatAmount(10000)):toBe("10K")
		expect(ComponentLogic.formatAmount(12345)):toBe("12.3K")
		expect(ComponentLogic.formatAmount(99999)):toBe("99.9K")
		expect(ComponentLogic.formatAmount(999999)):toBe("999K")
		expect(ComponentLogic.formatAmount(1500000)):toBe("1.5M")
		expect(ComponentLogic.formatAmount(2e9)):toBe("2B")
		expect(ComponentLogic.formatAmount(-1234)):toBe("-1,234")
	end)
end)

describe("ComponentLogic tabs and toasts", function()
	it("wraps tab steps both ways", function()
		expect(ComponentLogic.stepTab(1, 3, -1)):toBe(3)
		expect(ComponentLogic.stepTab(3, 3, 1)):toBe(1)
		expect(ComponentLogic.stepTab(2, 3, 1)):toBe(3)
		expect(ComponentLogic.stepTab(1, 0, 1)):toBe(0)
	end)

	it("keeps toasts on screen between 2 and 6 seconds", function()
		expect(ComponentLogic.toastSeconds("")):toBe(2)
		expect(ComponentLogic.toastSeconds(string.rep("x", 500))):toBe(6)
	end)

	it("drops the oldest toast past the cap", function()
		local q = {}
		local dropped
		q, dropped = ComponentLogic.pushToast(q, "a", 2)
		expect(dropped):toBe(nil)
		q, dropped = ComponentLogic.pushToast(q, "b", 2)
		q, dropped = ComponentLogic.pushToast(q, "c", 2)
		expect(dropped):toBe("a")
		expect(#q):toBe(2)
		expect(q[1]):toBe("b")
	end)
end)
