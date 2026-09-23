--!strict
-- Task assignment, progress and qualification (P2-4). Owns "who has to
-- visit which stations this round," "how far has each player gotten,"
-- and "who qualifies for the Decision Studio" - the pure ranking and
-- assignment math live in TaskAssignment.luau and Qualification.luau
-- (src/shared/), this is the thin Roblox-touching wrapper that supplies
-- them real input (players, a seed, a station pool) and applies/
-- replicates their output. See those two files for the actual rules.
--
-- SCOPE: this does NOT validate a task submission - that's the
-- TaskHandler framework P2-5 builds. `TaskService.recordCompletion(
-- player, stationId)` is the seam a future validated TaskHandler calls
-- into once IT has decided a completion is legitimate (right station,
-- right range, minimum plausible time, not already done). Nothing here
-- ever trusts a raw client remote for "I finished" - Ground Rule 1.
--
-- WHO IS IN A RACE (P3-5): this service's per-racer state is keyed on a
-- PARTICIPANT ID, not on a Player instance, and its roster comes from
-- Participants.luau rather than Players:GetPlayers(). That is what lets
-- an NPC report a completion "through the exact same TaskService API a
-- human uses, so qualification logic has no NPC branch anywhere"
-- (architecture.md §4) - there is no NPC path through this file at all,
-- only racers with ids. The Player-shaped public methods below are thin
-- wrappers that look up `player.UserId` and call the id-shaped one, so
-- P2-5's TaskHandlerService and P3-2's DecisionService are unchanged.
--
-- WHERE THE STATION POOL COMES FROM: no map-loading service exists yet
-- (maps are hand-built in Studio and never synced by Rojo - CLAUDE.md -
-- and no MapDef has been registered in src/shared/Config/Maps yet
-- either). Rather than reach into ServerStorage.Maps itself and invent
-- that missing piece's scope here, TaskService takes the pool through an
-- injection point (`setStations`), the same shape RoundService used for
-- NetGuard.setRoundStateProvider - whatever loads a map in the future
-- just has to call it once. `debugLoadStationsFromMap` is a Studio-only
-- convenience that fills it in today by scanning a map's own
-- CollectionService tags (works right now against P2-3's GrayBoxTest).

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Packages.Signal)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local TaskAssignment = require(ReplicatedStorage.Shared.TaskAssignment)
local Qualification = require(ReplicatedStorage.Shared.Qualification)
local Participants = require(ServerScriptService.Server.Participants)

-- A station as this service knows it: TaskAssignment.luau's own
-- StationInfo (id + accepted task ids) plus the live Instance needed for
-- a distance-to-next-station reading. The pure modules never see `part`
-- - only this file does.
export type StationRecord = {
	stationId: string,
	acceptedTaskIds: { string },
	part: BasePart,
}

type RacerRoundState = {
	assignments: { TaskAssignment.StationAssignment },
	completed: { [string]: boolean },
	tasksCompleted: number,
	lastCompletionTime: number?,
}

-- capacityPerStation is computed as the bare theoretical minimum
-- (ceil(demand / pool size)) plus this much headroom. TaskAssignment.
-- assign's own doc comment covers why: confirmed locally that a
-- non-backtracking dealing algorithm at the exact minimum fails on a
-- real fraction of seeds (roughly 1 in 4, in a 5000-seed stress run
-- against a 12-station/6-player/6-task layout) - +1 headroom brought
-- that to 0/5000.
local CAPACITY_HEADROOM = 1

local stationPool: { TaskAssignment.StationInfo } = {}
local stationParts: { [string]: BasePart } = {}
local stationOccupancy: { [string]: number } = {}

local racerStates: { [number]: RacerRoundState } = {}
local finishOrder: { number } = {}
local qualificationEmitted = false
local nextSeedOverride: number? = nil
local lastQualificationResult: Qualification.QualificationResult? = nil

