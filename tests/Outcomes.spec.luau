--!strict
-- Covers Outcomes.luau (P3-1): the pure Steal/Share resolver. Exhaustive
-- over every combination for one, two and three finalists, including
-- which outcome tier each winner is paid at. What a tier pays, and that
-- stealing out-pays sharing at every rung, is RewardLogic's
-- (tests/RewardLogic.spec.luau).

local TestRunner = require("./TestRunner")
local Outcomes = require("../src/shared/Config/Outcomes")

local SOLE: Outcomes.OutcomeTag, LONE: Outcomes.OutcomeTag, ALL: Outcomes.OutcomeTag =
	"SoleStealer", "LoneSharer", "AllShare"

local function finalist(playerId: number, choice: Outcomes.Choice): Outcomes.FinalistInput
	return { playerId = playerId, choice = choice }
end

local function winnerTag(result: Outcomes.OutcomeResult, playerId: number): Outcomes.OutcomeTag?
	for _, winner in result.winners do
		if winner.playerId == playerId then
			return winner.outcomeTag
		end
	end
	return nil
end

local function isLoser(result: Outcomes.OutcomeResult, playerId: number): boolean
	return table.find(result.loserIds, playerId) ~= nil
end

TestRunner.describe("Outcomes.resolve - three finalists", function()
	TestRunner.it("3 Share: all three win the all-share amount", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Share"), finalist(3, "Share") })
		TestRunner.expect(result.branch):toBe("AllShare")
		TestRunner.expect(#result.winners):toBe(3)
		TestRunner.expect(#result.loserIds):toBe(0)
		TestRunner.expect(winnerTag(result, 1)):toBe(ALL)
		TestRunner.expect(winnerTag(result, 2)):toBe(ALL)
		TestRunner.expect(winnerTag(result, 3)):toBe(ALL)
	end)

	TestRunner.it("3 Steal: nobody wins, all three lose", function()
		local result = Outcomes.resolve({ finalist(1, "Steal"), finalist(2, "Steal"), finalist(3, "Steal") })
		TestRunner.expect(result.branch):toBe("AllSteal")
		TestRunner.expect(#result.winners):toBe(0)
		TestRunner.expect(#result.loserIds):toBe(3)
	end)

	TestRunner.it("1 Steal, 2 Share (stealer first): the stealer wins big, sharers lose", function()
		local result = Outcomes.resolve({ finalist(1, "Steal"), finalist(2, "Share"), finalist(3, "Share") })
		TestRunner.expect(result.branch):toBe("SoleSteal")
		TestRunner.expect(winnerTag(result, 1)):toBe(SOLE)
		TestRunner.expect(isLoser(result, 2)):toBe(true)
		TestRunner.expect(isLoser(result, 3)):toBe(true)
	end)

	TestRunner.it("1 Steal, 2 Share (stealer in the middle): still correctly identified by id, not position", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Steal"), finalist(3, "Share") })
		TestRunner.expect(result.branch):toBe("SoleSteal")
		TestRunner.expect(winnerTag(result, 2)):toBe(SOLE)
		TestRunner.expect(isLoser(result, 1)):toBe(true)
		TestRunner.expect(isLoser(result, 3)):toBe(true)
	end)

	TestRunner.it("1 Steal, 2 Share (stealer last): still correctly identified", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Share"), finalist(3, "Steal") })
		TestRunner.expect(result.branch):toBe("SoleSteal")
		TestRunner.expect(winnerTag(result, 3)):toBe(SOLE)
	end)

	TestRunner.it("2 Steal, 1 Share (sharer first): the sharer wins small, stealers lose", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Steal"), finalist(3, "Steal") })
		TestRunner.expect(result.branch):toBe("LoneShare")
		TestRunner.expect(winnerTag(result, 1)):toBe(LONE)
		TestRunner.expect(isLoser(result, 2)):toBe(true)
		TestRunner.expect(isLoser(result, 3)):toBe(true)
	end)

	TestRunner.it("2 Steal, 1 Share (sharer in the middle): still correctly identified", function()
		local result = Outcomes.resolve({ finalist(1, "Steal"), finalist(2, "Share"), finalist(3, "Steal") })
		TestRunner.expect(result.branch):toBe("LoneShare")
		TestRunner.expect(winnerTag(result, 2)):toBe(LONE)
	end)

	TestRunner.it("2 Steal, 1 Share (sharer last): still correctly identified", function()
		local result = Outcomes.resolve({ finalist(1, "Steal"), finalist(2, "Steal"), finalist(3, "Share") })
		TestRunner.expect(result.branch):toBe("LoneShare")
		TestRunner.expect(winnerTag(result, 3)):toBe(LONE)
	end)
end)

TestRunner.describe("Outcomes.resolve - two finalists", function()
	TestRunner.it("Share, Share: both win the all-share amount", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Share") })
		TestRunner.expect(result.branch):toBe("TwoShare")
		TestRunner.expect(winnerTag(result, 1)):toBe(ALL)
		TestRunner.expect(winnerTag(result, 2)):toBe(ALL)
	end)

	TestRunner.it("Steal, Steal: both lose", function()
		local result = Outcomes.resolve({ finalist(1, "Steal"), finalist(2, "Steal") })
		TestRunner.expect(result.branch):toBe("TwoSteal")
		TestRunner.expect(#result.winners):toBe(0)
		TestRunner.expect(#result.loserIds):toBe(2)
	end)

	TestRunner.it("Steal, Share: the stealer takes everything, the sharer gets nothing", function()
		local result = Outcomes.resolve({ finalist(1, "Steal"), finalist(2, "Share") })
		TestRunner.expect(result.branch):toBe("OneStealOneShare")
		TestRunner.expect(winnerTag(result, 1)):toBe(SOLE)
		TestRunner.expect(isLoser(result, 2)):toBe(true)
	end)

	TestRunner.it("Share, Steal (order swapped): the stealer is still correctly identified by id", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Steal") })
		TestRunner.expect(result.branch):toBe("OneStealOneShare")
		TestRunner.expect(winnerTag(result, 2)):toBe(SOLE)
		TestRunner.expect(isLoser(result, 1)):toBe(true)
	end)
end)

TestRunner.describe("Outcomes.resolve - one finalist", function()
	TestRunner.it("a solo Steal still resolves at the baseline all-share amount", function()
		local result = Outcomes.resolve({ finalist(1, "Steal") })
		TestRunner.expect(result.branch):toBe("SoloFinalist")
		TestRunner.expect(winnerTag(result, 1)):toBe(ALL)
		TestRunner.expect(#result.loserIds):toBe(0)
	end)

	TestRunner.it("a solo Share resolves identically - choice doesn't matter alone", function()
		local result = Outcomes.resolve({ finalist(1, "Share") })
		TestRunner.expect(result.branch):toBe("SoloFinalist")
		TestRunner.expect(winnerTag(result, 1)):toBe(ALL)
	end)
end)

TestRunner.describe("Outcomes.resolve - invalid finalist counts fail loudly", function()
	TestRunner.it("errors on zero finalists", function()
		local ok = pcall(function()
			Outcomes.resolve({})
		end)
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("errors on more than three finalists", function()
		local ok = pcall(function()
			Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Share"), finalist(3, "Share"), finalist(4, "Share") })
		end)
		TestRunner.expect(ok):toBe(false)
	end)
end)
