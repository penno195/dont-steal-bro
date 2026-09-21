--!strict
-- tasks-catalogue.md #1, `pressure-valve` - P2-6's Tap reference task:
-- "vent a bursting pipe before the gauge maxes out." Matches the
-- reference keypad task's structure/naming/comment style exactly
-- (CodePlayback.luau); the only new shape here is Tap's own mechanic -
-- a server-rolled tap TARGET COUNT instead of a sequence, plus the
-- catalogue's own min-tap-interval rule and gauge-reset failure mode.
--
-- SIMPLIFICATION, NOTED HONESTLY (same stance CodePlayback.luau takes on
-- its own mercy-reroll gap): tasks-catalogue.md's "gauge" is described as
-- filling toward 100% on its own over real time. This handler
-- implements the same OBSERVABLE behavior - progress resets to 0 if the
-- rolled tap target isn't reached within a time budget - by checking
-- elapsed time lazily on each accepted tap rather than running a live
-- server-side ticking gauge, since nothing here needs a client-visible
-- percentage, only the pass/fail moment the catalogue actually specifies.
-- A live gauge value for the client to animate is additive UI polish,
-- not a framework or validation gap.

local Types = require(script.Parent.Types)

type Challenge = {
	-- Deliberately NOT the rolled target count - "returns only what the
	-- client needs to render it, never the answer" (Types.luau's own
	-- contract). The client only needs to know a tap loop has started;
	-- tasks-catalogue.md's own client view never shows the target either
	-- (a real gauge fills from FEEL, not a visible counter).
	meterFillSeconds: number,
}

type State = {
	targetTapCount: number, -- rolled once at start(), constant for the whole attempt
	tapCount: number, -- resets to 0 on a gauge-max, never on a merely-slow-but-still-within-budget tap
	cycleStartedAtElapsed: number, -- ctx.elapsedSeconds() value when the current (post-reset) cycle began
	lastAcceptedTapElapsed: number?, -- nil until the first accepted tap
}

type Submission = {} -- TapSubmit's payload carries only stationId, already consumed by the dispatcher - nothing task-specific to pass through

local MIN_TARGET_TAPS = 18
local MAX_TARGET_TAPS = 24
local MIN_TAP_INTERVAL_SECONDS = 0.07 -- tasks-catalogue.md's own "~70ms"
local METER_FILL_SECONDS = 6 -- the time budget a cycle has to reach the target before the gauge maxes and resets

local function start(ctx: Types.TaskContext): (Challenge, State)
	local challenge: Challenge = { meterFillSeconds = METER_FILL_SECONDS }
	local state: State = {
		targetTapCount = ctx.rng:NextInteger(MIN_TARGET_TAPS, MAX_TARGET_TAPS),
		tapCount = 0,
		cycleStartedAtElapsed = 0,
		lastAcceptedTapElapsed = nil,
	}
	return challenge, state
end

local function validate(ctx: Types.TaskContext, state: State, _submission: Submission): (boolean, State)
	local nowElapsed = ctx.elapsedSeconds()

	-- "server increments its own counter only if the elapsed time since
	-- the last accepted tap exceeds a minimum human interval... silently
	-- dropping faster taps" (tasks-catalogue.md, verbatim) - a dropped
	-- tap changes NOTHING: doesn't count toward the target, doesn't
	-- count toward (or reset) the gauge either, as if it never happened.
	if
		state.lastAcceptedTapElapsed ~= nil
		and (nowElapsed - state.lastAcceptedTapElapsed) < MIN_TAP_INTERVAL_SECONDS
	then
		return false, state
	end

	-- Gauge maxed before the target was reached - "resets to 0%... no
	-- lockout... immediately retry" (tasks-catalogue.md). This accepted
	-- tap becomes the FIRST tap of the new cycle rather than being
	-- wasted.
	if nowElapsed - state.cycleStartedAtElapsed >= METER_FILL_SECONDS then
		return false,
			{
				targetTapCount = state.targetTapCount,
				tapCount = 1,
				cycleStartedAtElapsed = nowElapsed,
				lastAcceptedTapElapsed = nowElapsed,
			}
	end

	local newTapCount = state.tapCount + 1
	local nextState: State = {
		targetTapCount = state.targetTapCount,
		tapCount = newTapCount,
		cycleStartedAtElapsed = state.cycleStartedAtElapsed,
		lastAcceptedTapElapsed = nowElapsed,
	}

	return newTapCount >= state.targetTapCount, nextState
end

local function cleanup(_ctx: Types.TaskContext, _state: State)
	-- Nothing to release - see CodePlayback.luau's identical no-op for
	-- why this is present rather than omitted.
end

local PressureValve: Types.TaskHandler<Challenge, State, Submission> = {
	taskId = "pressure-valve",
	start = start,
	validate = validate,
	cleanup = cleanup,
}

return PressureValve
