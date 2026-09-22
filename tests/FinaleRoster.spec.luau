--!strict
-- Covers FinaleRoster.luau (P3-7): every disconnect and shutdown branch
-- of the Decision Studio, as decisions. DecisionService.luau itself
-- isn't required here - it touches Players/remotes/timers/ProfileStore
-- at call time, so its integration is exercised manually in Studio
-- (docs/finale-disconnect-tests.md has the two-client script), the same
-- split every other spec in this suite uses.
--
-- P3-7 asks for all six cases to be implemented AND tested. Five of
-- them are decisions and are tested here; the sixth (the ordering
-- guarantee that a profile write beats ProfileStore's session release)
-- lives in ProfileLogic.applyLeaveSequence and is covered by
-- ProfileLogic.spec.luau's own ordering case.

local TestRunner = require("./TestRunner")
local FinaleRoster = require("../src/server/FinaleRoster")

local function presentExcept(missing: { number }): (racerId: number) -> boolean
	return function(racerId: number): boolean
		return table.find(missing, racerId) == nil
	end
end

local allPresent = presentExcept({})

TestRunner.describe("FinaleRoster.resolveStartingRoster - case 1, nobody left", function()
	TestRunner.it("keeps all three qualifiers, in rank order, with no announcements", function()
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, 4, allPresent)
		TestRunner.expect(#roster.qualifierIds):toBe(3)
		TestRunner.expect(roster.qualifierIds[1]):toBe(1)
		TestRunner.expect(roster.qualifierIds[3]):toBe(3)
		TestRunner.expect(#roster.changes):toBe(0)
	end)

	TestRunner.it("does not promote the alternate just because one exists", function()
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, 4, allPresent)
		TestRunner.expect(table.find(roster.qualifierIds, 4)):toBe(nil)
	end)
end)

TestRunner.describe("FinaleRoster.resolveStartingRoster - case 1, a qualifier left", function()
	TestRunner.it("promotes the 4th-place alternate into the vacated seat", function()
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, 4, presentExcept({ 2 }))
		TestRunner.expect(#roster.qualifierIds):toBe(3)
		TestRunner.expect(table.find(roster.qualifierIds, 2)):toBe(nil)
		TestRunner.expect(table.find(roster.qualifierIds, 4) ~= nil):toBe(true)
	end)

	TestRunner.it("reports who replaced whom, as a pair", function()
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, 4, presentExcept({ 2 }))
		TestRunner.expect(#roster.changes):toBe(1)
		TestRunner.expect(roster.changes[1].droppedId):toBe(2)
		TestRunner.expect(roster.changes[1].promotedId):toBe(4)
	end)

	TestRunner.it("runs the finale with two when no alternate exists at all", function()
		-- "If no alternate exists, run the finale with two and use the
		-- two-player outcome branch" - P3-7 case 1, verbatim.
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, nil, presentExcept({ 2 }))
		TestRunner.expect(#roster.qualifierIds):toBe(2)
		TestRunner.expect(#roster.changes):toBe(1)
		TestRunner.expect(roster.changes[1].promotedId):toBe(nil)
	end)

	TestRunner.it("runs with two when the alternate has ALSO left", function()
		-- The 4th-place finisher can leave in the same window. Promoting
		-- an absent player would just move the problem into the Studio,
		-- where Q4's harsher rule would hit someone who never got a seat.
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, 4, presentExcept({ 2, 4 }))
		TestRunner.expect(#roster.qualifierIds):toBe(2)
		TestRunner.expect(roster.changes[1].promotedId):toBe(nil)
	end)
end)

TestRunner.describe("FinaleRoster.resolveStartingRoster - case 1, several left", function()
	TestRunner.it("promotes the single alternate exactly once, then runs smaller", function()
		-- There is only ever ONE alternate (Qualification.rank returns
		-- `alternate: number?`), so two departures cannot both be filled.
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, 4, presentExcept({ 1, 2 }))
		TestRunner.expect(#roster.qualifierIds):toBe(2) -- the promoted alternate, plus 3
		TestRunner.expect(#roster.changes):toBe(2)
		TestRunner.expect(roster.changes[1].promotedId):toBe(4)
		TestRunner.expect(roster.changes[2].promotedId):toBe(nil)
	end)

	TestRunner.it("survives every qualifier leaving, leaving a solo finalist", function()
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, 4, presentExcept({ 1, 2, 3 }))
		TestRunner.expect(#roster.qualifierIds):toBe(1)
		TestRunner.expect(roster.qualifierIds[1]):toBe(4)
	end)

	TestRunner.it("returns an empty roster when literally nobody is left", function()
		-- DecisionService's own guard skips straight to Results on this;
		-- what matters here is that it doesn't error or invent a seat.
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, nil, presentExcept({ 1, 2, 3 }))
		TestRunner.expect(#roster.qualifierIds):toBe(0)
		TestRunner.expect(#roster.changes):toBe(3)
	end)

	TestRunner.it("never seats the same racer twice", function()
		-- A duplicate would be a silent double entry in Outcomes.resolve's
		-- input, which is far worse than an empty seat.
		local roster = FinaleRoster.resolveStartingRoster({ 1, 2, 3 }, 3, presentExcept({ 1 }))
		local seen: { [number]: boolean } = {}
		for _, id in roster.qualifierIds do
			TestRunner.expect(seen[id]):toBe(nil)
			seen[id] = true
		end
	end)

	TestRunner.it("handles an NPC seat the same as a human one - ids are just ids", function()
		-- NPCs qualify through the normal path (design-decisions.md Q5)
		-- and carry negative ids; a bot never "leaves," so it is simply
		-- always present.
		local roster = FinaleRoster.resolveStartingRoster({ 1, -1, 3 }, -2, presentExcept({ 1 }))
		TestRunner.expect(#roster.qualifierIds):toBe(3)
		TestRunner.expect(roster.changes[1].promotedId):toBe(-2)
	end)
end)

TestRunner.describe("FinaleRoster.classifyLeave - case 2, during Negotiate", function()
	TestRunner.it("substitutes the default choice and forfeits", function()
		local decision = FinaleRoster.classifyLeave("Negotiate", false, false)
		TestRunner.expect(decision.action):toBe("SubstituteDefault")
		TestRunner.expect(decision.forfeits):toBe(true)
	end)

	TestRunner.it("also applies during Intro, before anyone can have chosen", function()
		local decision = FinaleRoster.classifyLeave("Intro", false, false)
		TestRunner.expect(decision.action):toBe("SubstituteDefault")
		TestRunner.expect(decision.forfeits):toBe(true)
	end)
end)

TestRunner.describe("FinaleRoster.classifyLeave - case 3, Choose after locking in", function()
	TestRunner.it("keeps the locked choice and still forfeits", function()
		-- Both halves matter: a locked Steal must not become a Share on
		-- the way out, and leaving must still cost them the round.
		local decision = FinaleRoster.classifyLeave("Choose", true, false)
		TestRunner.expect(decision.action):toBe("KeepLockedChoice")
		TestRunner.expect(decision.forfeits):toBe(true)
	end)
end)

TestRunner.describe("FinaleRoster.classifyLeave - case 4, Choose without locking", function()
	TestRunner.it("substitutes the default choice and forfeits", function()
		local decision = FinaleRoster.classifyLeave("Choose", false, false)
		TestRunner.expect(decision.action):toBe("SubstituteDefault")
		TestRunner.expect(decision.forfeits):toBe(true)
	end)

	TestRunner.it("may complete the round, since the last open seat just closed", function()
		TestRunner.expect(FinaleRoster.classifyLeave("Choose", false, false).mayCompleteRound):toBe(true)
	end)
end)

TestRunner.describe("FinaleRoster.classifyLeave - case 5, after the result is written", function()
	TestRunner.it("changes nothing during Reveal", function()
		-- "The result was already written before the reveal, so nothing
		-- changes - prove this with a test" (P3-7 case 5, verbatim).
		local decision = FinaleRoster.classifyLeave("Reveal", true, true)
		TestRunner.expect(decision.action):toBe("AlreadyResolved")
		TestRunner.expect(decision.forfeits):toBe(false)
		TestRunner.expect(decision.mayCompleteRound):toBe(false)
	end)

	TestRunner.it("changes nothing during Resolve", function()
		local decision = FinaleRoster.classifyLeave("Resolve", true, true)
		TestRunner.expect(decision.action):toBe("AlreadyResolved")
		TestRunner.expect(decision.forfeits):toBe(false)
	end)

	TestRunner.it("adds no forfeit to a player who never locked in but whose result is final", function()
		-- Their default choice was already substituted and resolved by
		-- resolveAndReveal. A second forfeit here would be a loss applied
		-- on top of a result that already accounted for them.
		local decision = FinaleRoster.classifyLeave("Reveal", false, true)
		TestRunner.expect(decision.forfeits):toBe(false)
	end)

	TestRunner.it("cannot manufacture a loss for someone who just WON and then quit", function()
		-- The half a naive "leaving always forfeits" rule gets wrong.
		local decision = FinaleRoster.classifyLeave("Reveal", true, true)
		TestRunner.expect(decision.forfeits):toBe(false)
	end)

	TestRunner.it("treats a written outcome as final even while the phase still says Choose", function()
		-- The writes happen at the END of Choose, inside the same
		-- synchronous call that enters Reveal - so for a moment both
		-- "we are in Choose" and "the result is final" are true, and
		-- only the second one may decide this.
		local decision = FinaleRoster.classifyLeave("Choose", true, true)
		TestRunner.expect(decision.action):toBe("AlreadyResolved")
		TestRunner.expect(decision.forfeits):toBe(false)
	end)
end)

TestRunner.describe("FinaleRoster.shutdownPolicy - case 6", function()
	TestRunner.it("preserves every streak when the finale never resolved", function()
		-- A player cannot trigger a BindToClose, so the
		-- disconnect-to-dodge reasoning behind Q4's forfeit doesn't apply
		-- and there's nothing to defend against by punishing them.
		TestRunner.expect(FinaleRoster.shutdownPolicy(false)):toBe("PreserveStreaks")
	end)

	TestRunner.it("keeps the written result when the finale already resolved", function()
		TestRunner.expect(FinaleRoster.shutdownPolicy(true)):toBe("KeepWrittenResult")
	end)
end)