-- Fired on every accepted completion, human or NPC, with whatever the
-- caller knew about how long it took (nil when nothing measured it).
-- P3-5's NPCService listens for the human ones to keep a running median
-- per task - the number its own fairness floor is measured against.
-- Created at module load, not in init(), for the reason RoundService.
-- luau's header gives: subscribing must be safe from any other
-- service's init(), whatever order they happen to run in.
local completed = Signal.new()

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- Injection point for whatever loads a map - see this file's header
-- comment. Replaces the pool outright each call (a fresh map load, not
-- an incremental add).
local function setStations(stations: { StationRecord })
	stationPool = {}
	stationParts = {}
	for _, station in stations do
		table.insert(stationPool, { stationId = station.stationId, acceptedTaskIds = station.acceptedTaskIds })
		stationParts[station.stationId] = station.part
	end
end

-- Studio-only convenience: scans CollectionService's real "TaskStation"
-- tag under `mapRoot` (e.g. the ServerStorage.Maps.GrayBoxTest model
-- P2-3's builder script produces) and calls setStations for you, reading
-- map-kit-spec.md's own StationId/AcceptedTaskIds attributes. Skips (and
-- warns about) a station missing either attribute rather than failing
-- the whole load - useful for iterating on a half-tagged map in Studio.
local function debugLoadStationsFromMap(mapRoot: Instance)
	local stations: { StationRecord } = {}

	for _, instance in CollectionService:GetTagged("TaskStation") do
		if not (instance:IsDescendantOf(mapRoot) and instance:IsA("BasePart")) then
			continue
		end

		local stationId = instance:GetAttribute("StationId") :: string?
		local acceptedTaskIdsRaw = instance:GetAttribute("AcceptedTaskIds") :: string?
		if stationId == nil or acceptedTaskIdsRaw == nil or acceptedTaskIdsRaw == "" then
			warn(
				string.format("TaskService: %s is missing StationId/AcceptedTaskIds - skipped", instance:GetFullName())
			)
			continue
		end

		table.insert(stations, {
			stationId = stationId,
			acceptedTaskIds = string.split(acceptedTaskIdsRaw, ","),
			part = instance,
		})
	end

	setStations(stations)
	print(string.format("TaskService: loaded %d station(s) from %s", #stations, mapRoot:GetFullName()))
end

-- Forces the seed the NEXT beginRace() uses, instead of deriving one from
-- the clock - "reproducible for debugging," the task's own requirement,
-- needs a way to pick a known seed to replay. Consumed once, then
-- cleared, so it never silently pins every future round too.
local function debugSetNextSeed(seed: number)
	nextSeedOverride = seed
end

local function capacityForRoster(playerCount: number): number
	if #stationPool == 0 then
		return 0
	end
	return math.ceil((playerCount * GameConfig.tasksPerPlayer) / #stationPool) + CAPACITY_HEADROOM
end

-- The payload field is still called `playerId` (the client contract
-- predates NPCs and there is no reason to churn it): an NPC simply
-- appears as a negative id, which Participants.luau guarantees can
-- never collide with a real UserId.
local function broadcastProgress()
	local progress = {}
	for racerId, state in racerStates do
		table.insert(progress, { playerId = racerId, tasksCompleted = state.tasksCompleted })
	end
	Net.fireAllClients("TaskProgress", { progress = progress })
end

-- P6-3: one racer's own route, to that racer only (see Net.luau's
-- TaskAssignmentState for why this is never broadcast). An NPC has no
-- HUD, so it returns early for one, like PowerUpService's inventory.
local function sendAssignment(racerId: number)
	local state = racerStates[racerId]
	local participant = Participants.get(racerId)
	local player = if participant ~= nil then participant.player else nil
	if state == nil or player == nil then
		return
	end

	local route = {}
	for _, assignment in state.assignments do
		table.insert(route, {
			stationId = assignment.stationId,
			taskId = assignment.taskId,
			completed = state.completed[assignment.stationId] == true,
		})
	end
	Net.fireClient("TaskAssignmentState", player, { assignments = route })
end

-- The first not-yet-completed station in a player's own assigned order -
-- "their next station," for the distance tie-break. nil once they've
-- completed everything (nothing left to travel to).
local function nextStationPartFor(state: RacerRoundState): BasePart?
	for _, assignment in state.assignments do
		if not state.completed[assignment.stationId] then
			return stationParts[assignment.stationId]
		end
	end
	return nil
end

-- nil (not 0) when it can't actually be measured - no remaining station,
-- or the racer has no live Character right now (a human respawning or
-- just teleported; an NPC whose rig hasn't been parented yet).
-- Qualification.rank treats a nil distance as "best," which is the right
-- fail-safe here: a measurement gap should never rank someone worse than
-- they'd otherwise be.
local function distanceToNextStation(racerId: number, state: RacerRoundState): number?
	local targetPart = nextStationPartFor(state)
	if targetPart == nil then
		return nil
	end

	local participant = Participants.get(racerId)
	local character = if participant ~= nil then participant.character else nil
	if character == nil then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end

	return (root.Position - targetPart.Position).Magnitude
end

local function buildProgressEntries(): { Qualification.PlayerProgress }
	local entries: { Qualification.PlayerProgress } = {}
	for racerId, state in racerStates do
		table.insert(entries, {
			playerId = racerId,
			tasksAssigned = #state.assignments,
			tasksCompleted = state.tasksCompleted,
			lastCompletionTime = state.lastCompletionTime,
			distanceToNextStation = distanceToNextStation(racerId, state),
		})
	end
	return entries
end

-- Idempotent per round (guarded by `qualificationEmitted`) - safe to call
-- from both triggers (the 3rd finisher, and Qualified's own onEnter) even
-- though only one of them will ever actually do anything for a given
-- round.
local function emitQualification()
	if qualificationEmitted then
		return
	end

	local entries = buildProgressEntries()
	if #entries == 0 then
		warn("TaskService: no player progress to rank - skipping qualification (no station pool loaded this round?)")
		return
	end

	local result = Qualification.rank(entries, GameConfig.qualifierCount, GameConfig.qualificationFloorPercent)
	qualificationEmitted = true
	lastQualificationResult = result
	Net.fireAllClients("TaskQualificationResult", result)

	print(
		string.format(
			"TaskService: qualification decided - qualifiers [%s], alternate %s",
			table.concat(result.qualifiers, ", "),
			if result.alternate ~= nil then tostring(result.alternate) else "none"
		)
	)
end

local function beginRace()
	qualificationEmitted = false
	lastQualificationResult = nil
	finishOrder = {}
	racerStates = {}
	stationOccupancy = {}

	if #stationPool == 0 then
		warn("TaskService: no station pool set (no map loaded) - skipping task assignment for this race")
		return
	end

	-- Every racer on the roster, humans and NPCs alike, in one list -
	-- NPCService has already registered its bots by the time Race is
	-- entered (it spawns them during Loading, after its own fill grace
	-- window). TaskAssignment never learns which is which.
	local racerIds: { number } = {}
	for _, participant in Participants.all() do
		table.insert(racerIds, participant.id)
	end

	if #racerIds == 0 then
		return
	end

	local seed = nextSeedOverride or math.floor(now() * 1000)
	nextSeedOverride = nil

	local capacity = capacityForRoster(#racerIds)
	local assignmentsByRacerId = TaskAssignment.assign(seed, stationPool, racerIds, GameConfig.tasksPerPlayer, capacity)

	for racerId, assignments in assignmentsByRacerId do
		racerStates[racerId] = {
			assignments = assignments,
			completed = {},
			tasksCompleted = 0,
			lastCompletionTime = nil,
		}

		for _, assignment in assignments do
			stationOccupancy[assignment.stationId] = (stationOccupancy[assignment.stationId] or 0) + 1
		end
	end

	broadcastProgress()
	for racerId in racerStates do
		sendAssignment(racerId)
	end
	print(
		string.format(
			"TaskService: assigned tasks to %d racer(s) (%d human, %d NPC) - seed %d, capacity %d",
			#racerIds,
			Participants.countHumans(),
			Participants.countNPCs(),
			seed,
			capacity
		)
	)
end

-- Called by P2-5's validated TaskHandler for a human, and by P3-5's
-- NPCService for a bot that has finished "working" at a station - never
-- directly by a client remote (see this file's header comment). Returns
-- false (a normal no-op, not an error) for anything that isn't a
-- legitimate, not-yet-completed, actually-assigned station: no active
-- round for this racer, a double submit, or a station never on their
-- list.
--
-- `durationSeconds` is how long the racer actually spent on it, when the
-- caller measured it (TaskHandlerService has it from the challenge
-- session's own clock). Only used to feed NPCService's running human
-- median; nothing about qualification reads it.
local function recordCompletionFor(racerId: number, stationId: string, durationSeconds: number?): boolean
	local state = racerStates[racerId]
	if state == nil or state.completed[stationId] then
		return false
	end

	local taskId: string? = nil
	for _, assignment in state.assignments do
		if assignment.stationId == stationId then
			taskId = assignment.taskId
			break
		end
	end
	if taskId == nil then
		return false
	end

	state.completed[stationId] = true
	state.tasksCompleted += 1
	state.lastCompletionTime = now()
	stationOccupancy[stationId] = math.max(0, (stationOccupancy[stationId] or 0) - 1)

	broadcastProgress()
	sendAssignment(racerId)
	completed:Fire(racerId, stationId, taskId, durationSeconds)

	if state.tasksCompleted >= #state.assignments then
		table.insert(finishOrder, racerId)
		if #finishOrder >= GameConfig.qualifierCount and not qualificationEmitted then
			emitQualification()
			local RoundService = Loader.get("RoundService") :: any
			RoundService.requestTransition("Qualified")
		end
	end

	return true
end

-- The Player-shaped wrapper P2-5's TaskHandlerService already calls.
-- Kept so that file (and any future human-side caller) never has to
-- know participant ids exist.
local function recordCompletion(player: Player, stationId: string, durationSeconds: number?): boolean
	return recordCompletionFor(player.UserId, stationId, durationSeconds)
end

-- Frees every station still outstanding on a leaving player's route -
-- "free their stations," the task's own requirement - so
-- getStationOccupancy no longer counts a slot nobody will ever fill.
local function freeRemainingStations(state: RacerRoundState)
	for _, assignment in state.assignments do
		if not state.completed[assignment.stationId] then
			stationOccupancy[assignment.stationId] = math.max(0, (stationOccupancy[assignment.stationId] or 0) - 1)
		end
	end
end

-- "Recompute qualification without them" falls out for free: buildProgressEntries
-- only ever walks `racerStates`, so removing a leaver from it here means
-- any later Qualification.rank call (the 3rd-finisher trigger, or
-- Qualified's own onEnter) simply never sees them.
--
-- P3-5 note: this is reached for a human leaving (RoundService's
-- onPlayerLeaving) and for an NPC being despawned mid-race
-- (NPCService calls removeRacer directly) - the same cleanup either way.
local function removeRacer(racerId: number)
	local state = racerStates[racerId]
	if state == nil then
		return
	end

	freeRemainingStations(state)
	racerStates[racerId] = nil
	broadcastProgress()
end

local function handlePlayerLeaving(player: Player, state: string)
	if state ~= "Race" then
		return
	end
	removeRacer(player.UserId)
end

local TaskService: Loader.Service = {
	name = "TaskService",
	dependencies = { "NetGuard", "ConfigValidator", "RoundService", "ParticipantService" },

	setStations = setStations,
	debugLoadStationsFromMap = debugLoadStationsFromMap,
	debugSetNextSeed = debugSetNextSeed,
	recordCompletion = recordCompletion,

	-- P3-5's id-shaped surface. Everything below it that takes a Player
	-- is a wrapper over one of these.
	recordCompletionFor = recordCompletionFor,
	removeRacer = removeRacer,

	onCompletion = function(
		callback: (racerId: number, stationId: string, taskId: string, durationSeconds: number?) -> ()
	)
		return completed:Connect(callback)
	end,

	getAssignmentFor = function(racerId: number): { TaskAssignment.StationAssignment }?
		local state = racerStates[racerId]
		return if state then state.assignments else nil
	end,

	-- P3-6: the brain's "how far behind am I" reading. Same numbers
	-- getProgress gives for a Player, keyed by id so it answers for a
	-- bot too - which it has to, since a bot needs to know how it's
	-- doing against the whole field, itself included.
	getProgressFor = function(racerId: number): { tasksCompleted: number, tasksAssigned: number }?
		local state = racerStates[racerId]
		if state == nil then
			return nil
		end
		return { tasksCompleted = state.tasksCompleted, tasksAssigned = #state.assignments }
	end,

	getRacerIds = function(): { number }
		local ids: { number } = {}
		for racerId in racerStates do
			table.insert(ids, racerId)
		end
		table.sort(ids)
		return ids
	end,

	getTaskIdForRacer = function(racerId: number, stationId: string): string?
		local state = racerStates[racerId]
		if state == nil then
			return nil
		end
		for _, assignment in state.assignments do
			if assignment.stationId == stationId then
				return assignment.taskId
			end
		end
		return nil
	end,

	-- Which of a racer's assigned stations are still outstanding, in
	-- their own assigned order - NPCService's route, and the only thing
	-- it needs to know about the race it's in.
	getRemainingStations = function(racerId: number): { TaskAssignment.StationAssignment }
		local state = racerStates[racerId]
		if state == nil then
			return {}
		end
		local remaining: { TaskAssignment.StationAssignment } = {}
		for _, assignment in state.assignments do
			if not state.completed[assignment.stationId] then
				table.insert(remaining, assignment)
			end
		end
		return remaining
	end,

	getAssignment = function(player: Player): { TaskAssignment.StationAssignment }?
		local state = racerStates[player.UserId]
		return if state then state.assignments else nil
	end,

	getProgress = function(player: Player): { tasksCompleted: number, tasksAssigned: number }?
		local state = racerStates[player.UserId]
		if state == nil then
			return nil
		end
		return { tasksCompleted = state.tasksCompleted, tasksAssigned = #state.assignments }
	end,

	getStationOccupancy = function(stationId: string): number
		return stationOccupancy[stationId] or 0
	end,

	-- The three small read-only surfaces P2-5's TaskHandlerService needs
	-- to dispatch a live interaction: which station Instance a stationId
	-- actually is, which specific task id this PLAYER was assigned there
	-- (a station's AcceptedTaskIds can list more than one; TaskAssignment
	-- already picked exactly one per player at assignment time), and
	-- whether it's still legitimately theirs to attempt right now.
	getStationPart = function(stationId: string): BasePart?
		return stationParts[stationId]
	end,

	getTaskIdFor = function(player: Player, stationId: string): string?
		local state = racerStates[player.UserId]
		if state == nil then
			return nil
		end
		for _, assignment in state.assignments do
			if assignment.stationId == stationId then
				return assignment.taskId
			end
		end
		return nil
	end,

	-- Combines "on their list" and "not already complete" into the one
	-- check a dispatcher actually needs - "that the task is actually on
	-- their list and not already complete" (P2-5's own requirement,
	-- verbatim). recordCompletion re-checks both independently anyway
	-- (defense in depth - see its own comment), so this is a read-only
	-- convenience for a guard check BEFORE calling into a handler, not
	-- the actual enforcement point.
	isAssignedAndIncomplete = function(player: Player, stationId: string): boolean
		local state = racerStates[player.UserId]
		if state == nil or state.completed[stationId] then
			return false
		end
		for _, assignment in state.assignments do
			if assignment.stationId == stationId then
				return true
			end
		end
		return false
	end,

	-- P3-2: DecisionService's own starting point - the qualifiers/
	-- alternate this round actually resolved, exactly as broadcast via
	-- TaskQualificationResult. nil before qualification has been decided
	-- yet, or after a fresh beginRace() reset (Studio debug-replay
	-- safety, same reasoning as qualificationEmitted's own reset).
	getLastQualificationResult = function(): Qualification.QualificationResult?
		return lastQualificationResult
	end,
}

function TaskService:init()
	local RoundService = Loader.get("RoundService") :: any

	RoundService.onEnter("Race", function()
		beginRace()
	end)

	RoundService.onEnter("Qualified", function()
		emitQualification()
	end)

	RoundService.onPlayerLeaving(function(player: Player, state: string)
		handlePlayerLeaving(player, state)
	end)
end

return TaskService
