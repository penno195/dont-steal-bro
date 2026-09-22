--!strict
-- Covers LeaderboardLogic.luau (P4-3): the write rule, the request
-- budget, backoff, cache staleness and entry ranking.
-- LeaderboardService.luau isn't required here - it touches
-- OrderedDataStore and a real clock, so it's exercised in Studio, the
-- same split every other spec in this suite uses.
--
-- These cases matter more than most: P4-3's own framing is that
-- "request budgets and write amplification cause outages that only
-- appear at scale," and an outage that only appears at 20,000
-- concurrent players cannot be reproduced in Studio. If the budget
-- arithmetic isn't right here, it isn't checkable until it's live.

local TestRunner = require("./TestRunner")
local LeaderboardLogic = require("../src/server/LeaderboardLogic")

local LIMITS: LeaderboardLogic.BudgetLimits = {
	perWindow = 100,
	windowSeconds = 60,
	softCeiling = 0.7,
}

TestRunner.describe("LeaderboardLogic.shouldWrite", function()
	TestRunner.it("writes the first time a player is seen with a real streak", function()
		TestRunner.expect(LeaderboardLogic.shouldWrite(nil, 3)):toBe(true)
	end)

	TestRunner.it("writes only on a genuine improvement", function()
		TestRunner.expect(LeaderboardLogic.shouldWrite(5, 6)):toBe(true)
		TestRunner.expect(LeaderboardLogic.shouldWrite(5, 5)):toBe(false)
		TestRunner.expect(LeaderboardLogic.shouldWrite(5, 4)):toBe(false)
	end)

	TestRunner.it("never writes a zero - nobody is ranked for never having won", function()
		TestRunner.expect(LeaderboardLogic.shouldWrite(nil, 0)):toBe(false)
	end)

	TestRunner.it("is what stops a 6-player round costing 6 writes every time", function()
		-- Write amplification, stated as a case: a server running rounds
		-- back to back with nobody improving should issue nothing at all.
		local written = 0
		for _ = 1, 20 do
			if LeaderboardLogic.shouldWrite(8, 8) then
				written += 1
			end
		end
		TestRunner.expect(written):toBe(0)
	end)
end)

TestRunner.describe("LeaderboardLogic - the request budget", function()
	TestRunner.it("starts empty and reports zero pressure", function()
		TestRunner.expect(LeaderboardLogic.budgetPressure(LeaderboardLogic.newBudget(0), LIMITS)):toBe(0)
	end)

	TestRunner.it("tracks pressure as a fraction of the window's allowance", function()
		local state = LeaderboardLogic.spend(LeaderboardLogic.newBudget(0), 35)
		TestRunner.expect(LeaderboardLogic.budgetPressure(state, LIMITS)):toBeCloseTo(0.35)
	end)

	TestRunner.it("reports pressure above 1 rather than clamping it", function()
		-- The number that says an outage is coming is worth seeing.
		local state = LeaderboardLogic.spend(LeaderboardLogic.newBudget(0), 130)
		TestRunner.expect(LeaderboardLogic.budgetPressure(state, LIMITS)):toBeCloseTo(1.3)
	end)

	TestRunner.it("resets the window once it has elapsed", function()
		local state = LeaderboardLogic.spend(LeaderboardLogic.newBudget(0), 90)
		local rolled = LeaderboardLogic.rollWindow(state, 61, LIMITS)
		TestRunner.expect(rolled.spent):toBe(0)
		TestRunner.expect(rolled.windowStartedAt):toBe(61)
	end)

	TestRunner.it("leaves the window alone before it elapses", function()
		local state = LeaderboardLogic.spend(LeaderboardLogic.newBudget(0), 90)
		TestRunner.expect(LeaderboardLogic.rollWindow(state, 59, LIMITS).spent):toBe(90)
	end)

	TestRunner.it("does not mutate the state handed in", function()
		local state = LeaderboardLogic.newBudget(0)
		LeaderboardLogic.spend(state, 10)
		TestRunner.expect(state.spent):toBe(0)
	end)
end)

