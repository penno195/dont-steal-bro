--!strict
-- tasks-catalogue.md #8, `breaker-sequence`: "flip a bank of switches in
-- the exact order a control panel flashes at you." A Sequence task like
-- CodePlayback.luau, and it reuses that task's KeypadDigitSubmit remote:
-- `digit` is the switch number (1..SWITCH_COUNT), so no new wire shape.
--
-- The sequence is rolled fresh every attempt from ctx.rng and sent to
-- the client to FLASH (the whole premise, as with code-playback). Each
-- tap is checked against the server's own index into it.
--
-- Failure/retry (tasks-catalogue.md): a wrong flip resets progress and
-- the view replays the SAME sequence, up to MAX_REPLAYS times. The miss
-- after that is a full reset: a new sequence is rolled and sent back in
-- that miss's feedback, to be flashed like the first. That's a fresh
-- challenge for this one player, not an answer to anything already
-- asked, and it goes only to them (TaskResult is fireClient).

local Types = require(script.Parent.Types)

type Challenge = {
	switchCount: number,
	sequence: { number }, -- switch numbers, flashed in this order
}

type State = {
	sequence: { number }, -- kept server-side; only re-sent on a full reset
	nextIndex: number, -- 1-based index into `sequence` of the next flip expected
	misses: number, -- wrong flips on this sequence; past MAX_REPLAYS it's rerolled
}

type Submission = {
	digit: number, -- the switch flipped, one per KeypadDigitSubmit call
}

local SWITCH_COUNT = 6
local MIN_LENGTH = 4 -- tasks-catalogue.md's own "4-6 switches"
local MAX_LENGTH = 6
local EASY_LENGTH = 3 -- Task Insight's easy tier
local MAX_REPLAYS = 2

-- `length` distinct switches in a random order: a partial Fisher-Yates
-- shuffle of 1..SWITCH_COUNT. Distinct, because a bank of breakers each
-- flipped once reads as a sequence; flipping one twice doesn't.
local function roll(rng: Random, length: number): { number }
	local pool = {}
	for i = 1, SWITCH_COUNT do
		pool[i] = i
	end
	for i = 1, length do
		local j = rng:NextInteger(i, SWITCH_COUNT)
		pool[i], pool[j] = pool[j], pool[i]
	end
	return table.move(pool, 1, length, 1, {})
end

local function rollFor(ctx: Types.TaskContext): { number }
	return roll(ctx.rng, if ctx.easy then EASY_LENGTH else ctx.rng:NextInteger(MIN_LENGTH, MAX_LENGTH))
end

local function start(ctx: Types.TaskContext): (Challenge, State)
	local sequence = rollFor(ctx)
	return { switchCount = SWITCH_COUNT, sequence = sequence }, { sequence = sequence, nextIndex = 1, misses = 0 }
end

-- Feedback names only the switch just flipped and how many are in so far
-- (so the bank can latch the accepted ones and drop them on a miss). On
-- a miss it says whether to replay the same flash, or carries the new
-- sequence after a full reset.
local function validate(
	ctx: Types.TaskContext,
	state: State,
	submission: Submission
): (boolean, State, Types.TaskFeedback?)
	local switch = submission.digit
	-- Not a switch on this bank (the remote allows 0-9): ignored, not a miss.
	if switch < 1 or switch > SWITCH_COUNT then
		return false, state
	end

	if switch ~= state.sequence[state.nextIndex] then
		local misses = state.misses + 1
		if misses > MAX_REPLAYS then
			local sequence = rollFor(ctx)
			return false, { sequence = sequence, nextIndex = 1, misses = 0 }, { accepted = false, sequence = sequence }
		end
		return false, { sequence = state.sequence, nextIndex = 1, misses = misses }, { accepted = false, replay = true }
	end

	local feedback = { accepted = true, entered = state.nextIndex, switch = switch }
	if state.nextIndex >= #state.sequence then
		return true, state, feedback
	end
	return false, { sequence = state.sequence, nextIndex = state.nextIndex + 1, misses = state.misses }, feedback
end

local function cleanup(_ctx: Types.TaskContext, _state: State)
	-- Nothing to release - see CodePlayback.luau's identical no-op for
	-- why this is present rather than omitted.
end

local BreakerSequence: Types.TaskHandler<Challenge, State, Submission> = {
	taskId = "breaker-sequence",
	start = start,
	validate = validate,
	cleanup = cleanup,
}

return BreakerSequence
