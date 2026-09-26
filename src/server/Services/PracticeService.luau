--!strict
-- The hub practice area (P5-5): waiting players pick up the real items
-- and use them on each other. This file contains NO power-up or effect
-- logic. It switches EffectContext into practice mode, which makes the
-- real PowerUpService and StatusEffects run with shorter effects and a
-- lower cap (see EffectContext.luau for why it isn't a copy). Then it
-- spawns pickups in the practice area and clears people who get matched.
--
-- WHAT KEEPS PRACTICE CONTAINED
--
--   The hub itself. Items spawn in HubPracticeArea but, once held, work
--   anywhere in the hub: there is no queue pad to protect, since joining
--   the queue is a UI button. EffectContext.mayAct only refuses a player
--   with no character or one a match has claimed (below).
--
--   Match found. From the moment a group claims a player (their ticket
--   is Departing), they are out of practice wherever they stand.
--   MatchTeleportService also calls `release` when the group departs,
--   so a frozen player is thawed then and there. Nothing needs to thaw
--   them for travel anyway: TeleportAsync doesn't care about WalkSpeed.
--
--   The match server. Practice state is plain memory on the hub server,
--   and a teleport carries only TeleportLogic's hint. The match server
--   boots in Round mode (it has no Workspace.Hub, and isn't the hub
--   place), and PowerUpService.beginRace asserts Round mode. A new
--   character also starts with every effect cleared (StatusEffects).
--
-- WHAT PRACTICE NEVER WRITES: progression, stats or analytics. Nothing in
-- the power-up path writes progression, and Telemetry.powerUpUsed and
-- PowerUpService's audit both check EffectContext.recordsStats().
-- MovementWatch exempts practising players (EffectContext.inPracticeArea).
--
-- STUDIO: with matchmaking.hubPlaceId unset, this runs in Studio when
-- Workspace.Hub has a practice area, like MatchmakingService does. Don't
-- force a round in that place: beginRace's assertion will stop it.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Participants = require(ServerScriptService.Server.Participants)
local EffectContext = require(ServerScriptService.Server.EffectContext)

local config = GameConfig.practice

local active = false

local function rootPosition(participant: Participants.Participant): Vector3?
	local character = participant.character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- EffectContext's gate. Read live on every check, never cached. Practice
-- works anywhere in the hub, so the only questions are "is there a live
-- character" and "has a match claimed them".
local function gate(id: number): boolean
	local participant = Participants.get(id)
	if participant == nil or not active then
		return false
	end

	local player = participant.player
	if player ~= nil and (Loader.get("MatchmakingService") :: any).isDeparting(player) then
		return false
	end

	return rootPosition(participant) ~= nil
end

-- Drops every effect and held item. Idempotent and cheap on someone who
-- has nothing, so callers never need to check first.
local function clear(id: number)
	local StatusEffects = Loader.get("StatusEffects") :: any
	if #StatusEffects.getActiveEffectsFor(id) > 0 then
		StatusEffects.clearFor(id)
	end
	local PowerUpService = Loader.get("PowerUpService") :: any
	PowerUpService.clearInventoryFor(id)
end

-- MatchTeleportService calls this as a group leaves the hub. No-op on
-- a server where practice isn't running.
local function release(players: { Player })
	if not active then
		return
	end
	for _, player in players do
		clear(player.UserId)
	end
end

-- Stateless on purpose: anyone outside the gate who still has an effect
-- or an item gets cleared, which in practice means they got matched.
local function checkZones()
	for _, participant in Participants.all() do
		if not gate(participant.id) then
			clear(participant.id)
		end
	end
end

local function findOne(tag: string): BasePart?
	local hub = Workspace:FindFirstChild("Hub")
	if hub == nil then
		return nil
	end
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(hub) then
			return instance
		end
	end
	return nil
end

local function itemSpawnPoints(): { any }
	local hub = Workspace:FindFirstChild("Hub") :: Instance
	local parts: { BasePart } = {}
	for _, instance in CollectionService:GetTagged("HubPracticeItemSpawn") do
		if instance:IsA("BasePart") and instance:IsDescendantOf(hub) then
			table.insert(parts, instance)
		end
	end
	table.sort(parts, function(a, b)
		return a.Name < b.Name
	end)

	local points = {}
	for i, part in parts do
		local rarity = config.itemSpawnRarities[(i - 1) % #config.itemSpawnRarities + 1]
		table.insert(points, { part = part, rarity = rarity, allowedPowerUpIds = nil })
	end
	return points
end

local function isHubServer(): boolean
	local hubPlaceId = GameConfig.matchmaking.hubPlaceId
	if hubPlaceId == 0 then
		return RunService:IsStudio()
	end
	return game.PlaceId == hubPlaceId
end

local PracticeService: Loader.Service = {
	name = "PracticeService",
	dependencies = { "ConfigValidator", "ParticipantService", "PowerUpService", "StatusEffects", "MatchmakingService" },

	release = release,
	isActive = function(): boolean
		return active
	end,
}

function PracticeService:init()
	if not isHubServer() then
		return
	end
	-- The area only marks where pickups spawn; it no longer bounds use.
	if findOne("HubPracticeArea") == nil then
		warn("PracticeService: no HubPracticeArea under Workspace.Hub - practice is off on this server")
		return
	end

	-- In init, not start: every service's start runs with the mode
	-- already decided, so nothing ever sees this server in Round mode.
	EffectContext.enterPractice({
		durationScale = config.durationScale,
		maxEffectSeconds = config.maxEffectSeconds,
		maxActiveEffects = config.maxActiveEffects,
	}, gate)
	active = true
end

function PracticeService:start()
	if not active then
		return
	end

	local PowerUpService = Loader.get("PowerUpService") :: any
	PowerUpService.setSpawnPoints(itemSpawnPoints())
	PowerUpService.setMapRarityWeights(config.respawnMultipliers)
	PowerUpService.startPickups()

	-- No PlayerRemoving handler: PowerUpService and StatusEffects already
	-- drop a leaver's state, and clearing here would recreate it.
	task.spawn(function()
		while true do
			task.wait(config.zoneCheckSeconds)
			checkZones()
		end
	end)
end

return PracticeService
