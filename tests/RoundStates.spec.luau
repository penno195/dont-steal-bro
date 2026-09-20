--!strict
-- Covers RoundStates.luau (P2-1): the pure round state machine. Round-
-- Service.luau itself isn't required here - it touches Signals/
-- workspace/remotes at call time, so it's exercised manually in Studio
-- instead, same split as every other *.spec.luau in this suite.

local TestRunner = require("./TestRunner")
local RoundStates = require("../src/shared/RoundStates")

TestRunner.describe("RoundStates.isLegalTransition (every legal path)", function()
	local legalPairs: { { RoundStates.RoundState } } = {
		{ "WaitingForPlayers", "Loading" },
		{ "Loading", "Intro" },
		{ "Intro", "Race" },
		{ "Race", "Qualified" },
		{ "Qualified", "DecisionStudio" },
		{ "DecisionStudio", "Results" },
		{ "Results", "Cleanup" },
	}

	for _, pair in legalPairs do
		local from, to = pair[1], pair[2]
		TestRunner.it(string.format("allows %s -> %s", from, to), function()
			TestRunner.expect(RoundStates.isLegalTransition(from, to)):toBe(true)
		end)
	end

	TestRunner.it("every state in RoundStates.ALL is covered by the table above", function()
		TestRunner.expect(#RoundStates.ALL):toBe(8)
	end)
end)

TestRunner.describe("RoundStates.isLegalTransition (a sample of illegal paths)", function()
	local illegalPairs: { { RoundStates.RoundState } } = {
		{ "WaitingForPlayers", "Race" }, -- skipping ahead
		{ "Race", "WaitingForPlayers" }, -- going backward
		{ "Intro", "Intro" }, -- re-entering the same state isn't a normal transition
		{ "Cleanup", "WaitingForPlayers" }, -- Cleanup is terminal - no same-server continuation (design-decisions.md Q6)
		{ "DecisionStudio", "Race" }, -- skipping the reveal
	}

	for _, pair in illegalPairs do
		local from, to = pair[1], pair[2]
		TestRunner.it(string.format("rejects %s -> %s", from, to), function()
			TestRunner.expect(RoundStates.isLegalTransition(from, to)):toBe(false)
		end)
	end
end)

TestRunner.describe("RoundStates.legalNextStates", function()
	TestRunner.it("returns the single next state for a normal state", function()
		local next = RoundStates.legalNextStates("Loading")
		TestRunner.expect(#next):toBe(1)
		TestRunner.expect(next[1]):toBe("Intro")
	end)

	TestRunner.it("returns an empty list for the terminal state", function()
		TestRunner.expect(#RoundStates.legalNextStates("Cleanup")):toBe(0)
	end)
end)

TestRunner.describe("RoundStates.runOnce (exactly-once exit guard)", function()
	TestRunner.it("runs the action on the first call", function()
		local calls = 0
		local ran = RoundStates.runOnce(false, function()
			calls += 1
		end)
		TestRunner.expect(ran):toBe(true)
		TestRunner.expect(calls):toBe(1)
	end)

	TestRunner.it("is a no-op when already run - the timer/condition race the task names", function()
		local calls = 0
		local ran = RoundStates.runOnce(true, function()
			calls += 1
		end)
		TestRunner.expect(ran):toBe(false)
		TestRunner.expect(calls):toBe(0)
	end)
end)
