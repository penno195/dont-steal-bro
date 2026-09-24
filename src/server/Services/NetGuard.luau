--!strict
-- The single choke point every ServerIntent remote passes through before
-- any real game-logic handler sees it. Net.luau (src/shared/Net.luau)
-- declares WHAT a remote looks like; this is what ENFORCES that
-- declaration against a client that Ground Rule 1 says is fully
-- compromised: per-player rate limiting, exact-shape payload validation
-- and a round-state gate, in that order, before a handler ever runs.
--
-- WHAT THIS WOULD NOT SAVE YOU FROM if you skipped server-side
-- validation somewhere else and relied on the client instead:
--   - Truthfulness. A well-shaped, rate-limit-respecting, correctly-
--     timed payload can still be a LIE - "I finished the task" with no
--     server-side proof is a validly-shaped remote call, not a valid
--     task completion. Shape/rate/state are necessary, never sufficient;
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
-- Rejections never throw. Escalation is log, then throttle (the rate
-- limiter itself), then flag-for-review through the flag hook - see
-- Net.recordViolation's doc comment. The ONE thing this module kicks
-- for is repeated MALFORMED traffic (P8-1 F4): a payload that fails its
-- schema, or any call on a server-to-client remote. Client and server
-- always run the same place version, so the real client never produces
-- either - unlike a wrong-state or over-rate call, which a legitimate
-- player can trip (a tap in flight as the race ends, a fast masher) and
-- which therefore only ever flag, never kick.

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

-- This many malformed calls within this many seconds is a kick (see the
-- header). Tighter than a flag would warrant only because a false
-- positive here requires a client that isn't ours.
local MALFORMED_KICK_THRESHOLD = 5
local MALFORMED_KICK_WINDOW_SECONDS = 10
local MALFORMED_KICK_MESSAGE = "Disconnected: your client sent data this game doesn't accept."

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
local malformedTrackers: { [Player]: Net.ViolationTracker } = {}
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

-- Wired up by RoundService's init() (P2-1: `NetGuard.setRoundStateProvider
-- (function() return currentState end)`). No remote declares a `states`
-- gate yet, so this has no observable effect today, but the mechanism is
-- real for whenever the first one does (Net.isStateAllowed fails closed
-- on an unrecognised state either way).
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

-- Per-player budget for REPORTS, separate from every remote's own call
-- budget (P8-1). Without it, 1000 junk calls a second were 1000 `warn`
-- lines a second: the flood's cost landed on the server's log pipeline
-- instead of on the attacker. Past the budget, reports are counted and
-- the count rides along on the next one that is let through, so the log
-- still says how big the flood was without printing every line of it.
local REPORT_RATE_LIMIT: Net.RateLimit = { capacity = 10, refillPerSecond = 1 }
local reportLimiters: { [Player]: Net.RateLimiterState } = {}
local suppressedReports: { [Player]: number } = {}

local function report(player: Player, remoteName: string, payload: any, reason: string)
	local limiter = reportLimiters[player]
	if limiter == nil then
		limiter = Net.newRateLimiterState(REPORT_RATE_LIMIT, os.clock())
		reportLimiters[player] = limiter
	end
	if not Net.tryConsume(limiter, os.clock()) then
		suppressedReports[player] = (suppressedReports[player] or 0) + 1
		return
	end

	local suppressed = suppressedReports[player]
	suppressedReports[player] = nil
	reportSink({
		player = player,
		remote = remoteName,
		reason = if suppressed then string.format("%s (+%d similar suppressed)", reason, suppressed) else reason,
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

-- Malformed traffic only - see the header for why this, and nothing
-- else, kicks. Also counts toward the ordinary flag signal above.
local function recordMalformed(player: Player, remoteName: string)
	recordViolation(player, remoteName)

	local tracker = malformedTrackers[player]
	if tracker == nil then
		tracker = Net.newViolationTracker(os.clock())
		malformedTrackers[player] = tracker
	end

	if Net.recordViolation(tracker, os.clock(), MALFORMED_KICK_WINDOW_SECONDS, MALFORMED_KICK_THRESHOLD) then
		warn(
			string.format(
				"NetGuard: kicking %s (%d) - %d malformed calls within %ds, last on %s",
				player.Name,
				player.UserId,
				tracker.count,
				MALFORMED_KICK_WINDOW_SECONDS,
				remoteName
			)
		)
		player:Kick(MALFORMED_KICK_MESSAGE)
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

-- The guard pipeline itself: rate limit, then shape, then state.
--
-- Rate limit FIRST (P8-1). It used to run last, on the theory that
-- shape/state are cheaper and reject most spam - but that meant a
-- malformed or wrong-state call never touched the bucket at all, so a
-- flood of junk was entirely unthrottled and every call paid for a
-- schema walk and a report. Charging the bucket up front means every
-- call, well-formed or not, spends from the same per-remote budget; a
-- legitimate client never sends junk, so this costs it nothing.
local function handleServerEvent(def: Net.RemoteDef, player: Player, payload: any)
	-- An event can still arrive after PlayerRemoving has cleared this
	-- player's state; handling it would just re-create that state and
	-- leak it for the rest of the server's life.
	if player.Parent ~= Players then
		return
	end

	local schema = def.schema
	if schema == nil then
		report(player, def.name, payload, "remote declares no schema - dropped by default")
		recordMalformed(player, def.name)
		return
	end

	local limiterState = getRateLimiterState(player, def)
	if not Net.tryConsume(limiterState, os.clock()) then
		report(player, def.name, payload, "rate limit exceeded")
		recordViolation(player, def.name)
		return
	end

	local shapeOk, _typedPayload, shapeErr = schema.validate(payload)
	if not shapeOk then
		report(player, def.name, payload, string.format("invalid payload: %s", shapeErr or "unknown"))
		recordMalformed(player, def.name)
		return
	end

	if not Net.isStateAllowed(def, roundStateProvider()) then
		local wanted = if def.states then table.concat(def.states :: { string }, ", ") else "any"
		report(player, def.name, payload, string.format("wrong round state (needs one of: %s)", wanted))
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

	-- Every remote gets a listener, ServerBroadcasts included (P8-1). A
	-- client can FireServer on a broadcast remote too, and with no
	-- listener Roblox queues each call and then logs "invocation queue
	-- exhausted" once per call - an unthrottled log flood. Connected here,
	-- a broadcast has no schema, so handleServerEvent drops it through
	-- the same throttled report as any other junk.
	for _, def in Net.Remotes do
		local remote = Net.getRemote(def.name)
		remote.OnServerEvent:Connect(function(player: Player, payload: any)
			handleServerEvent(def, player, payload)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		limiterStates[player] = nil
		violationTrackers[player] = nil
		malformedTrackers[player] = nil
		reportLimiters[player] = nil
		suppressedReports[player] = nil
	end)
end

return NetGuard
