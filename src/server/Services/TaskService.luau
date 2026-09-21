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

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local TaskAssignment = require(ReplicatedStorage.Shared.TaskAssignment)
local Qualification = require(ReplicatedStorage.Shared.Qualification)

-- A station as this service knows it: TaskAssignment.luau's own
-- StationInfo (id + accepted task ids) plus the live Instance needed for
-- a distance-to-next-station reading. The pure modules never see `part`
-- - only this file does.
export type StationRecord = {
	stationId: string,
	acceptedTaskIds: { string },
	part: BasePart,
}

type PlayerRoundState = {
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

local playerStates: { [Player]: PlayerRoundState } = {}
local finishOrder: { Player } = {}
local qualificationEmitted = false
local nextSeedOverride: number? = nil

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

local function broadcastProgress()
	local progress = {}
	for player, state in playerStates do
		table.insert(progress, { playerId = player.UserId, tasksCompleted = state.tasksCompleted })
	end
	Net.fireAllClients("TaskProgress", { progress = progress })
end

-- The first not-yet-completed station in a player's own assigned order -
-- "their next station," for the distance tie-break. nil once they've
-- completed everything (nothing left to travel to).
local function nextStationPartFor(state: PlayerRoundState): BasePart?
	for _, assignment in state.assignments do
		if not state.completed[assignment.stationId] then
			return stationParts[assignment.stationId]
		end
	end
	return nil
end

-- nil (not 0) when it can't actually be measured - no remaining station,
-- or the player has no live Character right now (respawning, just
-- teleported, etc). Qualification.rank treats a nil distance as "best,"
-- which is the right fail-safe here: a measurement gap should never rank
-- someone worse than they'd otherwise be.
local function distanceToNextStation(player: Player, state: PlayerRoundState): number?
	local targetPart = nextStationPartFor(state)
	if targetPart == nil then
		return nil
	end

	local character = player.Character
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
	for player, state in playerStates do
		table.insert(entries, {
			playerId = player.UserId,
			tasksAssigned = #state.assignments,
			tasksCompleted = state.tasksCompleted,
			lastCompletionTime = state.lastCompletionTime,
			distanceToNextStation = distanceToNextStation(player, state),
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
	finishOrder = {}
	playerStates = {}
	stationOccupancy = {}

	if #stationPool == 0 then
		warn("TaskService: no station pool set (no map loaded) - skipping task assignment for this race")
		return
	end

	local players = Players:GetPlayers()
	local playerIds: { number } = {}
	local byId: { [number]: Player? } = {}
	for _, player in players do
		table.insert(playerIds, player.UserId)
		byId[player.UserId] = player
	end

	if #playerIds == 0 then
		return
	end

	local seed = nextSeedOverride or math.floor(now() * 1000)
	nextSeedOverride = nil

	local capacity = capacityForRoster(#playerIds)
	local assignmentsByPlayerId =
		TaskAssignment.assign(seed, stationPool, playerIds, GameConfig.tasksPerPlayer, capacity)

	for playerId, assignments in assignmentsByPlayerId do
		local player = byId[playerId]
		if player == nil then
			continue
		end

		playerStates[player] = {
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
	print(
		string.format("TaskService: assigned tasks to %d player(s) - seed %d, capacity %d", #playerIds, seed, capacity)
	)
end

-- Called by a future validated TaskHandler (P2-5), never directly by a
-- client remote - see this file's header comment. Returns false (a
-- normal no-op, not an error) for anything that isn't a legitimate,
-- not-yet-completed, actually-assigned station: no active round for this
-- player, a double submit, or a station never on their list.
local function recordCompletion(player: Player, stationId: string): boolean
	local state = playerStates[player]
	if state == nil or state.completed[stationId] then
		return false
	end

	local isAssigned = false
	for _, assignment in state.assignments do
		if assignment.stationId == stationId then
			isAssigned = true
			break
		end
	end
	if not isAssigned then
		return false
	end

	state.completed[stationId] = true
	state.tasksCompleted += 1
	state.lastCompletionTime = now()
	stationOccupancy[stationId] = math.max(0, (stationOccupancy[stationId] or 0) - 1)

	broadcastProgress()

	if state.tasksCompleted >= #state.assignments then
		table.insert(finishOrder, player)
		if #finishOrder >= GameConfig.qualifierCount and not qualificationEmitted then
			emitQualification()
			local RoundService = Loader.get("RoundService") :: any
			RoundService.requestTransition("Qualified")
		end
	end

	return true
end

-- Frees every station still outstanding on a leaving player's route -
-- "free their stations," the task's own requirement - so
-- getStationOccupancy no longer counts a slot nobody will ever fill.
local function freeRemainingStations(state: PlayerRoundState)
	for _, assignment in state.assignments do
		if not state.completed[assignment.stationId] then
			stationOccupancy[assignment.stationId] = math.max(0, (stationOccupancy[assignment.stationId] or 0) - 1)
		end
	end
end

-- "Recompute qualification without them" falls out for free: buildProgressEntries
-- only ever walks `playerStates`, so removing a leaver from it here means
-- any later Qualification.rank call (the 3rd-finisher trigger, or
-- Qualified's own onEnter) simply never sees them.
local function handlePlayerLeaving(player: Player, state: string)
	if state ~= "Race" then
		return
	end

	local playerState = playerStates[player]
	if playerState == nil then
		return
	end

	freeRemainingStations(playerState)
	playerStates[player] = nil
	broadcastProgress()
end

local TaskService: Loader.Service = {
	name = "TaskService",
	dependencies = { "NetGuard", "ConfigValidator", "RoundService" },

	setStations = setStations,
	debugLoadStationsFromMap = debugLoadStationsFromMap,
	debugSetNextSeed = debugSetNextSeed,
	recordCompletion = recordCompletion,

	getAssignment = function(player: Player): { TaskAssignment.StationAssignment }?
		local state = playerStates[player]
		return if state then state.assignments else nil
	end,

	getProgress = function(player: Player): { tasksCompleted: number, tasksAssigned: number }?
		local state = playerStates[player]
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
		local state = playerStates[player]
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
		local state = playerStates[player]
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
