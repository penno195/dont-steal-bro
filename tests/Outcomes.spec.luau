--!strict
-- Covers Outcomes.luau (P3-1): the pure Steal/Share resolver. Exhaustive
-- over every combination for one, two and three finalists, plus the
-- design invariant that sole-stealer > lone-sharer > all-share > 0
-- carries through into what resolve() actually pays out.

local TestRunner = require("./TestRunner")
local Outcomes = require("../src/shared/Config/Outcomes")

-- Mirrors GameConfig.luau's own tier 1 numbers (sole=20, lone=10, all=5)
-- so the invariant test below is checking against a realistic, not
-- contrived, ordering.
local SOLE, LONE, ALL = 20, 10, 5

local function finalist(playerId: number, choice: Outcomes.Choice): Outcomes.FinalistInput
	return {
		playerId = playerId,
		choice = choice,
		soleStealerVU = SOLE,
		loneSharerVU = LONE,
		allShareVU = ALL,
	}
end

local function winnerAmount(result: Outcomes.OutcomeResult, playerId: number): number?
	for _, winner in result.winners do
		if winner.playerId == playerId then
			return winner.bountyVU
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
		TestRunner.expect(winnerAmount(result, 1)):toBe(ALL)
		TestRunner.expect(winnerAmount(result, 2)):toBe(ALL)
		TestRunner.expect(winnerAmount(result, 3)):toBe(ALL)
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
		TestRunner.expect(winnerAmount(result, 1)):toBe(SOLE)
		TestRunner.expect(isLoser(result, 2)):toBe(true)
		TestRunner.expect(isLoser(result, 3)):toBe(true)
	end)

	TestRunner.it("1 Steal, 2 Share (stealer in the middle): still correctly identified by id, not position", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Steal"), finalist(3, "Share") })
		TestRunner.expect(result.branch):toBe("SoleSteal")
		TestRunner.expect(winnerAmount(result, 2)):toBe(SOLE)
		TestRunner.expect(isLoser(result, 1)):toBe(true)
		TestRunner.expect(isLoser(result, 3)):toBe(true)
	end)

	TestRunner.it("1 Steal, 2 Share (stealer last): still correctly identified", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Share"), finalist(3, "Steal") })
		TestRunner.expect(result.branch):toBe("SoleSteal")
		TestRunner.expect(winnerAmount(result, 3)):toBe(SOLE)
	end)

	TestRunner.it("2 Steal, 1 Share (sharer first): the sharer wins small, stealers lose", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Steal"), finalist(3, "Steal") })
		TestRunner.expect(result.branch):toBe("LoneShare")
		TestRunner.expect(winnerAmount(result, 1)):toBe(LONE)
		TestRunner.expect(isLoser(result, 2)):toBe(true)
		TestRunner.expect(isLoser(result, 3)):toBe(true)
	end)

	TestRunner.it("2 Steal, 1 Share (sharer in the middle): still correctly identified", function()
		local result = Outcomes.resolve({ finalist(1, "Steal"), finalist(2, "Share"), finalist(3, "Steal") })
		TestRunner.expect(result.branch):toBe("LoneShare")
		TestRunner.expect(winnerAmount(result, 2)):toBe(LONE)
	end)

	TestRunner.it("2 Steal, 1 Share (sharer last): still correctly identified", function()
		local result = Outcomes.resolve({ finalist(1, "Steal"), finalist(2, "Steal"), finalist(3, "Share") })
		TestRunner.expect(result.branch):toBe("LoneShare")
		TestRunner.expect(winnerAmount(result, 3)):toBe(LONE)
	end)
end)

TestRunner.describe("Outcomes.resolve - two finalists", function()
	TestRunner.it("Share, Share: both win the all-share amount", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Share") })
		TestRunner.expect(result.branch):toBe("TwoShare")
		TestRunner.expect(winnerAmount(result, 1)):toBe(ALL)
		TestRunner.expect(winnerAmount(result, 2)):toBe(ALL)
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
		TestRunner.expect(winnerAmount(result, 1)):toBe(SOLE)
		TestRunner.expect(isLoser(result, 2)):toBe(true)
	end)

	TestRunner.it("Share, Steal (order swapped): the stealer is still correctly identified by id", function()
		local result = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Steal") })
		TestRunner.expect(result.branch):toBe("OneStealOneShare")
		TestRunner.expect(winnerAmount(result, 2)):toBe(SOLE)
		TestRunner.expect(isLoser(result, 1)):toBe(true)
	end)
end)

TestRunner.describe("Outcomes.resolve - one finalist", function()
	TestRunner.it("a solo Steal still resolves at the baseline all-share amount", function()
		local result = Outcomes.resolve({ finalist(1, "Steal") })
		TestRunner.expect(result.branch):toBe("SoloFinalist")
		TestRunner.expect(winnerAmount(result, 1)):toBe(ALL)
		TestRunner.expect(#result.loserIds):toBe(0)
	end)

	TestRunner.it("a solo Share resolves identically - choice doesn't matter alone", function()
		local result = Outcomes.resolve({ finalist(1, "Share") })
		TestRunner.expect(result.branch):toBe("SoloFinalist")
		TestRunner.expect(winnerAmount(result, 1)):toBe(ALL)
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

TestRunner.describe("Outcomes.resolve - design invariant: soleStealer > loneSharer > allShare > 0", function()
	TestRunner.it("carries through into what each branch actually pays its winner(s)", function()
		TestRunner.expect(SOLE > LONE):toBeTruthy()
		TestRunner.expect(LONE > ALL):toBeTruthy()
		TestRunner.expect(ALL > 0):toBeTruthy()

		local soleSteal = Outcomes.resolve({ finalist(1, "Steal"), finalist(2, "Share"), finalist(3, "Share") })
		local loneShare = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Steal"), finalist(3, "Steal") })
		local allShare = Outcomes.resolve({ finalist(1, "Share"), finalist(2, "Share"), finalist(3, "Share") })

		local soleStealPayout = winnerAmount(soleSteal, 1) :: number
		local loneSharePayout = winnerAmount(loneShare, 1) :: number
		local allSharePayout = winnerAmount(allShare, 1) :: number

		-- This is the test that fails loudly if a future edit to this
		-- module's branch logic ever swaps which VU field feeds which
		-- branch - the ordering asserted here is the actual incentive
		-- shape the whole Decision Studio depends on, not just a fact
		-- about the input numbers.
		TestRunner.expect(soleStealPayout > loneSharePayout):toBeTruthy()
		TestRunner.expect(loneSharePayout > allSharePayout):toBeTruthy()
		TestRunner.expect(allSharePayout > 0):toBeTruthy()
	end)
end)
