--!strict
-- The task-handler contract every mini-task's server side implements
-- (P2-5). This is the interface Ground Rule 2 says gets copied ~15
-- times, so its shape lives in exactly one place: a handler module (one
-- per task, src/server/TaskHandlers/<Name>.luau) only ever has to
-- implement `start`/`validate`/`cleanup` against the `TaskContext` this
-- file describes - it never reaches into Players, CollectionService, or
-- GameConfig itself ("a handler must never reach for game state
-- directly," the task's own requirement). TaskHandlerService.luau is the
-- dispatcher that actually builds a TaskContext and calls into a
-- handler; this file only declares the shapes both sides agree on.
--
-- Roblox-touching on purpose (TaskContext carries a real Player,
-- BasePart and Random) - unlike TaskAssignment.luau/Qualification.luau,
-- a task handler's whole job is a live player interacting with a live
-- station, so there's no pure subset to split out of this particular
-- file. A handler's OWN game logic (is this the right digit, did they
-- tap enough times) still comes in through explicitly typed `Challenge`/
-- `State`/`Submission` arguments below rather than closing over
-- anything, which is what keeps THAT logic testable in isolation even
-- though this contract itself isn't.

local Types = {}

export type TaskContext = {
	player: Player,
	stationId: string,
	stationPart: BasePart,
	rng: Random,

	-- "ctx carries... elapsed time" (the task's own requirement) - a
	-- function, not a snapshot number, so a handler always reads the
	-- CURRENT elapsed time at the moment it actually checks one, not
	-- whatever it was when the ctx was first built.
	elapsedSeconds: () -> number,
}

-- start() generates the challenge - "returns only what the client needs
-- to render it, never the answer" (the task's own requirement) - as
-- `Challenge`, plus the handler's own private progress state as `State`.
-- State is kept OUT of Challenge and never sent to the client - see
-- TaskHandlerService.luau for how it's threaded server-side through
-- subsequent validate() calls without ever crossing the network. For a
-- memory/playback-style task, `Challenge` legitimately CAN include the
-- answer itself (code-playback's whole premise is "the client is shown
-- a code, then has to re-enter it") - "never the answer" means never
-- leak it to a player who hasn't earned the right to see it, which is a
-- question of WHO the payload is sent to (Net.fireClient, targeted -
-- never Net.fireAllClients), not whether the payload can ever contain
-- the answer at all. See TaskHandlerService.luau's header comment for
-- the concrete exploit this distinction prevents.
--
-- validate() is called once per submitted intent (one digit tap, one
-- aim-stop signal, whatever shape a task's own input takes) - NOT once
-- per whole attempt - and returns whether the task is now fully
-- complete, plus the (possibly updated) State to carry into the next
-- call. One contract this way covers both a single-shot task
-- (Timing/Aim: one submission, immediately true or false) and a
-- multi-step one (Sequence: several submissions, true only once the
-- last one lands) without a second, different shape for either case.
--
-- cleanup() always runs exactly once per attempt - on success, on the
-- player leaving mid-task, or on a forced cancel (a future power-up
-- freeze, a new interaction restarting the same station) - see
-- TaskHandlerService.luau's session bookkeeping for the exactly-once
-- guarantee. Most handlers have nothing to release and can leave it
-- empty; it exists for the task that eventually does (spawns a
-- temporary prop, starts a sound loop - anything with a lifetime tied to
-- the attempt rather than the station itself).
--
-- validate()'s optional third return is per-submission feedback, sent
-- to the submitting player only inside TaskResult. It may describe THAT
-- submission (Fuse Rewire: "fuse-2 into slot-3 was accepted") - which
-- the player just chose, so it reveals nothing - but never the answer
-- to one they haven't made. Its shape is the task's own; the view that
-- renders it is the only reader.
export type TaskFeedback = { [string]: any }

export type TaskHandler<Challenge, State, Submission> = {
	taskId: string,
	start: (ctx: TaskContext) -> (Challenge, State),
	validate: (ctx: TaskContext, state: State, submission: Submission) -> (boolean, State, TaskFeedback?),
	cleanup: (ctx: TaskContext, state: State) -> (),
}

-- Shared environmental guards TaskHandlerService enforces BEFORE a
-- handler's own validate() ever runs - "enforces a minimum plausible
-- completion time, that the player is still within range of the
-- station, and that the task is actually on their list and not already
-- complete" (the task's own requirement, verbatim). Defined once, here,
-- rather than left for each of ~15 handler authors to remember to
-- re-implement - see TaskHandlerService.luau for where these are
-- actually checked.
Types.MIN_PLAUSIBLE_COMPLETION_FRACTION = 0.4 -- a submission faster than 40% of a task's own declared minimum expected duration is implausible for any human, regardless of which task it is
-- How long a correct final submission waits before it counts, so no
-- attempt ever completes faster than the plausible floor. Applied to the
-- COMPLETING submission only: gating every submission silently dropped
-- a fast player's first fuse drops, and the view looked frozen.
function Types.completionDelaySeconds(expectedMinSeconds: number?, elapsedSeconds: number): number
	if expectedMinSeconds == nil then
		return 0
	end
	return math.max(0, expectedMinSeconds * Types.MIN_PLAUSIBLE_COMPLETION_FRACTION - elapsedSeconds)
end

Types.INTERACT_RANGE_STUDS = 12 -- generous enough for normal camera/controller drift, tight enough that "I wasn't even there" isn't plausible

return Types
