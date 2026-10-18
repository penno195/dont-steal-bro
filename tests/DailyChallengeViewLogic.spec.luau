--!strict
-- Covers DailyChallengeViewLogic.luau: the Hub's daily challenges panel
-- (payoff-loop step 8c) - reading DailyChallengeState and its wording.

local TestRunner = require("./TestRunner")
local DailyChallengeViewLogic = require("../src/client/UI/DailyChallengeViewLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function slot(overrides: { [string]: any }?): { [string]: any }
	local s: { [string]: any } =
		{ id = "tasks", label = "Finish 5 tasks", progress = 2, target = 5, done = false, coins = 50, xp = 40 }
	for k, v in overrides or {} do
		s[k] = v
	end
	return s
end

local function payload(overrides: { [string]: any }?): { [string]: any }
	local p: { [string]: any } = {
		day = "2026-10-18",
		slots = { slot(), slot({ id = "win", done = true, progress = 1, target = 1 }) },
		rerollsLeft = 1,
		allDone = { coins = 100, xp = 50, paid = false },
		resetsIn = 3 * 3600 + 5 * 60,
	}
	for k, v in overrides or {} do
		p[k] = v
	end
	return p
end

describe("DailyChallengeViewLogic.parse", function()
	it("reads a well-formed state", function()
		local s = DailyChallengeViewLogic.parse(payload()) :: DailyChallengeViewLogic.State
		expect(#s.slots):toBe(2)
		expect(s.slots[1].label):toBe("Finish 5 tasks")
		expect(s.slots[2].done):toBe(true)
		expect(s.rerollsLeft):toBe(1)
		expect(s.allDone.coins):toBe(100)
	end)

	it("drops junk, and the whole list for one bad slot", function()
		expect(DailyChallengeViewLogic.parse(nil)):toBe(nil)
		expect(DailyChallengeViewLogic.parse(payload({ rerollsLeft = -1 }))):toBe(nil)
		expect(DailyChallengeViewLogic.parse(payload({ allDone = { coins = 1, xp = 1 } }))):toBe(nil)
		expect(DailyChallengeViewLogic.parse(payload({ slots = { slot(), slot({ target = "5" }) } }))):toBe(nil)
	end)
end)

describe("DailyChallengeViewLogic wording", function()
	it("words rewards and progress", function()
		expect(DailyChallengeViewLogic.rewardText(50, 40)):toBe("+50 coins  +40 XP")
		expect(DailyChallengeViewLogic.rewardText(0, 40)):toBe("+40 XP")
		expect(DailyChallengeViewLogic.rewardText(0, 0)):toBe("")
		local s = DailyChallengeViewLogic.parse(payload()) :: DailyChallengeViewLogic.State
		expect(DailyChallengeViewLogic.progressText(s.slots[1])):toBe("2/5")
		expect(DailyChallengeViewLogic.progressText(s.slots[2])):toBe("Done")
		expect(DailyChallengeViewLogic.levelCaption(s)):toBe("LEVEL · 1/2 TODAY")
		expect(DailyChallengeViewLogic.levelCaption(nil)):toBe("LEVEL")
		expect(DailyChallengeViewLogic.explainer(s.slots[1], "Finish %d tasks today.")):toBe(
			"Finish 5 tasks today.\n\nProgress: 2/5   Reward: +50 coins  +40 XP"
		)
		expect(DailyChallengeViewLogic.explainer(s.slots[2], nil)):toBe("Done! You got +50 coins  +40 XP.")
	end)

	it("only lets an unfinished slot be swapped while swaps are left", function()
		local s = DailyChallengeViewLogic.parse(payload()) :: DailyChallengeViewLogic.State
		expect(DailyChallengeViewLogic.canReroll(s, s.slots[1])):toBe(true)
		expect(DailyChallengeViewLogic.canReroll(s, s.slots[2])):toBe(false)
		local none = DailyChallengeViewLogic.parse(payload({ rerollsLeft = 0 })) :: DailyChallengeViewLogic.State
		expect(DailyChallengeViewLogic.canReroll(none, none.slots[1])):toBe(false)
		expect(DailyChallengeViewLogic.rerollLine(none)):toBe("No swaps left today.")
		expect(DailyChallengeViewLogic.rerollLine(s)):toBe("1 free swap left today.")
	end)

	it("words the bonus before and after it's paid", function()
		local s = DailyChallengeViewLogic.parse(payload()) :: DailyChallengeViewLogic.State
		expect(DailyChallengeViewLogic.bonusLine(s)):toBe("Finish all of them: +100 coins  +50 XP")
		local paid = DailyChallengeViewLogic.parse(payload({ allDone = { coins = 100, xp = 50, paid = true } }))
		expect(DailyChallengeViewLogic.bonusLine(paid :: DailyChallengeViewLogic.State)):toBe(
			"All done for today. Bonus paid!"
		)
	end)

	it("counts down to the reset", function()
		local s = DailyChallengeViewLogic.parse(payload()) :: DailyChallengeViewLogic.State
		expect(DailyChallengeViewLogic.resetText(DailyChallengeViewLogic.secondsLeft(s, 0))):toBe(
			"New challenges in 3h 5m"
		)
		expect(DailyChallengeViewLogic.resetText(DailyChallengeViewLogic.secondsLeft(s, 3 * 3600))):toBe(
			"New challenges in 5m"
		)
		expect(DailyChallengeViewLogic.secondsLeft(s, 99999)):toBe(0)
		expect(DailyChallengeViewLogic.resetText(30)):toBe("New challenges in under a minute")
	end)

	it("words a refused swap", function()
		expect(DailyChallengeViewLogic.refusalText("NoRerolls")):toBe("No swaps left today.")
		expect(DailyChallengeViewLogic.refusalText("NotSaved")):toBe("Couldn't swap that. Try again.")
		expect(DailyChallengeViewLogic.refusalText(nil)):toBe("Couldn't swap that. Try again.")
	end)
end)
