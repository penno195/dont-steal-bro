--!strict
-- The all-time leaderboard's arithmetic (P4-3): when a write is worth
-- making, how much of the per-server DataStore request budget is left,
-- how long to back off after a failure, whether the cached board is
-- still worth serving, and how to render a display name for an account
-- that has been renamed or deleted.
-- LeaderboardService.luau is the Roblox-touching wrapper that owns the
-- real OrderedDataStore, the real clock and the real polling loop.
--
-- WHY THIS SPLIT MATTERS MORE HERE THAN USUAL: P4-3's own framing is
-- "request budgets and write amplification cause outages that only
-- appear at scale." An outage that only appears at 20,000 concurrent
-- players is, by definition, one you cannot reproduce in Studio - so
-- the budget and backoff arithmetic has to be checkable without a
-- DataStore at all, or it is not checkable until it is already live.
-- Ground Rule 4, for a reason that isn't just tidiness.
--
-- ===== EVERY LIMIT HERE IS AN INPUT, NEVER A HARDCODED NUMBER ==========
--
-- CLAUDE.md is explicit that Roblox APIs and limits shift and are easy
-- to misremember, and P4-3 asks for anything needing verification to be
-- flagged. So this module knows NO Roblox limits. It is handed a budget
-- and told what was spent; the actual figures live in
-- GameConfig.leaderboard, marked for verification against current
-- documentation, and docs/leaderboard-scale.md is where they get
-- checked. A limit that turns out to be wrong is then a config edit,
-- not a hunt through arithmetic.

local LeaderboardLogic = {}

-- ===== writes: only on a real improvement ==============================

-- P4-3: "write only when a player's bestStreak actually improves."
--
-- The check exists twice on purpose, and this is the cheap half: this
-- one avoids spending a request at all, and the UpdateAsync max
-- comparison in the service is what makes a lower value unable to
-- overwrite a higher one even if two servers race. Skipping either
-- would be a mistake - this one alone loses the race, that one alone
-- burns budget on every no-op round.
--
-- `lastWrittenBest` is what THIS server last successfully wrote for the
-- player, not what the store holds: a server that has never written for
-- them passes nil and the first improvement always goes out.
function LeaderboardLogic.shouldWrite(lastWrittenBest: number?, newBest: number): boolean
	if newBest <= 0 then
		return false -- nobody is ranked for never having won
	end
	if lastWrittenBest == nil then
		return true
	end
	return newBest > lastWrittenBest
end

-- ===== the request budget ==============================================

export type BudgetState = {
	-- Requests spent inside the current window.
	spent: number,
	-- When the current window started, on the caller's own clock.
	windowStartedAt: number,
}

export type BudgetLimits = {
	-- How many requests this server may make per window. Supplied by
	-- the caller from config - see this file's header on why no Roblox
	-- figure is baked in here.
	perWindow: number,
	windowSeconds: number,
	-- Stop issuing discretionary requests once this fraction of the
	-- budget is gone, leaving the rest for writes that matter. A read
	-- is discretionary (the cache can go one cycle stale); a
	-- best-streak write is not.
	softCeiling: number,
}

function LeaderboardLogic.newBudget(now: number): BudgetState
	return { spent = 0, windowStartedAt = now }
end

-- Rolls the window forward if it has elapsed, and returns the state to
-- use. Pure: returns a new state rather than mutating, so a caller can
-- compare before and after.
function LeaderboardLogic.rollWindow(state: BudgetState, now: number, limits: BudgetLimits): BudgetState
	if now - state.windowStartedAt < limits.windowSeconds then
		return state
	end
	return { spent = 0, windowStartedAt = now }
end

-- The metric P4-3 asks for: "how close to the limit the game is
-- running", as a fraction in [0, 1+]. Above 1 means the budget was
-- genuinely exceeded, which is worth seeing rather than clamping away -
-- it is the number that says an outage is coming.
function LeaderboardLogic.budgetPressure(state: BudgetState, limits: BudgetLimits): number
	if limits.perWindow <= 0 then
		return 1
	end
	return state.spent / limits.perWindow
end

export type RequestKind = "Write" | "Read"

-- Whether a request may be issued now.
--
-- The asymmetry is the whole point. A READ is refused once pressure
-- passes the soft ceiling, because the board going one cycle stale is
-- invisible to players and the cache already covers it. A WRITE is
-- refused only at the hard limit, because a dropped write is a player's
-- record silently not counting - the thing the leaderboard exists to
-- get right. When budget is short, correctness spends it.
function LeaderboardLogic.mayRequest(state: BudgetState, limits: BudgetLimits, kind: RequestKind): boolean
	local pressure = LeaderboardLogic.budgetPressure(state, limits)
	if kind == "Read" then
		return pressure < limits.softCeiling
	end
	return state.spent < limits.perWindow
end

function LeaderboardLogic.spend(state: BudgetState, count: number?): BudgetState
	return { spent = state.spent + (count or 1), windowStartedAt = state.windowStartedAt }
end

