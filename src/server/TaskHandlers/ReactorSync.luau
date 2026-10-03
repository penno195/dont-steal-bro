--!strict
-- tasks-catalogue.md #11, `reactor-sync` - the Timing reference task:
-- "stop a sweeping needle inside a narrow safe band." The needle is
-- TimingLogic.position of the attempt's server clock; a stop (TimingSubmit)
-- claims when the player tapped, TimingLogic.clampStop holds that claim
-- to what the server's clock allows, and the needle's position at that
-- moment is checked against the band. See TimingLogic.luau's header for
-- exactly what the clamp does and doesn't allow.
--
-- Three syncs in a row win it. Each hit speeds the needle up and moves
-- the band. A miss costs one of three lives; losing the last resets the
-- syncs and the speed to the easy start (tasks-catalogue.md: "so a bad
-- first attempt doesn't spiral"). After every stop the needle rests a
-- beat at 0, then sweeps again from there.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TimingLogic = require(ReplicatedStorage.Shared.TimingLogic)
local Types = require(script.Parent.Types)

type Sweep = {
	sweepStart: number, -- attempt-clock time the needle leaves 0
	period: number, -- seconds per pass across the dial
	bandCenter: number, -- 0..1
}

type Challenge = Sweep & {
	bandHalfWidth: number,
	hitsNeeded: number,
	lives: number,
}

type State = Sweep & {
	bandHalfWidth: number,
	hitsNeeded: number,
	hits: number,
	lives: number,
	lastStopAt: number?,
}

type Submission = {
	at: number, -- the attempt-clock time the client says it tapped
}

local HITS_NEEDED = 3
local EASY_HITS_NEEDED = 2 -- Task Insight's easy tier
local LIVES = 3
-- Eased after the first playtest (2026-10-03: "quite difficult"): a
-- slower start, a gentler speed-up and a wider band. The third sync's
-- window went from ~0.13s to ~0.19s.
local START_PERIOD = 1.25
local SPEED_UP = 0.9 -- each hit multiplies the period by this
local BAND_HALF_WIDTH = 0.095
local EASY_BAND_HALF_WIDTH = 0.125
-- Band centres stay off the ends so a needle resting at 0 never sits in one.
local BAND_MIN = 0.3
local BAND_MAX = 0.9
local LEAD_IN = 0.8 -- the first sweep waits for the sheet to slide in
local PAUSE = 0.5 -- the rest after each stop

local function rollBand(ctx: Types.TaskContext): number
	return BAND_MIN + ctx.rng:NextNumber() * (BAND_MAX - BAND_MIN)
end

local function start(ctx: Types.TaskContext): (Challenge, State)
	local hitsNeeded = if ctx.easy then EASY_HITS_NEEDED else HITS_NEEDED
	local bandHalfWidth = if ctx.easy then EASY_BAND_HALF_WIDTH else BAND_HALF_WIDTH
	local bandCenter = rollBand(ctx)
	local challenge: Challenge = {
		sweepStart = LEAD_IN,
		period = START_PERIOD,
		bandCenter = bandCenter,
		bandHalfWidth = bandHalfWidth,
		hitsNeeded = hitsNeeded,
		lives = LIVES,
	}
	local state: State = {
		sweepStart = LEAD_IN,
		period = START_PERIOD,
		bandCenter = bandCenter,
		bandHalfWidth = bandHalfWidth,
		hitsNeeded = hitsNeeded,
		hits = 0,
		lives = LIVES,
		lastStopAt = nil,
	}
	return challenge, state
end

-- Feedback: whether the stop was in the band, the score after it, and the
-- next sweep to draw (start time, speed, band) - all things the player
-- needs on screen next, none of them about a stop not yet made.
local function validate(
	ctx: Types.TaskContext,
	state: State,
	submission: Submission
): (boolean, State, Types.TaskFeedback?)
	local at = TimingLogic.clampStop(submission.at, ctx.elapsedSeconds(), state.lastStopAt)
	-- No honest time left for it, or the needle hasn't left 0 yet: ignored.
	if at == nil or at <= state.sweepStart then
		return false, state
	end

	local pos = TimingLogic.position(at, state.sweepStart, state.period)
	local hit = TimingLogic.within(pos, state.bandCenter, state.bandHalfWidth)

	local nextState: State = table.clone(state)
	nextState.lastStopAt = at
	nextState.sweepStart = at + PAUSE
	nextState.bandCenter = rollBand(ctx)
	local reset = false
	if hit then
		nextState.hits += 1
		nextState.period = state.period * SPEED_UP
	else
		nextState.lives -= 1
		if nextState.lives <= 0 then
			reset = true
			nextState.hits = 0
			nextState.lives = LIVES
			nextState.period = START_PERIOD
		end
	end

	local feedback = {
		hit = hit,
		stoppedAt = pos,
		hits = nextState.hits,
		lives = nextState.lives,
		reset = reset,
		sweepStart = nextState.sweepStart,
		period = nextState.period,
		bandCenter = nextState.bandCenter,
	}
	return nextState.hits >= state.hitsNeeded, nextState, feedback
end

local function cleanup(_ctx: Types.TaskContext, _state: State)
	-- Nothing to release - see CodePlayback.luau's identical no-op for
	-- why this is present rather than omitted.
end

local ReactorSync: Types.TaskHandler<Challenge, State, Submission> = {
	taskId = "reactor-sync",
	start = start,
	validate = validate,
	cleanup = cleanup,
}

return ReactorSync
