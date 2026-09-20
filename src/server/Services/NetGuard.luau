--!strict
-- The single choke point every ServerIntent remote passes through before
-- any real game-logic handler sees it. Net.luau (src/shared/Net.luau)
-- declares WHAT a remote looks like; this is what ENFORCES that
-- declaration against a client that Ground Rule 1 says is fully
-- compromised: exact-shape payload validation, a round-state gate, and
-- per-player rate limiting, in that order, before a handler ever runs.
--
-- WHAT THIS WOULD NOT SAVE YOU FROM if you skipped server-side
-- validation somewhere else and relied on the client instead:
--   - Truthfulness. A well-shaped, rate-limit-respecting, correctly-
--     timed payload can still be a LIE - "I finished the task" with no
--     server-side proof is a valid ExamplePing, not a valid task
--     completion. Shape/rate/state are necessary, never sufficient;
--     each TaskHandler/PowerUpService/DecisionService still owns its own
--     truth (threat-model.md §2, §4).
--   - Physical plausibility. NetGuard has no idea whether a player could
--     physically have been in a position to send this - that's server-
--     side position/movement validation's job (threat-model.md §3), not
--     this module's.
--   - A statistically-perfect macro/replay. A script that fires exactly
--     the right shape, at exactly a human-plausible rate, in exactly the
--     right round state, passes every check here by construction -
--     that's a detection-over-many-sessions problem (threat-model.md's
--     "cannot be fundamentally prevented" section), not a per-call one.
--   - Anything read from TeleportData. Never trusted here or anywhere
--     else - it's a hint only (threat-model.md §5).
--
-- Rejections never throw and never kick from inside this module - see
-- Net.recordViolation's doc comment for why escalation is log, then
-- throttle (the rate limiter itself), then flag-for-review, with the
-- actual kick decision left to whatever moderation system reads the
-- flag hook.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

-- A violation crossing this many rejections within this many seconds
-- fires the flag handler once. Conservative defaults for a game with no
-- real telemetry yet - tune against real rejection-rate data once it
-- exists, same stance perf-budget.md and threat-model.md both take on
-- their own unvalidated numbers.
local ESCALATION_THRESHOLD = 5
local ESCALATION_WINDOW_SECONDS = 10

export type Report = {
	player: Player,
	remote: string,
	reason: string,
	payloadSize: number,
}

export type ReportSink = (report: Report) -> ()
export type FlagHandler = (player: Player, remote: string, violationCount: number) -> ()
export type RoundStateProvider = () -> string?

local function defaultReportSink(report: Report)
	warn(
		string.format(
			"NetGuard: rejected %s from %s (%d): %s [payload ~%d bytes]",
			report.remote,
			report.player.Name,
			report.player.UserId,
			report.reason,
			report.payloadSize
		)
	)
end

local function defaultFlagHandler(player: Player, remote: string, violationCount: number)
	warn(
		string.format(
			"NetGuard: %s (%d) flagged for review - %d rejections on %s within %ds",
			player.Name,
			player.UserId,
			violationCount,
			remote,
			ESCALATION_WINDOW_SECONDS
		)
	)
end

-- Module-level singleton state (mirrors Loader.luau's own `modules`
-- upvalue) - there is exactly one NetGuard per server, so there is no
-- meaningful difference between this and a field on the module table,
-- and this keeps the public API below as plain functions rather than
-- colon methods a caller would need `Loader.get` boilerplate for.
local handlers: { [string]: (player: Player, payload: any) -> () } = {}
local limiterStates: { [Player]: { [string]: Net.RateLimiterState } } = {}
local violationTrackers: { [Player]: Net.ViolationTracker } = {}
local roundStateProvider: RoundStateProvider = function()
	return nil
end
local reportSink: ReportSink = defaultReportSink
local flagHandler: FlagHandler = defaultFlagHandler

-- Registered by whichever service owns the real game-logic response to
-- a remote (RoundService, TaskService, ...) - called only after a
-- payload has passed every guard check.
local function on(remoteName: string, handler: (player: Player, payload: any) -> ())
	handlers[remoteName] = handler
