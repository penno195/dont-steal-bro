--!strict
-- Covers GuessLogic.luau (payoff-loop-roadmap.md step 2): who walks out,
-- which guesses are taken, and who earns a streak shield. The owner's
-- rule (design-decisions.md Q7's finale guesses case): a guess only
-- wins when the result is a single stealer or a single sharer.

local TestRunner = require("./TestRunner")
local GuessLogic = require("../src/server/GuessLogic")
local Outcomes = require("../src/shared/Config/Outcomes")

local function resolve(choices: { Outcomes.Choice }): Outcomes.OutcomeResult
	local finalists: { Outcomes.FinalistInput } = {}
	for i, choice in choices do
		table.insert(finalists, { playerId = i, choice = choice })
	end
	return Outcomes.resolve(finalists)
end

TestRunner.describe("GuessLogic.walkerOut", function()
	TestRunner.it("is the lone stealer of a sole steal", function()
		TestRunner.expect(GuessLogic.walkerOut(resolve({ "Share", "Steal", "Share" }))):toBe(2)
	end)

	TestRunner.it("is the lone sharer of a lone share", function()
		TestRunner.expect(GuessLogic.walkerOut(resolve({ "Steal", "Steal", "Share" }))):toBe(3)
	end)

	TestRunner.it("is the stealer of a two-seat steal against a share", function()
		TestRunner.expect(GuessLogic.walkerOut(resolve({ "Share", "Steal" }))):toBe(2)
	end)

	TestRunner.it("is nil for all-share, all-steal and the solo default", function()
		TestRunner.expect(GuessLogic.walkerOut(resolve({ "Share", "Share", "Share" })) == nil):toBe(true)
		TestRunner.expect(GuessLogic.walkerOut(resolve({ "Steal", "Steal", "Steal" })) == nil):toBe(true)
		TestRunner.expect(GuessLogic.walkerOut(resolve({ "Share", "Share" })) == nil):toBe(true)
		TestRunner.expect(GuessLogic.walkerOut(resolve({ "Steal", "Steal" })) == nil):toBe(true)
		TestRunner.expect(GuessLogic.walkerOut(resolve({ "Steal" })) == nil):toBe(true)
	end)
end)

TestRunner.describe("GuessLogic.isCorrect", function()
	TestRunner.it("is true only for the finalist who walks out", function()
		local result = resolve({ "Share", "Steal", "Share" })
		TestRunner.expect(GuessLogic.isCorrect(2, result)):toBe(true)
		TestRunner.expect(GuessLogic.isCorrect(1, result)):toBe(false)
		TestRunner.expect(GuessLogic.isCorrect(nil, result)):toBe(false)
	end)

	TestRunner.it("is false for every guess when nobody walks out alone", function()
		local result = resolve({ "Share", "Share", "Share" })
		for id = 1, 3 do
			TestRunner.expect(GuessLogic.isCorrect(id, result)):toBe(false)
		end
	end)
end)

TestRunner.describe("GuessLogic.validate", function()
	local FINALISTS = { 10, 20, -1 } -- -1: an NPC seat, which can be guessed

	TestRunner.it("takes a knocked-out player's first guess on any finalist, NPC included", function()
		TestRunner.expect((GuessLogic.validate(4, 20, FINALISTS, {}))):toBe(true)
		TestRunner.expect((GuessLogic.validate(4, -1, FINALISTS, {}))):toBe(true)
	end)

	TestRunner.it("refuses finalists, non-finalist targets and a second guess", function()
		local ok, why = GuessLogic.validate(10, 20, FINALISTS, {})
		TestRunner.expect(ok):toBe(false)
		TestRunner.expect(why):toBe("IsFinalist")

		ok, why = GuessLogic.validate(4, 5, FINALISTS, {})
		TestRunner.expect(ok):toBe(false)
		TestRunner.expect(why):toBe("NotAFinalist")

		ok, why = GuessLogic.validate(4, 10, FINALISTS, { [4] = 20 })
		TestRunner.expect(ok):toBe(false)
		TestRunner.expect(why):toBe("AlreadyGuessed")
	end)
end)

TestRunner.describe("GuessLogic.shieldWinners", function()
	TestRunner.it("lists every correct guesser in id order", function()
		local result = resolve({ "Steal", "Steal", "Share" }) -- 3 walks out
		local winners = GuessLogic.shieldWinners({ [9] = 3, [4] = 3, [7] = 1 }, result)
		TestRunner.expect(#winners):toBe(2)
		TestRunner.expect(winners[1]):toBe(4)
		TestRunner.expect(winners[2]):toBe(9)
	end)

	TestRunner.it("is empty when the result has no lone winner", function()
		local result = resolve({ "Steal", "Steal", "Steal" })
		TestRunner.expect(#GuessLogic.shieldWinners({ [4] = 1, [5] = 2 }, result)):toBe(0)
	end)
end)
