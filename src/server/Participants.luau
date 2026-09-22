--!strict
-- The round's roster of racers, humans and NPCs alike (P3-5).
--
-- WHY THIS EXISTS: architecture.md §4 requires that an NPC "reports
-- completion through the same TaskService API a human uses - so
-- qualification logic has no NPC branch anywhere." Before this module,
-- every race-side service keyed its per-racer state on a `Player`
-- instance and read `player.Character` / `player.UserId` directly, so
-- "the same API" was literally impossible for something that isn't a
-- Player: an NPC would have needed a parallel path in TaskService,
-- PowerUpService and StatusEffects, which is exactly the branching the
-- architecture forbids.
--
-- What those services actually need from a racer is much smaller than a
-- Player: a stable numeric id, a live character Model to measure
-- distance from and apply Humanoid stats to, and (for humans only) a
-- Player to fire a targeted remote at. That is this table. Services key
-- their state on `id`, ask this registry for the character, and fire a
-- remote only `if participant.player ~= nil` - so an NPC takes the same
-- code path a human does and simply has no remote fired at it.
--
-- PURE BY CONSTRUCTION: zero Roblox API calls (Player/Model appear only
-- as type annotations on values this module stores and hands back but
-- never touches), so it is unit-testable headlessly - Ground Rule 4.
-- Population is ParticipantService's job; this is just the store.
--
-- NPC IDS ARE NEGATIVE, and that is a load-bearing guarantee, not a
-- convention: a real Roblox UserId is always a positive integer, so a
-- negative id cannot collide with one no matter how many NPCs a server
-- has spawned. Every id-keyed surface in the codebase (Qualification's
-- `playerId`, Outcomes' finalist ids, the TaskProgress/DecisionLockedIn
-- payloads) therefore keeps working unchanged - an NPC is just another
-- id to all of them.

local Participants = {}

export type Participant = {
	id: number,
	displayName: string,
	isNPC: boolean,
	-- nil for every NPC. The presence of this field is the ONLY thing
	-- that should ever branch on "is this a bot" in a consuming service,
	-- and only ever to answer "is there a client to send this to."
	player: Player?,
	-- The live rig. nil while a human is loading/respawning or before an
	-- NPC's model is parented - every consumer already has to handle a
	-- characterless racer (a respawning human), so an NPC mid-spawn is
	-- not a new case.
	character: Model?,
}

local byId: { [number]: Participant } = {}
-- Insertion order, so iteration is deterministic across a round rather
-- than following Luau's hash order - a rank/target scan that reorders
-- itself between calls is miserable to debug.
local order: { number } = {}
local nextNPCId = -1

local function indexOf(id: number): number?
	for index, existing in order do
		if existing == id then
			return index
		end
	end
	return nil
end

-- Hands out the next never-yet-used negative id. Monotonic for the life
-- of the server (never reused even after unregister) so a stale id held
-- by an in-flight callback can never be mistaken for a live NPC.
function Participants.allocateNPCId(): number
	local id = nextNPCId
	nextNPCId -= 1
	return id
end

function Participants.isNPCId(id: number): boolean
	return id < 0
end

function Participants.register(participant: Participant): Participant
	assert(
		byId[participant.id] == nil,
		string.format("Participants.register: id %d is already registered", participant.id)
	)
	assert(
		participant.isNPC == (participant.player == nil),
		string.format(
			"Participants.register: id %d has isNPC=%s but player=%s - a human must carry its Player and an NPC must not",
			participant.id,
			tostring(participant.isNPC),
			tostring(participant.player)
		)
	)

	byId[participant.id] = participant
	table.insert(order, participant.id)
	return participant
end

function Participants.unregister(id: number)
	if byId[id] == nil then
		return
	end
	byId[id] = nil
	local index = indexOf(id)
	if index ~= nil then
		table.remove(order, index)
	end
end

function Participants.get(id: number): Participant?
	return byId[id]
end

-- The registry's own `player -> participant` lookup. Every service that
-- still takes a `Player` at its public edge (a NetGuard handler, a
-- TaskHandler callback) crosses over to id-keyed state here.
function Participants.fromPlayer(player: Player): Participant?
	return byId[player.UserId]
end

function Participants.setCharacter(id: number, character: Model?)
	local participant = byId[id]
	if participant ~= nil then
		participant.character = character
	end
end

-- Always a fresh array in insertion order - safe for a caller to hold
-- across an unregister, and safe to iterate while mutating the registry.
function Participants.all(): { Participant }
	local result: { Participant } = {}
	for _, id in order do
		local participant = byId[id]
		if participant ~= nil then
			table.insert(result, participant)
		end
	end
	return result
end

function Participants.humans(): { Participant }
	local result: { Participant } = {}
	for _, participant in Participants.all() do
		if not participant.isNPC then
			table.insert(result, participant)
		end
	end
	return result
end

function Participants.npcs(): { Participant }
	local result: { Participant } = {}
	for _, participant in Participants.all() do
		if participant.isNPC then
			table.insert(result, participant)
		end
	end
	return result
end

function Participants.countHumans(): number
	return #Participants.humans()
end

function Participants.countNPCs(): number
	return #Participants.npcs()
end

-- Test-only: wipes the registry AND the id counter. Never call this in
-- production - an NPC id handed out before a reset could be handed out
-- again after one, which is the exact reuse `allocateNPCId` avoids.
function Participants.resetForTesting()
	byId = {}
	order = {}
	nextNPCId = -1
end

return Participants
