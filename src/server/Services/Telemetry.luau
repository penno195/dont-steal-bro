--!strict
-- Analytics instrumentation (P4-7). One thin wrapper around AnalyticsService,
-- never called directly anywhere else. All events pass through here, so a
-- missing instrumentation point shows up as a missing call rather than as
-- an empty cell in the analytics dashboard.
--
-- Event naming convention: PascalCase, organized hierarchically by verb +
-- noun (UserQueued, UserMatched, RoundStarted, TaskCompleted, etc). All
-- events carry the user's id (inherent to AnalyticsService) and a clientId
-- (if on the client) or serverId (if on the server), never player names
-- or other PII.
--
-- Rate limiting is per-player per-event per-minute. A player mashing a
-- button 100 times per second still only logs 60 events at the limit,
-- not 6000. The limit is set in config, and 0 = no limit. Off by default
-- for now (PLACEHOLDER in GameConfig) because there's no telemetry yet to
-- say what is sane, but it's there to add without touching code.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Analytics = game:GetService("AnalyticsService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)

export type Event = {
	name: string,
	parameters: { [string]: any },
}

type RateLimitEntry = {
	count: number,
	resetAt: number,
}

local Telemetry = {
	-- Per-player rate limit tracking. Format: "eventName|userId" -> count + resetAt.
	rateLimits = {} :: { [string]: RateLimitEntry },
	-- Queued events waiting for flush. Max 50 (configurable) or flushIntervalSeconds
	-- (configurable), whichever comes first.
	queue = {} :: { Event },
	-- Last flush time, so we can enforce flushIntervalSeconds.
	lastFlushAt = 0,
	-- Monotonic counter for event ordering.
	eventSequence = 0,
}

-- ===== rate limiting =========================================================

local function rateLimitKey(eventName: string, userId: number): string
	return string.format("%s|%d", eventName, userId)
end

local function checkRateLimit(eventName: string, userId: number): boolean
	local config = GameConfig.telemetry
	if config.perMinuteLimit <= 0 then
		return true -- no limit
	end

	local key = rateLimitKey(eventName, userId)
	local now = os.time()
	local entry = Telemetry.rateLimits[key]

	if entry == nil or now >= entry.resetAt then
		-- New window: reset counter
		Telemetry.rateLimits[key] = { count = 1, resetAt = now + 60 }
		return true
	end

	-- Existing window
	if entry.count < config.perMinuteLimit then
		entry.count += 1
		return true
	end

	-- Rate limited
	return false
end

-- ===== queueing and flushing ================================================

-- Declared ahead of enqueue, which calls it. `Telemetry` above is the
-- module's private state table, not the service - it has no `flush`.
local flush: () -> ()

local function enqueue(event: Event)
	if not GameConfig.telemetry.enabled then
		return
	end

	table.insert(Telemetry.queue, event)

	if
		#Telemetry.queue >= GameConfig.telemetry.batchSize
		or os.time() - Telemetry.lastFlushAt >= GameConfig.telemetry.flushIntervalSeconds
	then
		flush()
	end
end

function flush()
	if #Telemetry.queue == 0 then
		return
	end

	local events = Telemetry.queue
	Telemetry.queue = {}
	Telemetry.lastFlushAt = os.time()

	-- Fire all at once. AnalyticsService batches internally; we're just
	-- breaking up the work into sensible chunks to keep frames smooth.
	for _, event in events do
		pcall(function()
			Analytics:FireEvent(event.name, event.parameters)
		end)
	end
end

-- ===== core funnel ===========================================================

-- Core funnel: the critical path from queue to match to hub, and back.
-- These are the dashboard's headline metrics: how many users do we lose
-- at each step?

local function userQueued(userId: number)
	if not checkRateLimit("UserQueued", userId) then
		return
	end
	enqueue({
		name = "UserQueued",
		parameters = { userId = userId, timestamp = os.time() },
	})
end

local function userMatched(userId: number, groupSize: number, npcCount: number)
	if not checkRateLimit("UserMatched", userId) then
		return
	end
	enqueue({
		name = "UserMatched",
		parameters = {
			userId = userId,
			groupSize = groupSize,
			npcCount = npcCount,
			timestamp = os.time(),
		},
	})
end

local function roundStarted(roundId: string, mapId: string, playerCount: number)
	enqueue({
		name = "RoundStarted",
		parameters = {
			roundId = roundId,
			mapId = mapId,
			playerCount = playerCount,
			timestamp = os.time(),
		},
	})
end

local function taskCompleted(roundId: string, userId: number, taskId: string, durationSeconds: number)
	if not checkRateLimit("TaskCompleted", userId) then
		return
	end
	enqueue({
		name = "TaskCompleted",
		parameters = {
			userId = userId,
			roundId = roundId,
			taskId = taskId,
			durationSeconds = math.floor(durationSeconds),
			timestamp = os.time(),
		},
	})
end

local function allTasksCompleted(roundId: string, userId: number, placementIndex: number)
	if not checkRateLimit("AllTasksCompleted", userId) then
		return
	end
	enqueue({
		name = "AllTasksCompleted",
		parameters = {
			userId = userId,
			roundId = roundId,
			placementIndex = placementIndex,
			timestamp = os.time(),
		},
	})
end

local function qualified(roundId: string, userId: number, placementIndex: number)
	if not checkRateLimit("Qualified", userId) then
		return
	end
	enqueue({
		name = "Qualified",
		parameters = {
			userId = userId,
			roundId = roundId,
			placementIndex = placementIndex,
			timestamp = os.time(),
		},
	})
end

