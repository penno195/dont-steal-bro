--!strict
-- tasks-catalogue.md #13, `airlock-cycle`: "time a door cycle so you seal
-- the chamber in the narrow gap between two moving hazard indicators."
-- The gentlest Timing task, on the same sweep maths as ReactorSync.luau
-- (src/shared/TimingLogic.luau), with its own speed/tolerance profile.
--
-- Two hazard lights travel the track together with a gap between them;
-- the gap's centre is TimingLogic.position of the attempt's server clock.
-- The door sits at the middle of the track. Seal (TimingSubmit) while the
-- whole door is inside the gap and it's done - one good tap. A bad seal just
-- replays: the gap rests a beat and sweeps again, nothing else changes
-- (tasks-catalogue.md: "stateless between attempts by design").

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TimingLogic = require(ReplicatedStorage.Shared.TimingLogic)
local Types = require(script.Parent.Types)

type Challenge = {
	sweepStart: number, -- attempt-clock time the gap starts moving
	period: number, -- seconds per pass along the track
	gapHalfWidth: number, -- how far either side of the door the gap still covers it
	door: number, -- the door's place on the track, 0..1
	doorHalfWidth: number, -- the door's own half-width on the track; the view draws it this size
}

type State = Challenge & {
	lastStopAt: number?,
}

type Submission = {
	at: number, -- the attempt-clock time the client says it tapped
}

local DOOR = 0.5
local MIN_PERIOD = 1.3
local MAX_PERIOD = 1.7
-- Tightened after a playtest (2026-10-18: seals counted "when it's not
-- covering"): the check used to be the door's CENTRE inside the gap, so
-- half the door could hang out of the green and still seal. Now the
-- whole door must fit, so the slack either side is gap minus door. The
-- gap is drawn a little wider to suit; the seal window went from ~0.27s
-- to ~0.14s of a 1.5s pass (easy tier: ~0.26s).
local DOOR_HALF_WIDTH = 0.0625
local GAP_HALF_WIDTH = 0.11
local EASY_GAP_HALF_WIDTH = 0.15 -- Task Insight's easy tier
local LEAD_IN = 0.8 -- the first sweep waits for the sheet to slide in
local PAUSE = 0.6 -- the rest after a bad seal

local function start(ctx: Types.TaskContext): (Challenge, State)
	local challenge: Challenge = {
		sweepStart = LEAD_IN,
		period = MIN_PERIOD + ctx.rng:NextNumber() * (MAX_PERIOD - MIN_PERIOD),
		gapHalfWidth = if ctx.easy then EASY_GAP_HALF_WIDTH else GAP_HALF_WIDTH,
		door = DOOR,
		doorHalfWidth = DOOR_HALF_WIDTH,
	}
	local state: State = table.clone(challenge) :: any
	state.lastStopAt = nil
	return challenge, state
end

-- Feedback on a bad seal: where the gap was, and when the replay starts.
local function validate(
	ctx: Types.TaskContext,
	state: State,
	submission: Submission
): (boolean, State, Types.TaskFeedback?)
	local at = TimingLogic.clampStop(submission.at, ctx.elapsedSeconds(), state.lastStopAt)
	-- No honest time left for it, or the gap hasn't started moving: ignored.
	if at == nil or at <= state.sweepStart then
		return false, state
	end

	local gap = TimingLogic.position(at, state.sweepStart, state.period)
	if TimingLogic.within(gap, state.door, state.gapHalfWidth - state.doorHalfWidth) then
		return true, state, { sealed = true, gapAt = gap }
	end

	local nextState: State = table.clone(state)
	nextState.lastStopAt = at
	nextState.sweepStart = at + PAUSE
	return false, nextState, { sealed = false, gapAt = gap, sweepStart = nextState.sweepStart }
end

local function cleanup(_ctx: Types.TaskContext, _state: State)
	-- Nothing to release - see CodePlayback.luau's identical no-op for
	-- why this is present rather than omitted.
end

local AirlockCycle: Types.TaskHandler<Challenge, State, Submission> = {
	taskId = "airlock-cycle",
	start = start,
	validate = validate,
	cleanup = cleanup,
}

return AirlockCycle
