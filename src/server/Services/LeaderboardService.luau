--!strict
-- The all-time highest-streak leaderboard (P4-3). Owns the
-- OrderedDataStore, the once-per-server poll, the name cache and the
-- request budget. The arithmetic - when a write is worth making, how
-- much budget is left, how long to back off, whether the cache is
-- stale - is pure and lives in LeaderboardLogic.luau, tested headlessly
-- because an outage that only appears at 20,000 concurrent players
-- cannot be reproduced in Studio.
--
-- ===== API SURFACE, VERIFIED NOT RECALLED ===============================
--
-- CLAUDE.md warns that Roblox APIs are easy to misremember. Every call
-- below was checked against this repo's own pinned definitions file
-- (globalTypes.d.luau, luau-lsp 1.69.0) before being written:
--
--   DataStoreService:GetOrderedDataStore(name, scope?) -> OrderedDataStore
--   DataStoreService:GetRequestBudgetForRequestType(EnumDataStoreRequestType) -> number
--   OrderedDataStore:GetSortedAsync(ascending, pageSize, min?, max?) -> DataStorePages
--   OrderedDataStore:UpdateAsync(key, (number?, DataStoreKeyInfo) -> number)
--   Pages.IsFinished / :GetCurrentPage() / :AdvanceToNextPageAsync()
--   UserService:GetUserInfosByUserIdsAsync({userId}) -> {{Id, Username, DisplayName}}
--
-- The SIGNATURES are verified. The numeric LIMITS are not, and cannot
-- be from a type definitions file - see docs/leaderboard-scale.md for
-- what has to be checked against current documentation before launch.
--
-- ===== TWO BUDGET SOURCES, AND WHY BOTH ================================
--
-- Roblox exposes the real remaining budget via
-- GetRequestBudgetForRequestType, and that is authoritative: it is the
-- engine's own count, and no local estimate can beat it for "will this
-- call actually go through." So it is the hard gate.
--
-- The local accounting in LeaderboardLogic is kept anyway, for two
-- things the engine's number can't give: a PRESSURE METRIC over a
-- window (P4-3 asks for "a metric for how close to the limit the game
-- is running", which is a trend, not an instant), and the soft ceiling
-- that makes reads yield to writes before either is actually refused.
-- The engine says what is possible; the policy says what is wise.

local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserService = game:GetService("UserService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LeaderboardLogic = require(ServerScriptService.Server.LeaderboardLogic)
local PeriodKeys = require(ServerScriptService.Server.PeriodKeys)

local config = GameConfig.leaderboard

local store: OrderedDataStore? = nil
local cachedEntries: { LeaderboardLogic.Entry } = {}
local lastRefreshAt: number? = nil
local lastWrittenBest: { [number]: number } = {}
local budget = LeaderboardLogic.newBudget(0)
local pollThread: thread? = nil

-- P4-4: the regular DataStore holding frozen standings for FINISHED
-- periods. Deliberately a different store from the live MemoryStore
-- maps - a snapshot has to outlive every TTL, since yesterday's
-- winners are still worth showing and still owe a reward.
local snapshotStore: DataStore? = nil

-- P4-4's reward hook. A no-op until something claims it, because what a
-- period win is WORTH is a progression decision (design-decisions.md
-- Q1's still-unbuilt RewardTables), not a leaderboard one. Fired only
-- by the server that won the snapshot race, so exactly once per period
-- across the whole universe.
local periodRewardHandler: (kind: string, periodKey: string, rank: number, userId: number, streak: number) -> () = function(
	kind: string,
	periodKey: string,
	rank: number,
	userId: number,
	streak: number
)
	print(
		string.format(
			"LeaderboardService: %s %s rank %d - user %d with streak %d (no reward handler set)",
			kind,
			periodKey,
			rank,
			userId,
			streak
		)
	)
end

-- userId -> {name, resolvedAt}. A TTL rather than a permanent cache, so
-- a RENAMED account corrects itself within an hour without costing a
-- lookup per board render. A DELETED account never resolves and falls
-- back to LeaderboardLogic.displayNameFor's placeholder every time,
-- which is cheap because the failure is cached too.
type NameEntry = { name: string?, resolvedAt: number }
local nameCache: { [number]: NameEntry } = {}

local function now(): number
	return os.clock()
end

local function rng(): number
	return math.random()
end

-- ===== budget ==============================================================

local function refreshBudgetWindow()
	budget = LeaderboardLogic.rollWindow(budget, now(), config.budget)
end

-- The engine's own remaining budget for this request type. Wrapped in a
-- pcall because it is a service call like any other and a failure here
-- must not take down the poll loop - a nil budget is treated as "don't
-- know", and the local policy decides alone.
-- `EnumItem` rather than `EnumDataStoreRequestType`: the defs name that
-- type internally but do not expose it to user code (confirmed locally -
-- luau-lsp reports "Unknown type"), and EnumItem is the standard
-- always-available spelling.
local function engineBudget(requestType: EnumItem): number?
	local ok, remaining = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(requestType)
	end)
	return if ok then remaining else nil
end

local function mayRequest(kind: LeaderboardLogic.RequestKind, requestType: EnumItem): boolean
	refreshBudgetWindow()

	-- Hard gate first: the engine's real count. A call made with no
	-- budget left doesn't fail fast, it THROTTLES - the request queues
	-- and the calling thread yields, which is how one greedy service
	-- stalls every other DataStore user on the server.
	local remaining = engineBudget(requestType)
	if remaining ~= nil and remaining < 1 then
		return false
	end

	return LeaderboardLogic.mayRequest(budget, config.budget, kind)
end

local function spend(count: number?)
	budget = LeaderboardLogic.spend(budget, count)
end

-- ===== names ===============================================================

-- Batched: one call resolves up to the whole page, rather than one call
-- per row. A 100-row board resolved one id at a time is 100 web calls
-- every refresh, which is the write-amplification mistake in its
-- read-shaped form.
local function resolveNames(userIds: { number })
	local nowValue = now()
	local wanted: { number } = {}

	for _, userId in userIds do
		local cached = nameCache[userId]
		if cached == nil or nowValue - cached.resolvedAt > config.nameCacheTtlSeconds then
			table.insert(wanted, userId)
		end
	end

	if #wanted == 0 then
		return
	end

	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(wanted)
	end)

	if not ok then
		-- Cache the FAILURE too, with a shorter life, so a persistent
		-- outage doesn't mean a fresh batch of lookups every refresh.
		for _, userId in wanted do
			nameCache[userId] = { name = nil, resolvedAt = nowValue - config.nameCacheTtlSeconds / 2 }
		end
		warn("LeaderboardService: display name lookup failed - falling back to placeholders this cycle")
		return
	end

	local seen: { [number]: boolean } = {}
	for _, info in infos :: { { Id: number, Username: string, DisplayName: string } } do
		nameCache[info.Id] = { name = info.DisplayName, resolvedAt = nowValue }
		seen[info.Id] = true
	end

	-- A deleted account is simply absent from the response rather than
	-- returned with an error, so anything unaccounted for is recorded as
	-- unresolvable - LeaderboardLogic.displayNameFor keeps its rank and
	-- gives it a stable placeholder.
	for _, userId in wanted do
		if not seen[userId] then
			nameCache[userId] = { name = nil, resolvedAt = nowValue }
		end
	end
end

-- ===== reading =============================================================

local function fetchTopPage(): { LeaderboardLogic.Entry }?
	local liveStore = store
	if liveStore == nil then
		return nil
	end

	local ok, pages = pcall(function()
		-- ascending = false: the top of the board is the highest streak.
		return liveStore:GetSortedAsync(false, config.topCount)
	end)
	spend(1)

	local resolvedPages = pages :: DataStorePages?
	if not ok or resolvedPages == nil then
		return nil
	end

	local raw: { LeaderboardLogic.Entry } = {}
	-- Only the FIRST page is read. topCount is the page size, so one
	-- page is the whole board - paging further would spend budget on
	-- rows nobody is going to see.
	for _, item in (resolvedPages :: DataStorePages):GetCurrentPage() do
		local row = item :: { key: string, value: any }
		local userId = tonumber(row.key)
		local value = tonumber(row.value)
		if userId ~= nil and value ~= nil then
			table.insert(raw, { userId = userId, bestStreak = value, displayName = "" })
		end
	end

	return raw
end

local function broadcastBoard()
	local status = LeaderboardLogic.cacheStatus(lastRefreshAt, now(), config.staleAfterSeconds, #cachedEntries > 0)

	local payload = {}
	for rank, entry in cachedEntries do
		table.insert(payload, {
			rank = rank,
			userId = entry.userId,
			bestStreak = entry.bestStreak,
			displayName = entry.displayName,
		})
	end

	-- The staleness indicator P4-3 requires travels WITH the data, not
	-- as a separate event: a client that got the board and missed the
	-- "this is old" message would show stale numbers as current, and
	-- that is worse than showing nothing.
	Net.fireAllClients("LeaderboardState", { entries = payload, status = status })
end

local function refreshBoard(): boolean
	if not mayRequest("Read", Enum.DataStoreRequestType.GetSortedAsync) then
		-- Not an error. The cache covers a skipped cycle, which is
		-- exactly what the soft ceiling is protecting.
		return false
	end

	local raw = fetchTopPage()
	if raw == nil then
		return false
	end

	local ranked = LeaderboardLogic.rank(LeaderboardLogic.dedupe(raw))

	local userIds: { number } = {}
	for _, entry in ranked do
		table.insert(userIds, entry.userId)
	end
	resolveNames(userIds)

	for _, entry in ranked do
		local cached = nameCache[entry.userId]
		entry.displayName = LeaderboardLogic.displayNameFor(if cached then cached.name else nil, entry.userId)
	end

	-- Only replaced on SUCCESS. A failed refresh leaves the previous
	-- board in place to be served stale, rather than blanking it -
	-- P4-3: "never an empty board."
	cachedEntries = ranked
	lastRefreshAt = now()
	return true
end

-- ===== daily and weekly boards (P4-4) ======================================
--
-- MemoryStoreService SortedMaps rather than OrderedDataStore, so a
-- finished period's entries expire on their own and there is no cleanup
-- job to write, schedule or forget. The period key is in the MAP NAME
-- (PeriodKeys.liveMapName), which is what makes rollover nearly free:
-- at midnight every server simply starts addressing a different map.
--
-- The calendar arithmetic - which day, which ISO week, when they end,
-- how long entries should live - is pure and lives in PeriodKeys.luau,
-- where the awkward year-boundary cases are pinned by real dates rather
-- than waiting for a December to find out.
--
-- ===== WHY SORTED MAPS NEED AN EXPLICIT SORT KEY ========================
--
-- MemoryStoreSortedMap:SetAsync(key, value, expiration, sortKey) sorts
-- by that fourth argument, NOT by the map key. The map key here is the
-- userId (so one player has one entry and an improvement overwrites
-- rather than accumulates), and the sort key is the streak. Passing the
-- userId as both - the easy mistake - would produce a board sorted by
-- account age.

local PERIOD_KINDS: { string } = { "Daily", "Weekly" }

type PeriodState = {
	-- The period key this server last observed. nil until the first
	-- check, which is deliberately NOT treated as a rollover.
	lastSeenKey: string?,
	entries: { LeaderboardLogic.Entry },
	lastRefreshAt: number?,
}

local periodState: { [string]: PeriodState } = {}
for _, rawKind in PERIOD_KINDS do
	local kind = rawKind
	periodState[kind] = { lastSeenKey = nil, entries = {}, lastRefreshAt = nil }
end

-- What THIS server last wrote for a player in a given period, so a
-- no-op write is never issued. Keyed by "<kind>|<periodKey>|<userId>"
-- and cleared on rollover, since a new period starts everyone at zero.
local lastPeriodWrite: { [string]: number } = {}

local function periodWriteKey(kind: string, periodKey: string, userId: number): string
	return string.format("%s|%s|%d", kind, periodKey, userId)
end

local function sortedMapFor(kind: string, periodKey: string): MemoryStoreSortedMap?
	local ok, map = pcall(function()
		return MemoryStoreService:GetSortedMap(PeriodKeys.liveMapName(kind, periodKey))
	end)
	return if ok then map else nil
end

-- ===== writing a period entry ==============================================

-- P4-4: "write only on improvement within the current period."
--
-- Note this is the PERIOD's best, not the all-time best: a player whose
-- all-time record is 40 but who has only reached 3 today belongs on
-- today's board at 3. So the value written is the streak achieved
-- inside this period, and the UpdateAsync transform below takes the max
-- against whatever is already stored - which is what makes two servers
-- writing for the same player at once safe, exactly as on the all-time
-- board.
local function writePeriodBest(kind: string, userId: number, streak: number)
	local periodKey = PeriodKeys.keyFor(kind, os.time())
	local writeKey = periodWriteKey(kind, periodKey, userId)

	if not LeaderboardLogic.shouldWrite(lastPeriodWrite[writeKey], streak) then
		return
	end

	local map = sortedMapFor(kind, periodKey)
	if map == nil then
		return
	end

	local expiry = PeriodKeys.liveExpirySeconds(kind, os.time(), config.periodGraceSeconds)

	local ok = pcall(function()
		map:UpdateAsync(tostring(userId), function(current: any): any
			local existing = tonumber(current) or 0
			if streak <= existing then
				-- Returning the existing value rather than nil: nil
				-- would DELETE the entry, which on a losing race would
				-- silently remove a player from the board.
				return existing
			end
			return streak
		end, math.floor(expiry))
	end)

	if ok then
		lastPeriodWrite[writeKey] = streak
	else
		warn(string.format("LeaderboardService: %s period write failed for %d", kind, userId))
	end
	spend(1)
end

-- ===== reading a period board ==============================================

local function refreshPeriodBoard(kind: string, periodKey: string): boolean
	local map = sortedMapFor(kind, periodKey)
	if map == nil then
		return false
	end

	local ok, rows = pcall(function()
		-- Descending: the top of the board is the highest streak. The
		-- two bound arguments are declared non-optional in the type
		-- defs but are genuinely optional at runtime, so nil is passed
		-- explicitly rather than omitted.
		return map:GetRangeAsync(Enum.SortDirection.Descending, config.topCount, nil, nil)
	end)
	spend(1)

	if not ok or rows == nil then
		return false
	end

	local raw: { LeaderboardLogic.Entry } = {}
	for _, row in rows :: { { key: string, value: any } } do
		local userId = tonumber(row.key)
		local streak = tonumber(row.value)
		if userId ~= nil and streak ~= nil then
			table.insert(raw, { userId = userId, bestStreak = streak, displayName = "" })
		end
	end

	local ranked = LeaderboardLogic.rank(LeaderboardLogic.dedupe(raw))

	local userIds: { number } = {}
	for _, entry in ranked do
		table.insert(userIds, entry.userId)
	end
	resolveNames(userIds)
	for _, entry in ranked do
		local cached = nameCache[entry.userId]
		entry.displayName = LeaderboardLogic.displayNameFor(if cached then cached.name else nil, entry.userId)
	end

	-- Replaced only on success, same as the all-time board: a failed
	-- refresh serves the previous standings stale rather than blanking
	-- them.
	local state = periodState[kind]
	state.entries = ranked
	state.lastRefreshAt = now()
	return true
end

-- ===== rollover ============================================================

-- P4-4 asks for a frozen snapshot of the finishing standings written to
-- a REGULAR DataStore, and for reward hooks that are safe against two
-- servers processing the same rollover.
--
-- ===== HOW THE DOUBLE-AWARD GUARD ACTUALLY WORKS ========================
--
-- Every server notices the rollover at roughly the same moment, so
-- "check whether a snapshot exists, then write one" is a race with a
-- window between the two halves - both servers check, both find
-- nothing, both award. The guard has to be ATOMIC, and it is the
-- snapshot write itself that provides it:
--
--   DataStore:UpdateAsync returns whatever the transform returned, and
--   the transform sees the CURRENT stored value. So a transform that
--   refuses to overwrite an existing snapshot, and a caller that
--   compares what came back against what it tried to write, gives a
--   definitive answer to "was I the one who created this?" - with no
--   window, because the read and the write are the same operation.
--
-- Only the server that created the snapshot fires the reward hook. The
-- losers find a snapshot that isn't theirs and stop. A separate
-- MemoryStore lock would ALSO work, but it would be a second thing that
-- can expire or fail independently of the snapshot it guards; using the
-- snapshot itself means the guard cannot drift out of step with the
-- thing it protects.
local function processRollover(kind: string, finishedKey: string)
	local snapshots = snapshotStore
	if snapshots == nil then
		warn(string.format("LeaderboardService: no snapshot store - %s %s standings are lost", kind, finishedKey))
		return
	end

	-- Read the finished period's final standings BEFORE anything else:
	-- the live map is still within its grace margin, which is the whole
	-- reason that margin exists.
	if not refreshPeriodBoard(kind, finishedKey) then
		warn(string.format("LeaderboardService: could not read final %s standings for %s", kind, finishedKey))
		return
	end

	local standings = periodState[kind].entries
	local payload = {
		periodKey = finishedKey,
		frozenAt = os.time(),
		entries = {},
	}
	for rank, entry in standings do
		table.insert(payload.entries, {
			rank = rank,
			userId = entry.userId,
			streak = entry.bestStreak,
			displayName = entry.displayName,
		})
	end

	local key = PeriodKeys.snapshotKey(kind, finishedKey)
	local ok, stored = pcall(function()
		return snapshots:UpdateAsync(key, function(current: any): any
			-- First writer wins, permanently. A second server's
			-- transform sees the existing snapshot and returns it
			-- unchanged, so its UpdateAsync hands back someone else's
			-- payload and the comparison below tells it so.
			if current ~= nil then
				return current
			end
			return payload
		end)
	end)
	spend(1)

	if not ok then
		warn(string.format("LeaderboardService: snapshot write failed for %s %s", kind, finishedKey))
		return
	end

	local wonTheRace = stored ~= nil and (stored :: any).frozenAt == payload.frozenAt
	if not wonTheRace then
		print(
			string.format(
				"LeaderboardService: %s %s already snapshotted by another server - not awarding",
				kind,
				finishedKey
			)
		)
		return
	end

	print(
		string.format(
			"LeaderboardService: froze %s %s with %d entries - awarding top %d",
			kind,
			finishedKey,
			#payload.entries,
			math.min(config.rewardTopN, #payload.entries)
		)
	)

	-- The reward hook. Injected rather than implemented here, because
	-- what a period win is WORTH is a progression/economy decision
	-- (design-decisions.md Q1's still-unbuilt RewardTables), not a
	-- leaderboard one. Fired only by the snapshot's creator, so it is
	-- fired exactly once across the whole universe.
	for rank, entry in payload.entries do
		if rank > config.rewardTopN then
			break
		end
		-- Message captured through the handler's upvalue rather than
		-- xpcall's second return, for the reason tests/TestRunner.luau
		-- documents: strict-mode return arity follows the wrapped
		-- function's own count, which is zero here.
		local handlerError: string? = nil
		local handlerOk = xpcall(periodRewardHandler, function(err)
			handlerError = tostring(err)
		end, kind, finishedKey, rank, entry.userId, entry.streak)
		if not handlerOk then
			warn(
				string.format("LeaderboardService: reward hook errored for rank %d - %s", rank, tostring(handlerError))
			)
		end
	end
end

-- Checks every period kind for a boundary crossing. Called on the same
-- poll loop as the all-time refresh, so a rollover is noticed within
-- one refresh interval of it happening - a minute or two late, which
-- for a daily board is invisible.
local function checkRollovers()
	local nowSeconds = os.time()

	for _, rawKind in PERIOD_KINDS do
		local kind = rawKind
		local state = periodState[kind]
		local currentKey = PeriodKeys.keyFor(kind, nowSeconds)

		if PeriodKeys.hasRolledOver(state.lastSeenKey, currentKey) then
			local finishedKey = state.lastSeenKey :: string
			-- Snapshot and award for the period that just ended, then
			-- start fresh. Wrapped so a failed rollover cannot stop the
			-- server from tracking the NEW period.
			local rolloverError: string? = nil
			local ok = xpcall(processRollover, function(err)
				rolloverError = tostring(err)
			end, kind, finishedKey)
			if not ok then
				warn(
					string.format(
						"LeaderboardService: rollover for %s %s failed - %s",
						kind,
						finishedKey,
						tostring(rolloverError)
					)
				)
			end

			-- A new period starts everyone at zero, so this server's
			-- record of what it has already written is meaningless now.
			lastPeriodWrite = {}
			state.entries = {}
			state.lastRefreshAt = nil
		end

		state.lastSeenKey = currentKey
	end
end

local function broadcastPeriodBoards()
	for _, rawKind in PERIOD_KINDS do
		local kind = rawKind
		local state = periodState[kind]
		local status =
			LeaderboardLogic.cacheStatus(state.lastRefreshAt, now(), config.staleAfterSeconds, #state.entries > 0)

		local payload = {}
		for rank, entry in state.entries do
			table.insert(payload, {
				rank = rank,
				userId = entry.userId,
				bestStreak = entry.bestStreak,
				displayName = entry.displayName,
			})
		end

		Net.fireAllClients("PeriodBoardState", {
			kind = kind,
			periodKey = state.lastSeenKey,
			entries = payload,
			status = status,
		})
	end
end
-- ===== writing =============================================================

-- UpdateAsync with a max comparison, so a lower value can never
-- overwrite a higher one even when two servers write for the same
-- player at once - the transform sees whatever is actually stored at
-- the moment it runs, not what this server last believed.
--
-- SetAsync would be the bug here: last-writer-wins, and the loser of
-- that race is a player's real record.
local function writeBest(userId: number, bestStreak: number): boolean
	local liveStore = store
	if liveStore == nil then
		return false
	end
	if not LeaderboardLogic.shouldWrite(lastWrittenBest[userId], bestStreak) then
		return false
	end
	if not mayRequest("Write", Enum.DataStoreRequestType.UpdateAsync) then
		warn(
			string.format(
				"LeaderboardService: out of write budget - %d's best of %d not recorded yet",
				userId,
				bestStreak
			)
		)
		return false
	end

	local attempt = 0
	while attempt < config.maxWriteAttempts do
		attempt += 1

		local ok = pcall(function()
			liveStore:UpdateAsync(tostring(userId), function(current: number?): number
				local existing = current or 0
				return math.max(existing, bestStreak)
			end)
		end)
		spend(1)

		if ok then
			lastWrittenBest[userId] = bestStreak
			return true
		end

		local delay =
			LeaderboardLogic.backoffSeconds(attempt, config.backoffBaseSeconds, config.backoffCapSeconds, rng())
		warn(
			string.format(
				"LeaderboardService: write for %d failed (attempt %d) - retrying in %.1fs",
				userId,
				attempt,
				delay
			)
		)
		task.wait(delay)
	end

	warn(
		string.format(
			"LeaderboardService: gave up writing %d's best of %d after %d attempts",
			userId,
			bestStreak,
			attempt
		)
	)
	return false
end

-- The seam P4-1's ProgressionService calls after a streak change. Runs
-- on its own thread: a write can retry with backoff for tens of
-- seconds, and the round must not wait on a leaderboard.
local function submitBestStreak(player: Player, bestStreak: number)
	task.spawn(writeBest, player.UserId, bestStreak)
end

-- P4-4: the period boards track the streak reached WITHIN the current
-- period, which is a different number from the all-time best - a player
-- whose record is 40 but who has only reached 3 today belongs on
-- today's board at 3. So this takes the CURRENT streak and is called on
-- every streak change, not only on a personal best.
local function submitPeriodStreak(player: Player, currentStreak: number)
	task.spawn(function()
		for _, rawKind in PERIOD_KINDS do
			local kind = rawKind
			writePeriodBest(kind, player.UserId, currentStreak)
		end
	end)
end

-- ===== poll loop ===========================================================

local function startPolling()
	if pollThread ~= nil then
		return
	end

	pollThread = task.spawn(function()
		-- A random first delay as well as a random interval: a hundred
		-- servers started by the same deploy would otherwise take their
		-- first read at the same instant.
		task.wait(LeaderboardLogic.nextRefreshDelay(0, config.refreshMaxSeconds, rng()))

		local consecutiveFailures = 0
		while true do
			local ok = refreshBoard()
			broadcastBoard()

			-- P4-4 rides the same loop: a rollover is noticed within
			-- one refresh interval of it happening, which for a daily
			-- board is invisible, and it costs no extra timer.
			checkRollovers()
			for _, rawKind in PERIOD_KINDS do
				local kind = rawKind
				local state = periodState[kind]
				if state.lastSeenKey ~= nil and mayRequest("Read", Enum.DataStoreRequestType.GetSortedAsync) then
					refreshPeriodBoard(kind, state.lastSeenKey :: string)
				end
			end
			broadcastPeriodBoards()

			if ok then
				consecutiveFailures = 0
				task.wait(LeaderboardLogic.nextRefreshDelay(config.refreshMinSeconds, config.refreshMaxSeconds, rng()))
			else
				consecutiveFailures += 1
				task.wait(
					LeaderboardLogic.backoffSeconds(
						consecutiveFailures,
						config.backoffBaseSeconds,
						config.backoffCapSeconds,
						rng()
					)
				)
			end
		end
	end)
end

-- ===== service =============================================================

local LeaderboardService: Loader.Service = {
	name = "LeaderboardService",
	dependencies = { "NetGuard", "ConfigValidator" },

	submitBestStreak = submitBestStreak,
	submitPeriodStreak = submitPeriodStreak,

	-- Read straight from the cache. P4-3: "never read on player demand,
	-- and never read once per viewer of the board" - so this is the
	-- ONLY way anything gets the board, and it cannot issue a request.
	getBoard = function(): { LeaderboardLogic.Entry }
		return table.clone(cachedEntries)
	end,

	getStatus = function(): string
		return LeaderboardLogic.cacheStatus(lastRefreshAt, now(), config.staleAfterSeconds, #cachedEntries > 0)
	end,

	-- The metric P4-3 asks for, exposed so P4-7's telemetry can log it
	-- without reaching into this file's state.
	getBudgetPressure = function(): number
		refreshBudgetWindow()
		return LeaderboardLogic.budgetPressure(budget, config.budget)
	end,

	-- ===== P4-4 =============================================

	-- The seam a progression/economy system claims to decide what a
	-- period win is worth. Replaces the logging default; called once
	-- per rewarded rank, only on the server that won the snapshot race.
	setPeriodRewardHandler = function(handler: (
		kind: string,
		periodKey: string,
		rank: number,
		userId: number,
		streak: number
	) -> ())
		periodRewardHandler = handler
	end,

	getPeriodBoard = function(kind: string): { LeaderboardLogic.Entry }
		local state = periodState[kind]
		return if state ~= nil then table.clone(state.entries) else {}
	end,

	getPeriodKey = function(kind: string): string?
		local state = periodState[kind]
		return if state ~= nil then state.lastSeenKey else nil
	end,

	-- Reads a FINISHED period's frozen standings straight from the
	-- snapshot store - yesterday's or last week's winners, long after
	-- the live MemoryStore entries have expired.
	getSnapshot = function(kind: string, periodKey: string): any?
		local snapshots = snapshotStore
		if snapshots == nil then
			return nil
		end
		local ok, snapshot = pcall(function()
			return snapshots:GetAsync(PeriodKeys.snapshotKey(kind, periodKey))
		end)
		return if ok then snapshot else nil
	end,
}

function LeaderboardService:init()
	budget = LeaderboardLogic.newBudget(now())

	-- Studio has no live DataStore access unless the place is published
	-- with API access enabled, and a failed GetOrderedDataStore here
	-- would take the whole boot down. A nil store degrades to "board
	-- never refreshes", which is exactly the Empty case the UI already
	-- has to handle.
	local ok, resolved = pcall(function()
		return DataStoreService:GetOrderedDataStore(config.storeName, config.storeScope)
	end)

	if ok then
		store = resolved
	else
		warn(
			string.format(
				"LeaderboardService: no OrderedDataStore available (%s) - the board will stay empty. In Studio this is normal unless API access is enabled.",
				if RunService:IsStudio() then "Studio" else "live"
			)
		)
	end

	-- P4-4: the snapshot store, and the first period observation. The
	-- observation matters - PeriodKeys.hasRolledOver is false against a
	-- nil, so recording the current period at boot is what stops a
	-- server that started at 3am from treating its first check as a
	-- midnight it never witnessed.
	local snapshotOk, resolvedSnapshot = pcall(function()
		return DataStoreService:GetDataStore(config.snapshotStoreName)
	end)
	if snapshotOk then
		snapshotStore = resolvedSnapshot
	end

	local bootTime = os.time()
	for _, rawKind in PERIOD_KINDS do
		local kind = rawKind
		periodState[kind].lastSeenKey = PeriodKeys.keyFor(kind, bootTime)
	end

	-- A joining player needs the board immediately, and the cache is
	-- already in memory - this costs nothing and is why per-viewer reads
	-- are never needed.
	Players.PlayerAdded:Connect(function()
		broadcastBoard()
		broadcastPeriodBoards()
	end)

	startPolling()
end

return LeaderboardService
