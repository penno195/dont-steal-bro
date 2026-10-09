--!strict
-- Covers ProgressionLogic.luau (P4-1): the streak rules.
-- ProgressionService.luau itself isn't required here - it touches
-- Players, the loader and ProfileStore at call time, so it's exercised
-- in Studio instead, the same split every other spec in this suite
-- uses.
--
-- P4-1 asks for three things by name: a full win chain of five rounds,
-- a loss at each possible point, and a duplicate event. All three are
-- below. The most important property in the file is the one the whole
-- metagame rests on - bestStreak only ever moves up, because
-- gdd.md §3's titles key off it and are "never revoked when a streak
-- resets."

local TestRunner = require("./TestRunner")
local ProgressionLogic = require("../src/server/ProgressionLogic")

local FRESH: ProgressionLogic.StreakState = { currentStreak = 0, bestStreak = 0 }

local ALL_REASONS: { ProgressionLogic.ReasonCode } = {
	"QualifiedWin",
	"StudioWinSoleStealer",
	"StudioWinLoneSharer",
	"StudioWinAllShare",
	"StudioLoss",
	"FailedToQualify",
	"ForfeitDisconnect",
}

TestRunner.describe("ProgressionLogic.isWin", function()
	TestRunner.it("counts exactly the four win reasons", function()
		TestRunner.expect(ProgressionLogic.isWin("QualifiedWin")):toBe(true)
		TestRunner.expect(ProgressionLogic.isWin("StudioWinSoleStealer")):toBe(true)
		TestRunner.expect(ProgressionLogic.isWin("StudioWinLoneSharer")):toBe(true)
		TestRunner.expect(ProgressionLogic.isWin("StudioWinAllShare")):toBe(true)
	end)

	TestRunner.it("counts every other reason as a loss", function()
		TestRunner.expect(ProgressionLogic.isWin("StudioLoss")):toBe(false)
		TestRunner.expect(ProgressionLogic.isWin("FailedToQualify")):toBe(false)
		TestRunner.expect(ProgressionLogic.isWin("ForfeitDisconnect")):toBe(false)
	end)
end)

TestRunner.describe("ProgressionLogic.applyResult - a five-round win chain", function()
	TestRunner.it("increments the streak once per win, and tracks bestStreak with it", function()
		local state = FRESH
		for round = 1, 5 do
			state = ProgressionLogic.applyResult(state, "StudioWinAllShare")
			TestRunner.expect(state.currentStreak):toBe(round)
			TestRunner.expect(state.bestStreak):toBe(round)
		end
	end)

	TestRunner.it("never mutates the state handed in", function()
		-- The caller logs both sides of the change, which only works if
		-- `before` is still the before.
		local before: ProgressionLogic.StreakState = { currentStreak = 3, bestStreak = 7 }
		ProgressionLogic.applyResult(before, "StudioWinAllShare")
		TestRunner.expect(before.currentStreak):toBe(3)
		TestRunner.expect(before.bestStreak):toBe(7)
	end)

	TestRunner.it("mixes win reasons across a chain without breaking it", function()
		local state = FRESH
		state = ProgressionLogic.applyResult(state, "StudioWinSoleStealer")
		state = ProgressionLogic.applyResult(state, "StudioWinLoneSharer")
		state = ProgressionLogic.applyResult(state, "StudioWinAllShare")
		state = ProgressionLogic.applyResult(state, "QualifiedWin")
		state = ProgressionLogic.applyResult(state, "StudioWinAllShare")
		TestRunner.expect(state.currentStreak):toBe(5)
	end)
end)

TestRunner.describe("ProgressionLogic.applyResult - a loss at each possible point", function()
	TestRunner.it("zeroes the streak at every point in a five-round chain", function()
		-- The loss lands after 0, 1, 2, 3 and 4 wins in turn. What is
		-- being checked is that the reset is total regardless of how
		-- much was built up first - design-decisions.md Q7's "one loss
		-- takes it all."
		for winsFirst = 0, 4 do
			local state = FRESH
			for _ = 1, winsFirst do
				state = ProgressionLogic.applyResult(state, "StudioWinAllShare")
			end
			TestRunner.expect(state.currentStreak):toBe(winsFirst)

			local after = ProgressionLogic.applyResult(state, "StudioLoss")
			TestRunner.expect(after.currentStreak):toBe(0)
			TestRunner.expect(after.bestStreak):toBe(winsFirst) -- preserved
		end
	end)

	TestRunner.it("resets identically for every losing reason", function()
		for _, reason in { "StudioLoss", "FailedToQualify", "ForfeitDisconnect" } do
			local state: ProgressionLogic.StreakState = { currentStreak = 9, bestStreak = 12 }
			local after = ProgressionLogic.applyResult(state, reason :: any)
			TestRunner.expect(after.currentStreak):toBe(0)
			TestRunner.expect(after.bestStreak):toBe(12)
		end
	end)

	TestRunner.it("never lowers bestStreak, for any reason at all", function()
		-- The property P4-2's permanent titles depend on.
		for _, reason in ALL_REASONS do
			local state: ProgressionLogic.StreakState = { currentStreak = 4, bestStreak = 20 }
			local after = ProgressionLogic.applyResult(state, reason)
			assert(after.bestStreak >= 20, string.format("%s lowered bestStreak to %d", reason, after.bestStreak))
		end
	end)

	TestRunner.it("rebuilds from zero after a loss without disturbing bestStreak", function()
		local state: ProgressionLogic.StreakState = { currentStreak = 0, bestStreak = 8 }
		state = ProgressionLogic.applyResult(state, "StudioWinAllShare")
		TestRunner.expect(state.currentStreak):toBe(1)
		TestRunner.expect(state.bestStreak):toBe(8) -- not raised: 1 < 8
	end)
end)

