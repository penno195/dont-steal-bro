--!strict
-- Puts a race map into the round: the one loader both a live match
-- server (MatchTeleportService, once its arrival gate closes) and
-- Studio test mode (StudioTestService) go through.
--
-- load(mapId):
--   1. Uses workspace's model named `mapId` if one is already there (a
--      Studio test session playing its own edits), otherwise clones it
--      from ServerStorage.Maps. The clone gets MapStreaming.prepare
--      before it is parented (lighting-and-streaming.md §5).
--   2. Hands the map to the services that take one: TaskService
--      stations, NPCService nav nodes and spawns, PowerUpService spawns.
--      If a MapDef shares the map's id, its NPC difficulty, rarity
--      weights and lighting preset apply too - enabled or not, so an
--      unreleased map can be tested in Studio.
--   3. On Loading, moves humans to spawn points 1..n; NPCService seats
--      bots from n+1 up, so the two never share a pad.
--
-- The caller requests Loading itself, after load returns true. One map
-- per server: RoundService's Cleanup is terminal and the match server
-- sends everyone home, so nothing ever unloads a map.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Maps = require(ReplicatedStorage.Shared.Config.Maps)
local MapStreaming = require(ServerScriptService.Server.MapStreaming)

local SPAWN_HEIGHT = Vector3.new(0, 4, 0) -- matches NPCService.chooseSpawnCFrame

local spawnPoints: { BasePart } = {}

local function findMap(mapId: string): Instance?
	local existing = Workspace:FindFirstChild(mapId)
	if existing ~= nil then
		print(string.format("MapLoaderService: using workspace.%s as it stands", mapId))
		-- Already parented, so clients may briefly see default streaming
		-- modes. Only a Studio test session leaves a map in workspace.
		MapStreaming.prepare(existing)
		return existing
	end

	local mapsFolder = ServerStorage:FindFirstChild("Maps")
	local source = if mapsFolder ~= nil then mapsFolder:FindFirstChild(mapId) else nil
	if source == nil then
		return nil
	end
	local map = source:Clone()
	MapStreaming.prepare(map)
	map.Parent = Workspace
	return map
end

-- CollectionService gives no order guarantee, and humans and NPCService
-- must agree on which pad is seat 1, so both read this one sorted list.
local function collectSpawnPoints(map: Instance): { BasePart }
	local points: { BasePart } = {}
	for _, instance in CollectionService:GetTagged("SpawnPoint") do
		if instance:IsDescendantOf(map) and instance:IsA("BasePart") then
			table.insert(points, instance)
		end
	end
	table.sort(points, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return points
end

local function applyMapDef(mapId: string)
	for _, entry in Maps do
		if entry.def.id == mapId then
			local NPCService = Loader.get("NPCService") :: any
			local PowerUpService = Loader.get("PowerUpService") :: any
			NPCService.setMapDifficultyModifier(entry.def.npcDifficultyModifier)
			PowerUpService.setMapRarityWeights(entry.def.powerUpRarityWeightMultipliers)
			-- LightingService restores the place's lighting on Cleanup.
			local LightingService = Loader.get("LightingService") :: any
			LightingService.apply(entry.def.lightingPreset)
			return
		end
	end
end

local function placeHumans()
	if #spawnPoints == 0 then
		return
	end
	local humans = Players:GetPlayers()
	table.sort(humans, function(a, b)
		return a.UserId < b.UserId
	end)
	for index, player in humans do
		local point = spawnPoints[((index - 1) % #spawnPoints) + 1]
		-- One thread per player, because streamAround yields and no player
		-- should wait on another's stream.
		task.spawn(function()
			MapStreaming.streamAround(player, point.Position)
			local character = player.Character
			if character ~= nil then
				character:PivotTo(point.CFrame + SPAWN_HEIGHT)
			end
		end)
	end
end

-- False when ServerStorage.Maps has no such model; the caller decides
-- whether a round still runs.
local function load(mapId: string): boolean
	local map = findMap(mapId)
	if map == nil then
		warn(string.format("MapLoaderService: no model named %q in ServerStorage.Maps", mapId))
		return false
	end

	local TaskService = Loader.get("TaskService") :: any
	local NPCService = Loader.get("NPCService") :: any
	local PowerUpService = Loader.get("PowerUpService") :: any
	TaskService.debugLoadStationsFromMap(map)
	NPCService.debugLoadFromMap(map)
	PowerUpService.debugLoadSpawnPointsFromMap(map)
	spawnPoints = collectSpawnPoints(map)
	NPCService.setSpawnPoints(spawnPoints)
	applyMapDef(mapId)
	print(string.format("MapLoaderService: loaded %s (%d spawn points)", map.Name, #spawnPoints))
	return true
end

local MapLoaderService: Loader.Service = {
	name = "MapLoaderService",
	dependencies = {
		"RoundService",
		"TaskService",
		"NPCService",
		"PowerUpService",
		"LightingService",
	},
	load = load,
}

function MapLoaderService:init()
	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Loading", placeHumans)
end

return MapLoaderService
