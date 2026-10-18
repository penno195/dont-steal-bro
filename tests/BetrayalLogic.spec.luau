--!strict
-- Covers BetrayalLogic.luau (payoff-loop-roadmap.md step 7): which
-- sharers were robbed, and by whom. The owner's rule (design-decisions.md
-- Q5's betrayal card case): betrayed = a sharer who lost to a lone
-- stealer, so two stealers never rob anyone.

local TestRunner = require("./TestRunner")
local BetrayalLogic = require("../src/server/BetrayalLogic")
local Outcomes = require("../src/shared/Config/Outcomes")

local function robberiesFor(choices: { Outcomes.Choice }): { BetrayalLogic.Robbery }
	local finalists: { Outcomes.FinalistInput } = {}
	for i, choice in choices do
		table.insert(finalists, { playerId = i, choice = choice })
	end
	return BetrayalLogic.robberies(finalists, Outcomes.resolve(finalists))
end

TestRunner.describe("BetrayalLogic.robberies", function()
	TestRunner.it("names the lone stealer for both sharers of a sole steal", function()
		local robberies = robberiesFor({ "Share", "Steal", "Share" })
		TestRunner.expect(#robberies):toBe(2)
		TestRunner.expect(robberies[1].sharerId):toBe(1)
		TestRunner.expect(robberies[1].stealerId):toBe(2)
		TestRunner.expect(robberies[2].sharerId):toBe(3)
		TestRunner.expect(robberies[2].stealerId):toBe(2)
	end)

	TestRunner.it("covers a two-seat steal against a share", function()
		local robberies = robberiesFor({ "Steal", "Share" })
		TestRunner.expect(#robberies):toBe(1)
		TestRunner.expect(robberies[1].sharerId):toBe(2)
		TestRunner.expect(robberies[1].stealerId):toBe(1)
	end)

	TestRunner.it("robs nobody when two steal, since the lone sharer wins", function()
		TestRunner.expect(#robberiesFor({ "Steal", "Steal", "Share" })):toBe(0)
	end)

	TestRunner.it("robs nobody in all-share, all-steal or the solo default", function()
		TestRunner.expect(#robberiesFor({ "Share", "Share", "Share" })):toBe(0)
		TestRunner.expect(#robberiesFor({ "Steal", "Steal", "Steal" })):toBe(0)
		TestRunner.expect(#robberiesFor({ "Share", "Share" })):toBe(0)
		TestRunner.expect(#robberiesFor({ "Steal", "Steal" })):toBe(0)
		TestRunner.expect(#robberiesFor({ "Share" })):toBe(0)
		TestRunner.expect(#robberiesFor({ "Steal" })):toBe(0)
	end)
end)

TestRunner.describe("BetrayalLogic.robbedBy", function()
	TestRunner.it("names the stealer for a robbed sharer and nil for anyone else", function()
		local robberies = robberiesFor({ "Share", "Steal", "Share" })
		TestRunner.expect(BetrayalLogic.robbedBy(3, robberies)):toBe(2)
		TestRunner.expect(BetrayalLogic.robbedBy(2, robberies) == nil):toBe(true)
		TestRunner.expect(BetrayalLogic.robbedBy(99, robberies) == nil):toBe(true)
	end)
end)