TestRunner.describe("LeaderboardLogic.mayRequest - writes outrank reads", function()
	TestRunner.it("allows both while the budget is comfortable", function()
		local state = LeaderboardLogic.spend(LeaderboardLogic.newBudget(0), 10)
		TestRunner.expect(LeaderboardLogic.mayRequest(state, LIMITS, "Read")):toBe(true)
		TestRunner.expect(LeaderboardLogic.mayRequest(state, LIMITS, "Write")):toBe(true)
	end)

	TestRunner.it("refuses reads past the soft ceiling but still allows writes", function()
		-- The asymmetry is the design: a board one cycle stale is
		-- invisible; a dropped write is a record that silently didn't
		-- count.
		local state = LeaderboardLogic.spend(LeaderboardLogic.newBudget(0), 75)
		TestRunner.expect(LeaderboardLogic.mayRequest(state, LIMITS, "Read")):toBe(false)
		TestRunner.expect(LeaderboardLogic.mayRequest(state, LIMITS, "Write")):toBe(true)
	end)

	TestRunner.it("refuses writes only at the hard limit", function()
		local state = LeaderboardLogic.spend(LeaderboardLogic.newBudget(0), 100)
		TestRunner.expect(LeaderboardLogic.mayRequest(state, LIMITS, "Write")):toBe(false)
	end)

	TestRunner.it("refuses everything on a zero budget rather than dividing by it", function()
		local zero: LeaderboardLogic.BudgetLimits = { perWindow = 0, windowSeconds = 60, softCeiling = 0.7 }
		local state = LeaderboardLogic.newBudget(0)
		TestRunner.expect(LeaderboardLogic.mayRequest(state, zero, "Read")):toBe(false)
		TestRunner.expect(LeaderboardLogic.mayRequest(state, zero, "Write")):toBe(false)
	end)
end)

TestRunner.describe("LeaderboardLogic.backoffSeconds", function()
	TestRunner.it("waits nothing before the first attempt", function()
		TestRunner.expect(LeaderboardLogic.backoffSeconds(0, 1, 60, 1)):toBe(0)
	end)

	TestRunner.it("doubles the ceiling each attempt", function()
		TestRunner.expect(LeaderboardLogic.backoffSeconds(1, 1, 60, 1)):toBe(1)
		TestRunner.expect(LeaderboardLogic.backoffSeconds(2, 1, 60, 1)):toBe(2)
		TestRunner.expect(LeaderboardLogic.backoffSeconds(3, 1, 60, 1)):toBe(4)
		TestRunner.expect(LeaderboardLogic.backoffSeconds(5, 1, 60, 1)):toBe(16)
	end)

	TestRunner.it("stops doubling at the cap", function()
		TestRunner.expect(LeaderboardLogic.backoffSeconds(20, 1, 60, 1)):toBe(60)
	end)

	TestRunner.it("uses FULL jitter - the delay spans zero to the ceiling", function()
		-- Not exponential-plus-a-wobble. When a DataStore has a bad
		-- minute every server fails at once, and a fixed backoff keeps
		-- them synchronised so the retry storm lands in a spike as hard
		-- as the failure. Full jitter spreads the same retries flat.
		TestRunner.expect(LeaderboardLogic.backoffSeconds(4, 1, 60, 0)):toBe(0)
		TestRunner.expect(LeaderboardLogic.backoffSeconds(4, 1, 60, 0.5)):toBe(4)
		TestRunner.expect(LeaderboardLogic.backoffSeconds(4, 1, 60, 1)):toBe(8)
	end)

	TestRunner.it("never returns a negative delay for a roll outside the range", function()
		assert(LeaderboardLogic.backoffSeconds(3, 1, 60, -5) >= 0, "negative backoff")
	end)
end)

TestRunner.describe("LeaderboardLogic.cacheStatus", function()
	TestRunner.it("is Empty before anything has ever been fetched", function()
		TestRunner.expect(LeaderboardLogic.cacheStatus(nil, 100, 300, false)):toBe("Empty")
	end)

	TestRunner.it("is Empty when a fetch succeeded but returned nothing", function()
		TestRunner.expect(LeaderboardLogic.cacheStatus(0, 10, 300, false)):toBe("Empty")
	end)

	TestRunner.it("is Fresh inside the staleness window", function()
		TestRunner.expect(LeaderboardLogic.cacheStatus(0, 120, 300, true)):toBe("Fresh")
	end)

	TestRunner.it("is Stale past it - but still has entries to serve", function()
		-- P4-3: serve the stale cache with an indicator, never an empty
		-- board.
		TestRunner.expect(LeaderboardLogic.cacheStatus(0, 400, 300, true)):toBe("Stale")
	end)

	TestRunner.it("goes Stale rather than Empty during a long outage", function()
		-- The case that matters: the store has been down for an hour and
		-- the board must still show something, flagged as old.
		TestRunner.expect(LeaderboardLogic.cacheStatus(0, 3600, 300, true)):toBe("Stale")
	end)
end)

