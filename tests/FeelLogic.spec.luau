--!strict
-- Covers FeelLogic.luau (P8-3): every moment has both variants, reduced
-- motion never moves anything, and the curves start and end at rest.
-- FeelController touches the camera and characters, so it's exercised
-- in Studio.

local FeelLogic = require("../src/client/UI/FeelLogic")
local TestRunner = require("./TestRunner")
local Tokens = require("../src/client/UI/Tokens")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

describe("FeelLogic.spec", function()
	it("defines every moment in both variants, with a punch channel", function()
		for _, moment in FeelLogic.MOMENTS do
			expect(FeelLogic.spec(moment, false) ~= nil):toBe(true)
			expect(FeelLogic.spec(moment, true) ~= nil):toBe(true)
			expect(FeelLogic.CHANNEL[moment] ~= nil):toBe(true)
		end
	end)

	it("never shakes, punches, freezes or sprays under reduced motion", function()
		for _, moment in FeelLogic.MOMENTS do
			local spec = FeelLogic.spec(moment, true)
			expect(spec.shake):toBe(nil)
			expect(spec.punch):toBe(nil)
			expect(spec.hitStop):toBe(0)
			if spec.burst ~= nil then
				expect(spec.burst.speed):toBe(0)
			end
			-- ...but the moment still lands.
			expect(spec.flash ~= nil):toBe(true)
		end
	end)

	it("ranks the moments: qualifying and the outcome hit hardest", function()
		local task = FeelLogic.spec("TaskComplete", false)
		local qualified = FeelLogic.spec("Qualified", false)
		local outcome = FeelLogic.spec("RevealOutcome", false)
		local card = FeelLogic.spec("RevealCard", false)
		assert(qualified.shake and task.shake and outcome.shake and card.shake)
		expect(qualified.shake.amplitude > task.shake.amplitude):toBe(true)
		expect(outcome.shake.amplitude > card.shake.amplitude):toBe(true)
	end)

	it("keeps hit-stop short enough to read as impact, not lag", function()
		for _, moment in FeelLogic.MOMENTS do
			expect(FeelLogic.spec(moment, false).hitStop <= 0.15):toBe(true)
		end
	end)

	it("only names colour tokens that exist", function()
		for _, reduced in { false, true } do
			for _, moment in FeelLogic.MOMENTS do
				local spec = FeelLogic.spec(moment, reduced)
				for _, token in { spec.burst and spec.burst.colorToken, spec.flash and spec.flash.colorToken } do
					if token ~= nil then
						assert((Tokens.color :: any)[token] ~= nil, moment .. ": unknown colour token " .. token)
					end
				end
			end
		end
	end)
end)

describe("FeelLogic curves", function()
	local shake = { amplitude = 0.3, frequency = 14, duration = 0.45 }
	local punch = { peak = 1.2, attack = 0.08, release = 0.4 }

	it("shake is zero outside its window and bounded inside", function()
		local x, y = FeelLogic.shakeOffset(shake, -0.1)
		expect(x):toBe(0)
		expect(y):toBe(0)
		x, y = FeelLogic.shakeOffset(shake, shake.duration)
		expect(x):toBe(0)
		expect(y):toBe(0)
		for t = 0, shake.duration, 0.01 do
			local sx, sy = FeelLogic.shakeOffset(shake, t)
			assert(math.abs(sx) <= shake.amplitude and math.abs(sy) <= shake.amplitude, "shake out of bounds")
		end
	end)

	it("punch rests at 1, peaks at peak, and returns to 1", function()
		expect(FeelLogic.punchScale(punch, 0)):toBe(1)
		expect(FeelLogic.punchScale(punch, punch.attack)):toBeCloseTo(punch.peak)
		expect(FeelLogic.punchScale(punch, punch.attack + punch.release)):toBe(1)
		for t = 0, punch.attack + punch.release, 0.01 do
			local s = FeelLogic.punchScale(punch, t)
			assert(s >= 1 and s <= punch.peak + 1e-9, "punch overshoots")
		end
	end)

	it("flash starts at its transparency and fades out", function()
		local flash = { transparency = 0.6, duration = 0.5, colorToken = "brand" }
		expect(FeelLogic.flashTransparency(flash, 0)):toBeCloseTo(0.6)
		expect(FeelLogic.flashTransparency(flash, 0.25)):toBeCloseTo(0.8)
		expect(FeelLogic.flashTransparency(flash, 0.5)):toBe(1)
	end)

	it("keeps the stronger of two shakes rather than summing", function()
		local x, y = FeelLogic.stronger(0.1, 0, 0, 0.2)
		expect(x):toBe(0)
		expect(y):toBe(0.2)
	end)
end)
