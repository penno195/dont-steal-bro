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
--      bots from n+1 up, so the two never share a pad. Humans stay
--      anchored there until Race, and anyone who respawns before the
--      Decision Studio goes back to their own pad.
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

-- Each human's pad, from Loading on. A respawn goes back to it rather
-- than to the place's own SpawnLocation (the Match place's ArrivalPad,
-- thousands of studs from the map).
local seats: { [Player]: BasePart } = {}
-- Root parts held still until Race. The client owns its character's
-- physics, so a character moved onto a map its client hasn't streamed
-- yet falls through the floor; on a live server RequestStreamAroundAsync
-- can time out before a dense map arrives, and the fall respawned
-- players on the ArrivalPad.
local held: { BasePart } = {}
local raceStarted = false

-- States in which a respawn belongs on the race map. From DecisionStudio
-- on, StudioStageService decides where people stand.
local ON_MAP: { [string]: boolean } = {
	Loading = true,
	Intro = true,
	Race = true,
	Qualified = true,
}

-- Feet on the pad's floor, not SPAWN_HEIGHT above it. A held root is
-- anchored, so it never falls the gap: its Humanoid sat in Freefall,
-- playing the falling animation, for the whole countdown. Pads are thin
-- non-colliding markers laid on the floor, so the floor is their bottom.
local function standingCFrame(point: BasePart, character: Model, root: BasePart): CFrame
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return point.CFrame + SPAWN_HEIGHT
	end
	local floorY = point.Position.Y - point.Size.Y / 2
	local standY = floorY + humanoid.HipHeight + root.Size.Y / 2
	local at = Vector3.new(point.Position.X, standY, point.Position.Z)
	return CFrame.new(at) * point.CFrame.Rotation
end

-- Yields on the stream, so callers run it in its own thread.
local function putOnSeat(player: Player, point: BasePart)
	MapStreaming.streamAround(player, point.Position)
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	if character == nil or root == nil then
		return
	end
	-- A mid-Race respawn is a server teleport MovementWatch would
	-- otherwise read as speed.
	(Loader.get("MovementWatch") :: any).suppressNextSample(player)
	if raceStarted then
		character:PivotTo(point.CFrame + SPAWN_HEIGHT)
		return
	end
	root.Anchored = true
	table.insert(held, root)
	character:PivotTo(standingCFrame(point, character, root))
	-- The avatar's appearance can load after this and rescale the legs;
	-- re-stand on the new HipHeight so a held racer neither floats nor
	-- sinks into the floor.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		local connection: RBXScriptConnection
		connection = humanoid:GetPropertyChangedSignal("HipHeight"):Connect(function()
			if raceStarted or not root.Anchored or root.Parent == nil then
				connection:Disconnect()
				return
			end
			character:PivotTo(standingCFrame(point, character, root))
		end)
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
		seats[player] = point
		-- One thread per player, because streamAround yields and no player
		-- should wait on another's stream.
		task.spawn(putOnSeat, player, point)
	end
end

-- Unanchoring puts the rig back on automatic network ownership, which
-- can hand it to whichever client is nearest - with six pads 6 studs
-- apart, often someone else's. That client ignores the owner's input
-- and doesn't run their Humanoid, so the rig slumps until its torso
-- (R15 legs don't collide) rests on the floor: stuck half under the
-- map. Give it straight back to its own player.
local function release(root: BasePart)
	root.Anchored = false
	local player = Players:GetPlayerFromCharacter(root.Parent)
	if player ~= nil then
		root:SetNetworkOwner(player)
	end
end

local function releaseHumans()
	raceStarted = true
	for _, root in held do
		if root.Parent ~= nil then
			release(root)
		end
	end
	table.clear(held)
end

local function onCharacterAdded(player: Player, character: Model)
	local point: BasePart? = seats[player]
	local RoundService = Loader.get("RoundService") :: any
	if point == nil or not ON_MAP[RoundService.getState()] then
		return
	end
	-- Let the default spawn finish building the character first.
	character:WaitForChild("HumanoidRootPart", 5)
	putOnSeat(player, point)
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
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
		"MovementWatch",
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
	RoundService.onEnter("Race", releaseHumans)
end

function MapLoaderService:start()
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		seats[player] = nil
	end)
end

return MapLoaderService