local function finaleEntered(roundId: string, userId: number, placementIndex: number)
	if not checkRateLimit("FinaleEntered", userId) then
		return
	end
	enqueue({
		name = "FinaleEntered",
		parameters = {
			userId = userId,
			roundId = roundId,
			placementIndex = placementIndex,
			timestamp = os.time(),
		},
	})
end

local function choiceLocked(roundId: string, userId: number, choice: string)
	if not checkRateLimit("ChoiceLocked", userId) then
		return
	end
	enqueue({
		name = "ChoiceLocked",
		parameters = {
			userId = userId,
			roundId = roundId,
			choice = choice,
			timestamp = os.time(),
		},
	})
end

local function resultReceived(roundId: string, userId: number, resultBranch: string)
	if not checkRateLimit("ResultReceived", userId) then
		return
	end
	enqueue({
		name = "ResultReceived",
		parameters = {
			userId = userId,
			roundId = roundId,
			resultBranch = resultBranch,
			timestamp = os.time(),
		},
	})
end

local function returnedToHub(userId: number)
	if not checkRateLimit("ReturnedToHub", userId) then
		return
	end
	enqueue({
		name = "ReturnedToHub",
		parameters = { userId = userId, timestamp = os.time() },
	})
end

-- ===== custom events ========================================================

-- Map voting and play.
local function mapVoted(roundId: string, userId: number, mapId: string)
	if not checkRateLimit("MapVoted", userId) then
		return
	end
	enqueue({
		name = "MapVoted",
		parameters = {
			userId = userId,
			roundId = roundId,
			mapId = mapId,
			timestamp = os.time(),
		},
	})
end

local function mapPlayed(roundId: string, mapId: string, playerCount: number)
	enqueue({
		name = "MapPlayed",
		parameters = {
			roundId = roundId,
			mapId = mapId,
			playerCount = playerCount,
			timestamp = os.time(),
		},
	})
end

-- Power-up use and outcome.
local function powerUpUsed(roundId: string, userId: number, powerUpId: string, targetId: number?, succeeded: boolean)
	if not checkRateLimit("PowerUpUsed", userId) then
		return
	end
	enqueue({
		name = "PowerUpUsed",
		parameters = {
			userId = userId,
			roundId = roundId,
			powerUpId = powerUpId,
			targetUserId = targetId,
			succeeded = succeeded,
			timestamp = os.time(),
		},
	})
end

-- Steal vs Share breakdown by streak at decision time.
local function stealShareChoice(roundId: string, userId: number, choice: string, currentStreak: number)
	if not checkRateLimit("StealShareChoice", userId) then
		return
	end
	enqueue({
		name = "StealShareChoice",
		parameters = {
			userId = userId,
			roundId = roundId,
			choice = choice,
			currentStreak = currentStreak,
			timestamp = os.time(),
		},
	})
end

-- Outcome branch tag for post-hoc analysis. Comes from Outcomes.luau.
local function finaleOutcome(
	roundId: string,
	resultBranch: string,
	winners: { number },
	losers: { number },
	npcCount: number
)
	enqueue({
		name = "FinaleOutcome",
		parameters = {
			roundId = roundId,
			resultBranch = resultBranch,
			winnerCount = #winners,
			loserCount = #losers,
			npcCount = npcCount,
			timestamp = os.time(),
		},
	})
end

-- Streak length and reason at a loss. Separate from the outcome so you can
-- run "what distribution of streaks end at each loss type".
local function streakLoss(userId: number, roundId: string, streakLength: number, lossReason: string)
	if not checkRateLimit("StreakLoss", userId) then
		return
	end
	enqueue({
		name = "StreakLoss",
		parameters = {
			userId = userId,
			roundId = roundId,
			streakLength = streakLength,
			lossReason = lossReason,
			timestamp = os.time(),
		},
	})
end

-- NPC count per round for understanding bot fill impact.
local function npcCountInRound(roundId: string, npcCount: number, humanCount: number)
	enqueue({
		name = "NPCCountInRound",
		parameters = {
			roundId = roundId,
			npcCount = npcCount,
			humanCount = humanCount,
			timestamp = os.time(),
		},
	})
end

-- Purchase completed. Logged when StoreService grants a receipt.
local function purchaseCompleted(userId: number, productId: string, productType: string)
	if not checkRateLimit("PurchaseCompleted", userId) then
		return
	end
	enqueue({
		name = "PurchaseCompleted",
		parameters = {
			userId = userId,
			productId = productId,
			productType = productType,
			timestamp = os.time(),
		},
	})
end

-- ===== service ===============================================================

local TelemetryService: Loader.Service = {
	name = "Telemetry",
	dependencies = {},

	-- Core funnel
	userQueued = userQueued,
	userMatched = userMatched,
	roundStarted = roundStarted,
	taskCompleted = taskCompleted,
	allTasksCompleted = allTasksCompleted,
	qualified = qualified,
	finaleEntered = finaleEntered,
	choiceLocked = choiceLocked,
	resultReceived = resultReceived,
	returnedToHub = returnedToHub,

	-- Custom events
	mapVoted = mapVoted,
	mapPlayed = mapPlayed,
	powerUpUsed = powerUpUsed,
	stealShareChoice = stealShareChoice,
	finaleOutcome = finaleOutcome,
	streakLoss = streakLoss,
	npcCountInRound = npcCountInRound,
	purchaseCompleted = purchaseCompleted,

	-- Explicit flush for tests and edge cases (BindToClose, etc)
	flush = flush,
}

function TelemetryService:init()
	-- Flush on close to ensure the last events make it out.
	game:BindToClose(function()
		flush()
	end)
end

return TelemetryService
