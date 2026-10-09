--!strict
-- Analytics instrumentation (P4-7, reworked in next-stages step 6). One
-- thin wrapper around AnalyticsService, never called directly anywhere
-- else. All events pass through here, so a missing instrumentation point
-- shows up as a missing call rather than as an empty cell in the
-- analytics dashboard.
--
-- What each event is called and which fields it carries is decided in
-- src/server/TelemetryLogic.luau (pure, tested); docs/telemetry-schema.md
-- is the table. This file only finds the Player, rate-limits, queues and
-- makes the call: LogFunnelStepEvent for the two funnels, LogCustomEvent
-- for everything else. (The old AnalyticsService:FireEvent is deprecated.)
--
-- Callers pass a Player or a user id. A user id with no Player in this
-- server (an NPC's negative id, or someone who already left) is dropped:
-- every analytics call needs a Player. Round-level events are logged
-- against one human in the server, the "anchor".
--
-- No PII: AnalyticsService attaches the user itself; nothing here logs
-- names, display names, chat or another player's id.
--
-- Rate limiting is per-player per-event per-minute. A player mashing a
-- button 100 times per second still only logs 60 events at the limit,
-- not 6000. The limit is set in config, and 0 = no limit.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Analytics = game:GetService("AnalyticsService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local EffectContext = require(ServerScriptService.Server.EffectContext)
local TelemetryLogic = require(ServerScriptService.Server.TelemetryLogic)

type Record = TelemetryLogic.Record
type Who = Player | number

type Queued = {
	player: Player,
	record: Record,
}

type RateLimitEntry = {
	count: number,
	resetAt: number,
}

local FIELD_KEYS = {
	Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
}

-- Studio can't send events (the platform only accepts a published
-- game's server), so there the call is replaced by a print when
-- telemetry.studioEcho is on.
local IS_STUDIO = RunService:IsStudio()

local state = {
	-- "eventName|userId" -> count + resetAt.
	rateLimits = {} :: { [string]: RateLimitEntry },
	-- Waiting for flush: batchSize events or flushIntervalSeconds,
	-- whichever comes first, and always before a player leaves.
	queue = {} :: { Queued },
	lastFlushAt = 0,
	-- Match server only: set by roundStarted, read by every Round step.
	round = nil :: TelemetryLogic.RoundContext?,
	-- Hub only: the Matchmaking funnel session per queue attempt.
	queueSessions = {} :: { [Player]: string },
	-- Event names whose call has already failed once, so a broken sink
	-- warns once per name instead of every event.
	warned = {} :: { [string]: true },
}

-- ===== players =============================================================

local function resolve(who: Who): Player?
	if typeof(who) == "Instance" then
		return if who.Parent == Players then who else nil
	end
	return Players:GetPlayerByUserId(who)
end

-- Round-level facts are logged once, against the first human here.
local function anchor(): Player?
	return Players:GetPlayers()[1]
end

-- ===== rate limiting =========================================================

local function allowed(eventName: string, userId: number): boolean
	local limit = GameConfig.telemetry.perMinuteLimit
	if limit <= 0 then
		return true
	end

	local key = string.format("%s|%d", eventName, userId)
	local now = os.time()
	local entry = state.rateLimits[key]
	if entry == nil or now >= entry.resetAt then
		state.rateLimits[key] = { count = 1, resetAt = now + 60 }
		return true
	end
	if entry.count < limit then
		entry.count += 1
		return true
	end
	return false
end

-- ===== sending ===============================================================

local function customFields(record: Record): { [string]: string }?
	local fields: { [string]: string } = {}
	local any = false
	for slot = 1, #FIELD_KEYS do
		local value = record.fields[slot]
		if value ~= nil then
			fields[FIELD_KEYS[slot]] = value
			any = true
		end
	end
	return if any then fields else nil
end

local function send(item: Queued)
	local record = item.record
	local fields = customFields(record)

	if IS_STUDIO then
		if GameConfig.telemetry.studioEcho then
			local shown: { string } = {}
			for slot = 1, #FIELD_KEYS do
				table.insert(shown, record.fields[slot] or "-")
			end
			print(
				string.format(
					"Telemetry [%s] %s%s value=%s session=%s player=%d %s",
					record.kind,
					record.name,
					if record.stepName then "/" .. record.stepName else "",
					tostring(record.value),
					tostring(record.sessionId),
					item.player.UserId,
					table.concat(shown, " | ")
				)
			)
		end
		return
	end

	local ok, err = pcall(function()
		if record.kind == "Funnel" then
			Analytics:LogFunnelStepEvent(
				item.player,
				record.name,
				record.sessionId,
				record.step,
				record.stepName,
				fields
			)
		else
			Analytics:LogCustomEvent(item.player, record.name, record.value, fields)
		end
	end)
	if not ok and not state.warned[record.name] then
		state.warned[record.name] = true
		warn(string.format("Telemetry: %s failed and will not warn again: %s", record.name, tostring(err)))
	end
end

local function flush()
	if #state.queue == 0 then
		return
	end
	local items = state.queue
	state.queue = {}
	state.lastFlushAt = os.time()
	for _, item in items do
		-- A player who left before the flush can't be logged against.
		-- PlayerRemoving flushes first, so this is only a backstop.
		if item.player.Parent == Players then
			send(item)
		end
	end
end

-- The rate-limit key: the event name, or funnel/step for a funnel step.
local function limitName(record: Record): string
	return if record.stepName then record.name .. "/" .. record.stepName else record.name
end

local function log(player: Player?, record: Record)
	if player == nil or not GameConfig.telemetry.enabled then
		return
	end
	if not allowed(limitName(record), player.UserId) then
		return
	end
	table.insert(state.queue, { player = player, record = record })
	local config = GameConfig.telemetry
	if #state.queue >= config.batchSize or os.time() - state.lastFlushAt >= config.flushIntervalSeconds then
		flush()
	end
end

local function roundMapId(): string
	local round = state.round
	return if round ~= nil then round.mapId else "none"
end

local function roundStep(who: Who, step: number)
	local round = state.round
	if round == nil then
		return -- not in a round (hub, or before Loading)
	end
	log(resolve(who), TelemetryLogic.roundStep(round, step))
end

-- ===== Matchmaking funnel (hub) =============================================

local function userQueued(who: Who)
	local player = resolve(who)
	if player == nil then
		return
	end
	local sessionId = HttpService:GenerateGUID(false)
	state.queueSessions[player] = sessionId
	log(player, TelemetryLogic.matchmakingStep(sessionId, TelemetryLogic.MatchmakingStep.Queued))
end

local function userMatched(who: Who)
	local player = resolve(who)
	if player == nil then
		return
	end
	-- Matched without a Queued (a session that predates the server, say)
	-- still gets a session: the funnel back-fills skipped steps.
	local sessionId = state.queueSessions[player] or HttpService:GenerateGUID(false)
	state.queueSessions[player] = nil
	log(player, TelemetryLogic.matchmakingStep(sessionId, TelemetryLogic.MatchmakingStep.Matched))
end

-- ===== Round funnel (match) ==================================================

-- Starts the round's funnel session and logs step 1 for every human here.
local function roundStarted(roundId: string, mapId: string, humans: { Player }, configVersion: string?)
	local round: TelemetryLogic.RoundContext = {
		roundId = roundId,
		mapId = mapId,
		humans = #humans,
		configVersion = configVersion,
	}
	state.round = round
	for _, player in humans do
		log(resolve(player), TelemetryLogic.roundStep(round, TelemetryLogic.RoundStep.Started))
	end
end

local function finished(who: Who)
	roundStep(who, TelemetryLogic.RoundStep.Finished)
end

local function qualified(who: Who)
	roundStep(who, TelemetryLogic.RoundStep.Qualified)
end

local function finaleEntered(who: Who)
	roundStep(who, TelemetryLogic.RoundStep.FinaleEntered)
end

local function choiceLocked(who: Who)
	roundStep(who, TelemetryLogic.RoundStep.ChoiceLocked)
end

local function resultReceived(who: Who)
	roundStep(who, TelemetryLogic.RoundStep.ResultReceived)
end

-- ===== custom events =========================================================

local function taskCompleted(who: Who, taskId: string, seconds: number, taskNumber: number)
	log(resolve(who), TelemetryLogic.taskCompleted(taskId, seconds, taskNumber, roundMapId()))
end

local function mapVoted(who: Who, mapId: string)
	log(resolve(who), TelemetryLogic.mapVoted(mapId))
end

local function mapPlayed(mapId: string, humans: number)
	log(anchor(), TelemetryLogic.mapPlayed(mapId, humans))
end

-- Never from hub practice (P5-5): a practice scuffle would skew real
-- power-up balance data.
local function powerUpUsed(who: Who, powerUpId: string, succeeded: boolean)
	if not EffectContext.recordsStats() then
		return
	end
	log(resolve(who), TelemetryLogic.powerUpUsed(powerUpId, succeeded, roundMapId()))
end

local function stealShareChoice(who: Who, choice: string, streak: number, bots: number, rung: number?)
	log(resolve(who), TelemetryLogic.stealShareChoice(choice, streak, bots, rung))
end

local function finaleOutcome(branch: string, winners: number, bots: number)
	log(anchor(), TelemetryLogic.finaleOutcome(branch, winners, bots))
end

local function streakLoss(who: Who, streak: number, reason: string)
	log(resolve(who), TelemetryLogic.streakLoss(streak, reason, roundMapId()))
end

-- Also remembers the seat count for StreakWin.
local function npcCountInRound(bots: number, humans: number)
	local round = state.round
	if round ~= nil then
		round.bots = bots
	end
	log(anchor(), TelemetryLogic.npcCountInRound(bots, humans, roundMapId()))
end

local function purchaseCompleted(who: Who, productId: string, productType: string, robux: number?)
	log(resolve(who), TelemetryLogic.purchaseCompleted(productId, productType, robux))
end

-- `rawReason` is TeleportData's returnReason, unchecked; the logic layer
-- keeps only the reasons the match server sends.
local function returnedToHub(who: Who, rawReason: any)
	log(resolve(who), TelemetryLogic.returnedToHub(rawReason))
end

local function taskAbandoned(who: Who, taskId: string, seconds: number, exit: string)
	log(resolve(who), TelemetryLogic.taskAbandoned(taskId, seconds, exit, roundMapId()))
end

-- Never from hub practice, like powerUpUsed: the two are read together.
local function powerUpCollected(who: Who, powerUpId: string, source: string)
	if not EffectContext.recordsStats() then
		return
	end
	log(resolve(who), TelemetryLogic.powerUpCollected(powerUpId, source, roundMapId()))
end

local function roundEnded(raceSeconds: number, humanFinishers: number, humans: number)
	log(anchor(), TelemetryLogic.roundEnded(roundMapId(), raceSeconds, humanFinishers, humans))
end

local function streakWin(who: Who, streak: number)
	local round = state.round
	log(resolve(who), TelemetryLogic.streakWin(streak, if round ~= nil then round.bots else nil, roundMapId()))
end

-- ===== service ===============================================================

local TelemetryService: Loader.Service = {
	name = "Telemetry",
	dependencies = {},

	-- Matchmaking funnel (hub)
	userQueued = userQueued,
	userMatched = userMatched,

	-- Round funnel (match)
	roundStarted = roundStarted,
	finished = finished,
	qualified = qualified,
	finaleEntered = finaleEntered,
	choiceLocked = choiceLocked,
	resultReceived = resultReceived,

	-- Custom events
	taskCompleted = taskCompleted,
	mapVoted = mapVoted,
	mapPlayed = mapPlayed,
	powerUpUsed = powerUpUsed,
	stealShareChoice = stealShareChoice,
	finaleOutcome = finaleOutcome,
	streakLoss = streakLoss,
	npcCountInRound = npcCountInRound,
	purchaseCompleted = purchaseCompleted,
	returnedToHub = returnedToHub,
	taskAbandoned = taskAbandoned,
	powerUpCollected = powerUpCollected,
	roundEnded = roundEnded,
	streakWin = streakWin,

	-- Explicit flush for tests and edge cases (BindToClose, etc)
	flush = flush,
}

function TelemetryService:init()
	-- A leaving player's queued events go out while they're still a
	-- Player; after this they can't be logged against.
	Players.PlayerRemoving:Connect(function(player)
		flush()
		state.queueSessions[player] = nil
	end)
	game:BindToClose(function()
		flush()
	end)
	-- log() only flushes when a new event arrives, so the last events
	-- of a burst (RoundEnded, StreakLoss at Results) would otherwise
	-- wait for the next event or a player leaving.
	task.spawn(function()
		while true do
			task.wait(GameConfig.telemetry.flushIntervalSeconds)
			if os.time() - state.lastFlushAt >= GameConfig.telemetry.flushIntervalSeconds then
				flush()
			end
		end
	end)
end

return TelemetryService