-- ===== backoff =========================================================

-- Exponential backoff with FULL jitter: the delay is drawn uniformly
-- from [0, exponential], not set to exponential-plus-a-wobble.
--
-- That matters at scale and is the whole reason jitter is in P4-3's
-- requirements. When a DataStore has a bad minute, every server in the
-- game fails at once and then retries at once - and a fixed backoff
-- keeps them synchronised forever, so the retry storm lands in a spike
-- exactly as hard as the one that caused the failure. Full jitter
-- spreads the same number of retries flat across the window. The cost
-- is that an individual retry can come back almost immediately, which
-- is fine: it is one server, not all of them.
--
-- `roll` is a value in [0, 1) from the caller's own RNG, so this stays
-- pure and a test can pin the result.
function LeaderboardLogic.backoffSeconds(attempt: number, baseSeconds: number, capSeconds: number, roll: number): number
	if attempt <= 0 then
		return 0
	end
	local exponential = math.min(baseSeconds * (2 ^ (attempt - 1)), capSeconds)
	return math.clamp(roll, 0, 1) * exponential
end

-- ===== the cache =======================================================

export type CacheStatus =
	-- Refreshed within its normal interval; nothing to say to the UI.
	"Fresh"
	-- Older than expected but still worth showing. The UI must say so -
	-- P4-3: "serve the stale cache and show a clear staleness
	-- indicator, never an empty board."
	| "Stale"
	-- Nothing has ever been fetched. The only case where an empty board
	-- is honest, because there is genuinely nothing to show yet.
	| "Empty"

-- `lastRefreshAt` is nil when no fetch has ever succeeded.
function LeaderboardLogic.cacheStatus(
	lastRefreshAt: number?,
	now: number,
	staleAfterSeconds: number,
	hasEntries: boolean
): CacheStatus
	if lastRefreshAt == nil or not hasEntries then
		return "Empty"
	end
	if now - lastRefreshAt > staleAfterSeconds then
		return "Stale"
	end
	return "Fresh"
end

-- When the next poll should happen, in seconds from now. P4-3 asks for
-- "once per server on an interval of 60 to 120 seconds"; the interval
-- is drawn from that range per cycle rather than fixed, for the same
-- reason the backoff is jittered - a thousand servers all reading on a
-- 60-second boundary is a thousand reads in one second, sixty times an
-- hour, and the spike is entirely self-inflicted.
function LeaderboardLogic.nextRefreshDelay(minSeconds: number, maxSeconds: number, roll: number): number
	local low = math.min(minSeconds, maxSeconds)
	local high = math.max(minSeconds, maxSeconds)
	return low + math.clamp(roll, 0, 1) * (high - low)
end

-- ===== entries =========================================================

export type Entry = {
	userId: number,
	bestStreak: number,
	displayName: string,
}

-- P4-3: "resolve display names from user ids with a cache, handling
-- deleted and renamed accounts."
--
-- RENAMED is the easy half and is handled by the cache having a TTL -
-- the service re-resolves eventually, and a stale name for a few
-- minutes is not a problem worth a request.
--
-- DELETED is the half that needs a decision, because the id keeps its
-- rank in the store forever while the account behind it is gone.
-- Dropping the row would silently renumber everyone below it and make
-- the board disagree with itself between servers depending on which
-- lookups happened to fail. So the rank is kept and the name falls back
-- to a stable placeholder derived from the id - the position is real
-- and was really earned, and that is what the board is claiming.
function LeaderboardLogic.displayNameFor(resolved: string?, userId: number): string
	if resolved ~= nil and resolved ~= "" then
		return resolved
	end
	return string.format("Player %d", userId)
end

-- Sorts descending by streak, breaking ties by ascending userId so the
-- order is total and identical on every server. OrderedDataStore
-- already returns sorted pages, but ties come back in an unspecified
-- order, and two servers disagreeing about who is 4th versus 5th is the
-- kind of thing players screenshot.
function LeaderboardLogic.rank(entries: { Entry }): { Entry }
	local sorted = table.clone(entries)
	table.sort(sorted, function(a, b)
		if a.bestStreak == b.bestStreak then
			return a.userId < b.userId
		end
		return a.bestStreak > b.bestStreak
	end)
	return sorted
end

-- Drops duplicate userIds, keeping the highest streak seen for each.
-- A page boundary can legitimately hand back the same key twice if a
-- write lands between two GetSortedAsync page fetches.
function LeaderboardLogic.dedupe(entries: { Entry }): { Entry }
	local bestById: { [number]: Entry } = {}
	local order: { number } = {}

	for _, entry in entries do
		local existing = bestById[entry.userId]
		if existing == nil then
			bestById[entry.userId] = entry
			table.insert(order, entry.userId)
		elseif entry.bestStreak > existing.bestStreak then
			bestById[entry.userId] = entry
		end
	end

	local result: { Entry } = {}
	for _, userId in order do
		table.insert(result, bestById[userId])
	end
	return result
end

return LeaderboardLogic
