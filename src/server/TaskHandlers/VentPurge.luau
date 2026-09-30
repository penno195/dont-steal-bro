--!strict
-- tasks-catalogue.md #2, `vent-purge` - "clear a toxic gas buildup by
-- punching an extractor fan control in a burst." The catalogue calls it
-- a reskin-only variant of Pressure Valve, and this handler is exactly
-- PressureValve.luau's shape with the catalogue's own numbers: a
-- distinct tap-target range (14-20) and the same ~70ms human interval.
--
-- SIMPLIFICATION, NOTED HONESTLY (the stance PressureValve.luau takes on
-- its own gauge): the catalogue's gas meter "ticks up on a fixed server
-- heartbeat". This handler gets the same guarantee - the failure clock
-- is server time, so a throttled client can't stall it - by checking
-- elapsed time lazily on each accepted tap rather than running a live
-- ticker, since the only observable moment is the reset itself.

local Types = require(script.Parent.Types)

type Challenge = {
	-- The target count stays server-side, as in PressureValve.luau.
	gasFillSeconds: number,
}

type State = {
	targetTapCount: number, -- rolled once at start(), constant for the whole attempt
	tapCount: number, -- resets to 0 when the gas meter fills
	cycleStartedAtElapsed: number, -- ctx.elapsedSeconds() value when the current (post-reset) cycle began
	lastAcceptedTapElapsed: number?, -- nil until the first accepted tap
}

type Submission = {} -- TapSubmit carries only stationId, already consumed by the dispatcher

local MIN_TARGET_TAPS = 14
local MAX_TARGET_TAPS = 20
-- Task Insight's easy tier: the same gas budget, far fewer taps.
local EASY_MIN_TARGET_TAPS = 8
local EASY_MAX_TARGET_TAPS = 12
local MIN_TAP_INTERVAL_SECONDS = 0.07
local GAS_FILL_SECONDS = 6 -- the gas meter's budget; target time is 5-7s

local function start(ctx: Types.TaskContext): (Challenge, State)
	local challenge: Challenge = { gasFillSeconds = GAS_FILL_SECONDS }
	local state: State = {
		targetTapCount = if ctx.easy
			then ctx.rng:NextInteger(EASY_MIN_TARGET_TAPS, EASY_MAX_TARGET_TAPS)
			else ctx.rng:NextInteger(MIN_TARGET_TAPS, MAX_TARGET_TAPS),
		tapCount = 0,
		cycleStartedAtElapsed = 0,
		lastAcceptedTapElapsed = nil,
	}
	return challenge, state
end

-- Feedback drives the thermometer: how far this player's accepted taps
-- have purged (0..1), and whether this tap landed after the gas meter
-- filled and started a fresh cycle. A dropped (too-fast) tap sends none.
local function validate(
	ctx: Types.TaskContext,
	state: State,
	_submission: Submission
): (boolean, State, Types.TaskFeedback?)
	local nowElapsed = ctx.elapsedSeconds()

	-- Too fast to be human: silently dropped, changes nothing.
	if
		state.lastAcceptedTapElapsed ~= nil
		and (nowElapsed - state.lastAcceptedTapElapsed) < MIN_TAP_INTERVAL_SECONDS
	then
		return false, state
	end

	-- Gas meter filled first: "meter and tap progress both reset, retry
	-- is immediate" (tasks-catalogue.md). This tap opens the new cycle.
	if nowElapsed - state.cycleStartedAtElapsed >= GAS_FILL_SECONDS then
		return false,
			{
				targetTapCount = state.targetTapCount,
				tapCount = 1,
				cycleStartedAtElapsed = nowElapsed,
				lastAcceptedTapElapsed = nowElapsed,
			},
			{ progress = 1 / state.targetTapCount, reset = true }
	end

	local newTapCount = state.tapCount + 1
	local nextState: State = {
		targetTapCount = state.targetTapCount,
		tapCount = newTapCount,
		cycleStartedAtElapsed = state.cycleStartedAtElapsed,
		lastAcceptedTapElapsed = nowElapsed,
	}

	return newTapCount >= state.targetTapCount,
		nextState,
		{ progress = math.min(1, newTapCount / state.targetTapCount), reset = false }
end

local function cleanup(_ctx: Types.TaskContext, _state: State)
	-- Nothing to release - see CodePlayback.luau's identical no-op.
end

local VentPurge: Types.TaskHandler<Challenge, State, Submission> = {
	taskId = "vent-purge",
	start = start,
	validate = validate,
	cleanup = cleanup,
}

return VentPurge