end

-- Wired up later by RoundService once it exists (P2). Until then every
-- state-gated remote fails closed via Net.isStateAllowed's nil handling
-- - there are none yet (ExamplePing declares no states), so this has no
-- effect today, but the mechanism is real for when P2 lands.
local function setRoundStateProvider(provider: RoundStateProvider)
	roundStateProvider = provider
end

-- Point this at analytics once analytics exists; defaults to `warn` so
-- rejections are never silently invisible in the meantime.
local function setReportSink(sink: ReportSink)
	reportSink = sink
end

-- Point this at a moderation/review system once one exists. Never calls
-- Kick itself - see this file's header comment for why.
local function setFlagHandler(handler: FlagHandler)
	flagHandler = handler
end

local function report(player: Player, remoteName: string, payload: any, reason: string)
	reportSink({
		player = player,
		remote = remoteName,
		reason = reason,
		payloadSize = Net.estimatePayloadSize(payload),
	})
end

local function recordViolation(player: Player, remoteName: string)
	local tracker = violationTrackers[player]
	if tracker == nil then
		tracker = Net.newViolationTracker(os.clock())
		violationTrackers[player] = tracker
	end

	local crossed = Net.recordViolation(tracker, os.clock(), ESCALATION_WINDOW_SECONDS, ESCALATION_THRESHOLD)
	if crossed then
		flagHandler(player, remoteName, tracker.count)
	end
end

local function getRateLimiterState(player: Player, def: Net.RemoteDef): Net.RateLimiterState
	local perPlayer = limiterStates[player]
	if perPlayer == nil then
		perPlayer = {}
		limiterStates[player] = perPlayer
	end

	local state = perPlayer[def.name]
	if state == nil then
		state = Net.newRateLimiterState(def.rateLimit :: Net.RateLimit, os.clock())
		perPlayer[def.name] = state
	end

	return state
end

-- The guard pipeline itself: shape, then state, then rate limit, in
-- that order - cheapest and most-likely-to-reject checks first, so a
-- spam flood is rejected on shape/state before ever touching the token
-- bucket's bookkeeping.
local function handleServerEvent(def: Net.RemoteDef, player: Player, payload: any)
	local schema = def.schema
	if schema == nil then
		report(player, def.name, payload, "remote declares no schema - dropped by default")
		return
	end

	local shapeOk, _typedPayload, shapeErr = schema.validate(payload)
	if not shapeOk then
		report(player, def.name, payload, string.format("invalid payload: %s", shapeErr or "unknown"))
		recordViolation(player, def.name)
		return
	end

	if not Net.isStateAllowed(def, roundStateProvider()) then
		local wanted = if def.states then table.concat(def.states :: { string }, ", ") else "any"
		report(player, def.name, payload, string.format("wrong round state (needs one of: %s)", wanted))
		recordViolation(player, def.name)
		return
	end

	local limiterState = getRateLimiterState(player, def)
	if not Net.tryConsume(limiterState, os.clock()) then
		report(player, def.name, payload, "rate limit exceeded")
		recordViolation(player, def.name)
		return
	end

	local handler = handlers[def.name]
	if handler == nil then
		report(player, def.name, payload, "no handler registered for this remote yet")
		return
	end

	handler(player, payload)
end

local NetGuard: Loader.Service = {
	name = "NetGuard",
	dependencies = {},
	on = on,
	setRoundStateProvider = setRoundStateProvider,
	setReportSink = setReportSink,
	setFlagHandler = setFlagHandler,
}

function NetGuard:init()
	Net.createRemotes(ReplicatedStorage)

	for _, def in Net.Remotes do
		if def.direction ~= "ServerIntent" then
			continue
		end

		local remote = Net.getRemote(def.name)
		remote.OnServerEvent:Connect(function(player: Player, payload: any)
			handleServerEvent(def, player, payload)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		limiterStates[player] = nil
		violationTrackers[player] = nil
	end)
end

return NetGuard
