--!strict
-- tasks-catalogue.md #3, `alarm-killswitch` - the Hold reference task:
-- "hold down a stiff breaker to kill a blaring alarm." Same structure as
-- PressureValve.luau; the new shape is Hold's own mechanic - the client
-- sends only press/release edges (HoldSubmit) and the server times the
-- interval between them on its own clock (ctx.elapsedSeconds()). A
-- client-reported duration never exists, so there is nothing to forge.
--
-- The rolled hold length IS sent in the challenge, so the view can fill
-- its bar. Knowing it skips nothing: the press still has to be held that
-- long in server time, and holding longer only wastes the player's own.
--
-- Releasing early resets to nothing held; no penalty beyond the lost
-- time (tasks-catalogue.md). Completion is the release edge after the
-- hold is long enough - the view releases for the player the moment its
-- bar fills, so they never have to guess when to let go.

local Types = require(script.Parent.Types)

type Challenge = {
	holdSeconds: number,
}

type State = {
	holdSeconds: number, -- rolled once at start(), constant for the whole attempt
	pressedAtElapsed: number?, -- ctx.elapsedSeconds() at the current press; nil while released
}

type Submission = {
	pressed: boolean,
}

local MIN_HOLD_SECONDS = 4.5 -- tasks-catalogue.md's own "4.5-6.5s"
local MAX_HOLD_SECONDS = 6.5
-- Task Insight's easy tier: the same breaker, a shorter hold.
local EASY_MIN_HOLD_SECONDS = 2.5
local EASY_MAX_HOLD_SECONDS = 3.5
-- Network jitter between the press and release edges can shave a few
-- frames off an honest hold. This much short still counts; the view
-- releases a little past the full hold to stay well clear of it.
local JITTER_TOLERANCE_SECONDS = 0.2

local function start(ctx: Types.TaskContext): (Challenge, State)
	local min = if ctx.easy then EASY_MIN_HOLD_SECONDS else MIN_HOLD_SECONDS
	local max = if ctx.easy then EASY_MAX_HOLD_SECONDS else MAX_HOLD_SECONDS
	-- Tenths of a second: plenty of spread without a float-y challenge.
	local holdSeconds = ctx.rng:NextInteger(min * 10, max * 10) / 10
	return { holdSeconds = holdSeconds }, { holdSeconds = holdSeconds, pressedAtElapsed = nil }
end

-- Feedback echoes the edge the server accepted (`holding`), and on an
-- early release says so (`early`), so the view's bar follows the
-- server's idea of the hold rather than its own. A repeated edge (a
-- second press while held, a release while released) changes nothing
-- and sends none.
local function validate(
	ctx: Types.TaskContext,
	state: State,
	submission: Submission
): (boolean, State, Types.TaskFeedback?)
	local nowElapsed = ctx.elapsedSeconds()

	if submission.pressed then
		if state.pressedAtElapsed ~= nil then
			return false, state
		end
		return false, { holdSeconds = state.holdSeconds, pressedAtElapsed = nowElapsed }, { holding = true }
	end

	if state.pressedAtElapsed == nil then
		return false, state
	end

	local released: State = { holdSeconds = state.holdSeconds, pressedAtElapsed = nil }
	if nowElapsed - state.pressedAtElapsed >= state.holdSeconds - JITTER_TOLERANCE_SECONDS then
		return true, released, { holding = false, early = false }
	end
	return false, released, { holding = false, early = true }
end

local function cleanup(_ctx: Types.TaskContext, _state: State)
	-- Nothing to release - see CodePlayback.luau's identical no-op for
	-- why this is present rather than omitted.
end

local AlarmKillswitch: Types.TaskHandler<Challenge, State, Submission> = {
	taskId = "alarm-killswitch",
	start = start,
	validate = validate,
	cleanup = cleanup,
}

return AlarmKillswitch
