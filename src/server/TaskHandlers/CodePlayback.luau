--!strict
-- tasks-catalogue.md #9, `code-playback` - the P2-5 reference task:
-- "watch a keypad flash a code, then re-enter it from memory," verb
-- Sequence. Implements the Types.luau TaskHandler contract end to end so
-- P2-6's two more tasks have a proven pattern to copy, not just a
-- theoretical interface.
--
-- A 4-digit code (digits 0-9), rolled fresh server-side every attempt
-- from ctx.rng - never derived from anything the client sent, and never
-- reused across attempts, so replaying a previous attempt's code is
-- worthless (tasks-catalogue.md's own "Shared validation principle").
--
-- SIMPLIFICATION, NOTED HONESTLY: tasks-catalogue.md's own write-up adds
-- a "soft catch-up mercy" - after 2 consecutive fails, the server flashes
-- a new, SHORTER code. This handler implements the simpler "a wrong
-- digit resets progress on the same code" rule instead. That's a
-- gameplay-tuning gap, not a framework one - the mercy-reroll variant
-- fits this exact same contract (it would just change what `validate`
-- returns as the next State), so it's additive work for whenever this
-- task's difficulty curve actually gets tuned, not a blocker on P2-5's
-- own job of proving the contract.

local Types = require(script.Parent.Types)

type Challenge = {
	code: { number }, -- sent to the client to FLASH - see Types.luau's own header comment for why this isn't "leaking the answer"
	displaySeconds: number,
}

type State = {
	code: { number }, -- kept server-side only; never re-sent after start()
	nextIndex: number, -- 1-based index into `code` of the next digit expected
}

type Submission = {
	digit: number, -- 0-9, one per KeypadDigitSubmit remote call
}

local CODE_LENGTH = 4
local DISPLAY_SECONDS = 3

local function start(ctx: Types.TaskContext): (Challenge, State)
	local code = {}
	for _ = 1, CODE_LENGTH do
		table.insert(code, ctx.rng:NextInteger(0, 9))
	end

	local challenge: Challenge = { code = code, displaySeconds = DISPLAY_SECONDS }
	local state: State = { code = code, nextIndex = 1 }
	return challenge, state
end

local function validate(_ctx: Types.TaskContext, state: State, submission: Submission): (boolean, State)
	local expectedDigit = state.code[state.nextIndex]

	if submission.digit ~= expectedDigit then
		-- Wrong digit: restart progress on the SAME rolled code (this
		-- file's header comment covers the catalogue's fuller mercy-
		-- reroll rule, not implemented here). Never reveals which digit
		-- was expected - the boolean is the only signal that crosses back.
		return false, { code = state.code, nextIndex = 1 }
	end

	local nextIndex = state.nextIndex + 1
	if nextIndex > #state.code then
		return true, state -- every digit entered correctly, in order - done
	end

	return false, { code = state.code, nextIndex = nextIndex }
end

local function cleanup(_ctx: Types.TaskContext, _state: State)
	-- Nothing to release: no Instance was created, no external resource
	-- held. Present (rather than omitted) so this handler still
	-- satisfies the contract literally, and so a reader sees at a glance
	-- this is a deliberate no-op, not an oversight.
end

local CodePlayback: Types.TaskHandler<Challenge, State, Submission> = {
	taskId = "code-playback",
	start = start,
	validate = validate,
	cleanup = cleanup,
}

return CodePlayback
