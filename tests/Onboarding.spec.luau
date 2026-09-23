--!strict
-- Covers P6-8's first-round tips (OnboardingLogic) and the Steal or
-- Share explainer (DecisionLogic.explainerRows). The overlay itself is
-- reviewed on device (docs/onboarding.md).

local DecisionLogic = require("../src/client/UI/DecisionLogic")
local OnboardingLogic = require("../src/client/UI/OnboardingLogic")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

describe("OnboardingLogic copy", function()
	it("keeps every tip short enough for two lines on a phone", function()
		for _, tip in OnboardingLogic.TIPS do
			expect(#tip.title <= 30):toBe(true)
			expect(#tip.body <= 90):toBe(true)
		end
	end)

	it("gives every tip a reading time between 4 and 9 seconds", function()
		for _, tip in OnboardingLogic.TIPS do
			local s = OnboardingLogic.readSeconds(tip)
			expect(s >= 4 and s <= 9):toBe(true)
		end
	end)
end)

describe("OnboardingLogic queue", function()
	it("shows one tip at a time, in order, each once", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "race")
		OnboardingLogic.trigger(s, "powerUp")
		expect(s.showing):toBe("race")
		OnboardingLogic.dismiss(s)
		expect(s.showing):toBe("powerUp")
		OnboardingLogic.dismiss(s)
		OnboardingLogic.trigger(s, "powerUp")
		expect(s.showing):toBe(nil)
	end)

	it("never queues the same tip twice", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "race")
		OnboardingLogic.trigger(s, "hit")
		OnboardingLogic.trigger(s, "hit")
		OnboardingLogic.trigger(s, "race")
		expect(#s.queue):toBe(1)
	end)

	it("ignores a tip for another stage", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "choose")
		expect(s.showing):toBe(nil)
	end)

	it("drops a stale race tip when the Studio starts", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "race")
		OnboardingLogic.trigger(s, "hit")
		OnboardingLogic.enterStage(s, "Studio")
		expect(s.showing):toBe(nil)
		expect(#s.queue):toBe(0)
		OnboardingLogic.trigger(s, "finale")
		expect(s.showing):toBe("finale")
	end)

	it("counts the loop taught after the race and either finale path", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "race")
		OnboardingLogic.dismiss(s)
		expect(OnboardingLogic.loopTaught(s)):toBe(false)
		OnboardingLogic.enterStage(s, "Studio")
		OnboardingLogic.trigger(s, "missed")
		OnboardingLogic.dismiss(s)
		expect(OnboardingLogic.loopTaught(s)):toBe(true)
	end)

	it("doesn't count a player who joined after the race", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Studio")
		OnboardingLogic.trigger(s, "finale")
		OnboardingLogic.dismiss(s)
		OnboardingLogic.trigger(s, "choose")
		OnboardingLogic.dismiss(s)
		expect(OnboardingLogic.loopTaught(s)):toBe(false)
	end)
end)

describe("DecisionLogic.explainerRows", function()
	it("reads the three-seat table the way payoff-table.md does", function()
		local rows = DecisionLogic.explainerRows(3)
		expect(#rows):toBe(4)
		expect(rows[1].detail):toBe("Everyone gets a SMALL prize.")
		expect(rows[2].detail):toBe("The stealer gets the BIG prize. The sharers get nothing.")
		expect(rows[3].detail):toBe("The one who shared gets a MEDIUM prize. The stealers get nothing.")
		expect(rows[4].detail):toBe("Everyone gets nothing.")
	end)

	it("names every prize prizeFor gives, for every table size", function()
		for seats = 1, 3 do
			for _, row in DecisionLogic.explainerRows(seats) do
				local stealers = row.stealers
				local expected: { string } = {}
				if stealers > 0 then
					table.insert(expected, DecisionLogic.prizeFor("Steal", stealers - 1, seats))
				end
				if stealers < seats then
					table.insert(expected, DecisionLogic.prizeFor("Share", stealers, seats))
				end
				for _, prize in expected do
					local word = if prize == "Nothing" then "nothing" else DecisionLogic.PRIZE_LABEL[prize :: any]
					expect(string.find(row.detail, word, 1, true) ~= nil):toBe(true)
				end
			end
		end
	end)

	it("backs up the one-line lesson: a steal only pays when it's the only one", function()
		for seats = 2, 3 do
			for othersStealing = 1, seats - 1 do
				expect(DecisionLogic.prizeFor("Steal", othersStealing, seats)):toBe("Nothing")
			end
			expect(DecisionLogic.prizeFor("Steal", 0, seats)):toBe("Big")
		end
	end)
end)