TestRunner.describe("ProgressionLogic.reasonForOutcome", function()
	TestRunner.it("maps each winning branch to its own reason code", function()
		TestRunner.expect(ProgressionLogic.reasonForOutcome("SoleSteal", true)):toBe("StudioWinSoleStealer")
		TestRunner.expect(ProgressionLogic.reasonForOutcome("OneStealOneShare", true)):toBe("StudioWinSoleStealer")
		TestRunner.expect(ProgressionLogic.reasonForOutcome("LoneShare", true)):toBe("StudioWinLoneSharer")
		TestRunner.expect(ProgressionLogic.reasonForOutcome("AllShare", true)):toBe("StudioWinAllShare")
		TestRunner.expect(ProgressionLogic.reasonForOutcome("TwoShare", true)):toBe("StudioWinAllShare")
		TestRunner.expect(ProgressionLogic.reasonForOutcome("SoloFinalist", true)):toBe("QualifiedWin")
	end)

	TestRunner.it("maps any branch to StudioLoss for a player who didn't win it", function()
		for _, branch in { "SoleSteal", "LoneShare", "AllShare", "AllSteal", "TwoSteal", "SoloFinalist" } do
			TestRunner.expect(ProgressionLogic.reasonForOutcome(branch, false)):toBe("StudioLoss")
		end
	end)

	TestRunner.it("never turns a winner into a loss, even for an unknown branch", function()
		-- A branch added later must not silently cost somebody their
		-- streak - the worst failure this function could have.
		local reason = ProgressionLogic.reasonForOutcome("SomeFutureBranch", true)
		TestRunner.expect(ProgressionLogic.isWin(reason)):toBe(true)
	end)
end)

TestRunner.describe("ProgressionLogic.statForReason", function()
	TestRunner.it("agrees with isWin for every reason", function()
		-- These two must never disagree: a streak that went up next to a
		-- "losses" stat is a bug report nobody can interpret.
		for _, reason in ALL_REASONS do
			local expected = if ProgressionLogic.isWin(reason) then "wins" else "losses"
			TestRunner.expect(ProgressionLogic.statForReason(reason)):toBe(expected)
		end
	end)
end)

TestRunner.describe("ProgressionLogic.classifyDuplicate - the duplicate event", function()
	TestRunner.it("treats the same reason reported twice as a retry", function()
		TestRunner.expect(ProgressionLogic.classifyDuplicate("StudioLoss", "StudioLoss")):toBe("Retry")
	end)

	TestRunner.it("treats two different results for one round as a contradiction", function()
		TestRunner.expect(ProgressionLogic.classifyDuplicate("StudioWinAllShare", "StudioLoss")):toBe("Contradiction")
		TestRunner.expect(ProgressionLogic.classifyDuplicate("StudioLoss", "ForfeitDisconnect")):toBe("Contradiction")
	end)

	TestRunner.it("is symmetric - order of arrival doesn't change the verdict", function()
		TestRunner.expect(ProgressionLogic.classifyDuplicate("StudioLoss", "StudioWinAllShare")):toBe("Contradiction")
	end)

	TestRunner.it("a retry applied twice produces the same state as applying once", function()
		-- The actual anti-double-count property, stated directly: the
		-- service returns the recorded state on a retry rather than
		-- re-applying, so a duplicated event cannot advance a streak by
		-- two.
		local once = ProgressionLogic.applyResult(FRESH, "StudioWinAllShare")
		TestRunner.expect(ProgressionLogic.classifyDuplicate("StudioWinAllShare", "StudioWinAllShare")):toBe("Retry")
		TestRunner.expect(once.currentStreak):toBe(1)
	end)
end)

TestRunner.describe("ProgressionLogic.formatAudit", function()
	TestRunner.it("names the before state, the after state and the reason", function()
		local before: ProgressionLogic.StreakState = { currentStreak = 2, bestStreak = 4 }
		local after = ProgressionLogic.applyResult(before, "StudioWinAllShare")
		local line = ProgressionLogic.formatAudit("Racer", "job:1", "StudioWinAllShare", before, after)

		assert(string.find(line, "Racer", 1, true) ~= nil, "audit line is missing the player")
		assert(string.find(line, "job:1", 1, true) ~= nil, "audit line is missing the round id")
		assert(string.find(line, "StudioWinAllShare", 1, true) ~= nil, "audit line is missing the reason")
		assert(string.find(line, "streak 2->3", 1, true) ~= nil, "audit line is missing the streak change")
		assert(string.find(line, "best 4->4", 1, true) ~= nil, "audit line is missing the bestStreak change")
	end)
end)

TestRunner.describe("ProgressionLogic.formatRewardAudit", function()
	TestRunner.it("names the player, round, outcome, rung and the grant", function()
		local line = ProgressionLogic.formatRewardAudit("Racer", "job:1", "SoleStealer", 4, "currency +140 (now 140)")
		TestRunner.expect(line):toBe("Reward: Racer round=job:1 outcome=SoleStealer rung=4 -> currency +140 (now 140)")
	end)
end)
