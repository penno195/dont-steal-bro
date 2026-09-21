--!strict
-- tasks-catalogue.md #7, `fuse-rewire` - P2-6's Drag reference task:
-- "drag replacement fuses into a blown panel in the right slots." Matches
-- the reference keypad task's structure/naming/comment style exactly
-- (CodePlayback.luau); the only new shape here is Drag's own mechanic -
-- a server-rolled fuse->slot mapping instead of a sequence, checked one
-- (fuseId, slotId) drop at a time.
--
-- "The client's drag is purely a UI convenience - the actual 'drop'
-- intent sent to the server is a (cableId, socketId) pair the server
-- checks against its own private mapping, so reading the client's UI
-- state doesn't reveal the right answer" (tasks-catalogue.md's own
-- words, about Cable Splice, reused verbatim here - Fuse Rewire is
-- explicitly the same validation pattern). Challenge below sends the
-- fuse/slot IDS to render, never the mapping between them.
--
-- SIMPLIFICATION, NOTED HONESTLY (same stance CodePlayback.luau and
-- PressureValve.luau take on their own gaps): tasks-catalogue.md adds "a
-- full time-out resets the whole panel." This handler doesn't implement
-- a live timeout - see PressureValve.luau's own header comment for why
-- that's a client-polish/tuning gap (a live ticking reset) rather than a
-- framework one; a wrong drop already "bounces back... with no penalty"
-- exactly as specified, which is the validation-relevant half of the
-- rule.

local Types = require(script.Parent.Types)

local SLOT_COUNT = 4 -- tasks-catalogue.md: "fewer, larger drop targets than Lock Tumbler" (which uses 3-4)

type Challenge = {
	fuseIds: { string },
	slotIds: { string },
}

type State = {
	mapping: { [string]: string }, -- fuseId -> correct slotId, rolled once at start()
	filledSlots: { [string]: boolean },
	remainingCount: number,
}

type Submission = {
	fuseId: string,
	slotId: string,
}

-- Fisher-Yates over a shallow copy, same algorithm as TaskAssignment.
-- luau's own shuffledCopy - duplicated rather than shared, since that
-- module's version is built around its own hand-rolled seeded float
-- generator (needed to stay Lune-pure) while this one uses ctx.rng, a
-- real Random instance this Roblox-only file has no reason to avoid
-- (see CodePlayback.luau's identical note on Random vs the LCG).
local function shuffledCopy(list: { string }, rng: Random): { string }
	local copy = table.clone(list)
	for i = #copy, 2, -1 do
		local j = rng:NextInteger(1, i)
		copy[i], copy[j] = copy[j], copy[i]
	end
	return copy
end

local function start(ctx: Types.TaskContext): (Challenge, State)
	local fuseIds = {}
	local slotIds = {}
	for i = 1, SLOT_COUNT do
		table.insert(fuseIds, string.format("fuse-%d", i))
		table.insert(slotIds, string.format("slot-%d", i))
	end

	-- The correct mapping is a random 1:1 pairing, independent of the
	-- ids' own numbering - "not a fixed puzzle" (tasks-catalogue.md).
	local shuffledSlotIds = shuffledCopy(slotIds, ctx.rng)
	local mapping: { [string]: string } = {}
	for index, fuseId in fuseIds do
		mapping[fuseId] = shuffledSlotIds[index]
	end

	local challenge: Challenge = { fuseIds = fuseIds, slotIds = slotIds }
	local state: State = { mapping = mapping, filledSlots = {}, remainingCount = SLOT_COUNT }
	return challenge, state
end

local function validate(_ctx: Types.TaskContext, state: State, submission: Submission): (boolean, State)
	local expectedSlotId = state.mapping[submission.fuseId]

	if expectedSlotId == nil or expectedSlotId ~= submission.slotId or state.filledSlots[submission.slotId] then
		-- Wrong slot (or a slot already locked in, re-sent) - "bounces
		-- back to the tray with no penalty" - nothing about `state`
		-- changes. Never reveals which slot WAS expected.
		return false, state
	end

	state.filledSlots[submission.slotId] = true
	state.remainingCount -= 1

	return state.remainingCount <= 0, state
end

local function cleanup(_ctx: Types.TaskContext, _state: State)
	-- Nothing to release - see CodePlayback.luau's identical no-op for
	-- why this is present rather than omitted.
end

local FuseRewire: Types.TaskHandler<Challenge, State, Submission> = {
	taskId = "fuse-rewire",
	start = start,
	validate = validate,
	cleanup = cleanup,
}

return FuseRewire
