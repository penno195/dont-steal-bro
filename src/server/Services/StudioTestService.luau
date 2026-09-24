--!strict
-- Studio test mode: press Play and a round runs on a real map, with no
-- command-bar steps. Does nothing outside Studio, or when
-- GameConfig.studioTest.enabled is false.
--
-- On start it waits for `minHumans` players to finish loading their
-- data, waits `startDelaySeconds` more so a second test client can join,
-- then:
--   1. Uses workspace's model named `mapId` if one is already there (so
--      edits made during a test session are what gets played), otherwise
--      clones it from ServerStorage.Maps.
--   2. Hands the map to the services that take one through their
--      Studio-only loaders: TaskService stations, NPCService nav nodes
--      and spawns, PowerUpService spawns. If a MapDef shares the map's
--      id, its NPC difficulty and rarity weights apply too - enabled or
--      not, so an unreleased map can be tested.
--   3. Requests Loading. Humans are moved to spawn points 1..n; NPCService
--      already seats bots from n+1 up, so the two never share a pad.
--
-- This is the missing map loader's Studio stand-in, not the real thing:
-- it never picks a map by vote, and one round per session is all
-- RoundService allows (Cleanup is terminal). Stop and Play for another.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Maps = require(ReplicatedStorage.Shared.Config.Maps)

local POLL_SECONDS = 0.5
local SPAWN_HEIGHT = Vector3.new(0, 4, 0) -- matches NPCService.chooseSpawnCFrame

local config = GameConfig.studioTest
local spawnPoints: { BasePart } = {}

local function findMap(mapId: string): Instance?
	local existing = Workspace:FindFirstChild(mapId)
	if existing ~= nil then
		print(string.format("StudioTestService: using workspace.%s as it stands", mapId))
		return existing
	end

	local mapsFolder = ServerStorage:FindFirstChild("Maps")
	local source = if mapsFolder ~= nil then mapsFolder:FindFirstChild(mapId) else nil
	if source == nil then
		return nil
	end
	local map = source:Clone()
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
			return
		end
	end
end

local function loadedHumans(): number
	local DataService = Loader.get("DataService") :: any
	local count = 0
	for _, player in Players:GetPlayers() do
		if DataService.isLoaded(player) then
			count += 1
		end
	end
	return count
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
		local character = player.Character
		if character ~= nil then
			local point = spawnPoints[((index - 1) % #spawnPoints) + 1]
			character:PivotTo(point.CFrame + SPAWN_HEIGHT)
		end
	end
end

local function run()
	while loadedHumans() < config.minHumans do
		task.wait(POLL_SECONDS)
	end
	task.wait(config.startDelaySeconds)

	local map = findMap(config.mapId)
	if map == nil then
		warn(
			string.format(
				"StudioTestService: no model named %q in ServerStorage.Maps - build it (scripts/build-graybox.luau for GrayBoxTest) or change GameConfig.studioTest.mapId",
				config.mapId
			)
		)
		return
	end

	local TaskService = Loader.get("TaskService") :: any
	local NPCService = Loader.get("NPCService") :: any
	local PowerUpService = Loader.get("PowerUpService") :: any
	TaskService.debugLoadStationsFromMap(map)
	NPCService.debugLoadFromMap(map)
	PowerUpService.debugLoadSpawnPointsFromMap(map)
	spawnPoints = collectSpawnPoints(map)
	NPCService.setSpawnPoints(spawnPoints)
	applyMapDef(config.mapId)

	-- This service's own wait above is the arrival grace; NPCs waiting
	-- out theirs as well would spawn after Race had already begun.
	NPCService.markArrivalGraceServed()

	local RoundService = Loader.get("RoundService") :: any
	print(string.format("StudioTestService: starting a round on %s with %d human(s)", map.Name, #Players:GetPlayers()))
	RoundService.requestTransition("Loading")
end

local StudioTestService: Loader.Service = {
	name = "StudioTestService",
	dependencies = { "ConfigValidator", "DataService", "RoundService", "TaskService", "NPCService", "PowerUpService" },
}

function StudioTestService:init()
	if not (RunService:IsStudio() and config.enabled) then
		return
	end
	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Loading", placeHumans)
end

function StudioTestService:start()
	if not (RunService:IsStudio() and config.enabled) then
		return
	end
	task.spawn(run)
end

return StudioTestService