TestRunner.describe("LeaderboardLogic.nextRefreshDelay", function()
	TestRunner.it("stays inside the configured range", function()
		for step = 0, 100 do
			local delay = LeaderboardLogic.nextRefreshDelay(60, 120, step / 100)
			assert(delay >= 60 and delay <= 120, string.format("%.2f is outside 60-120", delay))
		end
	end)

	TestRunner.it("spreads across the range rather than picking one value", function()
		-- A thousand servers all reading on a 60-second boundary is a
		-- thousand reads in one second, sixty times an hour, and the
		-- spike is entirely self-inflicted.
		local low = LeaderboardLogic.nextRefreshDelay(60, 120, 0)
		local high = LeaderboardLogic.nextRefreshDelay(60, 120, 1)
		TestRunner.expect(low):toBe(60)
		TestRunner.expect(high):toBe(120)
	end)

	TestRunner.it("tolerates the bounds being handed over the wrong way round", function()
		TestRunner.expect(LeaderboardLogic.nextRefreshDelay(120, 60, 0)):toBe(60)
	end)
end)

TestRunner.describe("LeaderboardLogic.displayNameFor", function()
	TestRunner.it("uses the resolved name when there is one", function()
		TestRunner.expect(LeaderboardLogic.displayNameFor("Racer", 7)):toBe("Racer")
	end)

	TestRunner.it("falls back to a stable placeholder for a deleted account", function()
		-- The rank is kept: dropping the row would silently renumber
		-- everyone below it, and two servers would disagree about who is
		-- 4th depending on which lookups happened to fail.
		TestRunner.expect(LeaderboardLogic.displayNameFor(nil, 7)):toBe("Player 7")
		TestRunner.expect(LeaderboardLogic.displayNameFor("", 7)):toBe("Player 7")
	end)
end)

TestRunner.describe("LeaderboardLogic.rank", function()
	local function entry(userId: number, bestStreak: number): LeaderboardLogic.Entry
		return { userId = userId, bestStreak = bestStreak, displayName = "P" .. userId }
	end

	TestRunner.it("sorts by streak, highest first", function()
		local ranked = LeaderboardLogic.rank({ entry(1, 3), entry(2, 9), entry(3, 5) })
		TestRunner.expect(ranked[1].userId):toBe(2)
		TestRunner.expect(ranked[3].userId):toBe(1)
	end)

	TestRunner.it("breaks ties by userId so every server agrees", function()
		-- Two servers disagreeing about who is 4th versus 5th is the
		-- kind of thing players screenshot.
		local ranked = LeaderboardLogic.rank({ entry(9, 5), entry(2, 5), entry(5, 5) })
		TestRunner.expect(ranked[1].userId):toBe(2)
		TestRunner.expect(ranked[2].userId):toBe(5)
		TestRunner.expect(ranked[3].userId):toBe(9)
	end)

	TestRunner.it("does not sort the caller's list in place", function()
		local entries = { entry(1, 1), entry(2, 9) }
		LeaderboardLogic.rank(entries)
		TestRunner.expect(entries[1].userId):toBe(1)
	end)
end)

TestRunner.describe("LeaderboardLogic.dedupe", function()
	local function entry(userId: number, bestStreak: number): LeaderboardLogic.Entry
		return { userId = userId, bestStreak = bestStreak, displayName = "P" .. userId }
	end

	TestRunner.it("keeps the highest streak when a page boundary repeats a key", function()
		-- A write landing between two GetSortedAsync page fetches can
		-- legitimately return the same key twice.
		local deduped = LeaderboardLogic.dedupe({ entry(1, 4), entry(2, 8), entry(1, 6) })
		TestRunner.expect(#deduped):toBe(2)
		TestRunner.expect(deduped[1].bestStreak):toBe(6)
	end)

	TestRunner.it("leaves a clean page untouched", function()
		TestRunner.expect(#LeaderboardLogic.dedupe({ entry(1, 4), entry(2, 8) })):toBe(2)
	end)

	TestRunner.it("preserves first-seen order", function()
		local deduped = LeaderboardLogic.dedupe({ entry(3, 1), entry(1, 2), entry(3, 5) })
		TestRunner.expect(deduped[1].userId):toBe(3)
		TestRunner.expect(deduped[2].userId):toBe(1)
	end)
end)
