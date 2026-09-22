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
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserService = game:GetService("UserService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LeaderboardLogic = require(ServerScriptService.Server.LeaderboardLogic)

local config = GameConfig.leaderboard

local store: OrderedDataStore? = nil
local cachedEntries: { LeaderboardLogic.Entry } = {}
local lastRefreshAt: number? = nil
local lastWrittenBest: { [number]: number } = {}
local budget = LeaderboardLogic.newBudget(0)
local pollThread: thread? = nil

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

	-- A joining player needs the board immediately, and the cache is
	-- already in memory - this costs nothing and is why per-viewer reads
	-- are never needed.
	Players.PlayerAdded:Connect(function()
		broadcastBoard()
	end)

	startPolling()
end

return LeaderboardService
