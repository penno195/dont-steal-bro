--!strict
-- The hub practice area (P5-5): waiting players pick up the real items
-- and use them on each other. This file contains NO power-up or effect
-- logic. It switches EffectContext into practice mode, which makes the
-- real PowerUpService and StatusEffects run with shorter effects and a
-- lower cap (see EffectContext.luau for why it isn't a copy). Then it
-- tells them where the practice area is, and clears people who leave it.
--
-- WHAT KEEPS PRACTICE CONTAINED
--
--   Anywhere else in the hub. EffectContext.mayAct is false outside the
--   HubPracticeArea volume. PowerUpService checks it for the pickup, the
--   caster and every target, and StatusEffects checks it again for the
--   victim. An item carried out of the area is emptied on the next zone
--   check, and can't be used even before then.
--
--   The queue pad. A player in HubQueueNoEffectZone can't cast or be
--   hit, even if a hand-built hub let it overlap the practice area
--   (hub-spec.md forbids that). So campers on the pad have no effect.
--   Walking in clears whatever they had within zoneCheckSeconds. The
--   zone surrounds the pad, so that happens before they reach the pad.
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
-- MovementWatch exempts the area (EffectContext.inPracticeArea).
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
local practiceArea: BasePart? = nil
local noEffectZone: BasePart? = nil

-- Whole 3D box, in the volume's own space, so a rotated volume works.
local function isInside(volume: BasePart, position: Vector3): boolean
	local localPoint = volume.CFrame:PointToObjectSpace(position)
	local half = volume.Size / 2
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

local function rootPosition(participant: Participants.Participant): Vector3?
	local character = participant.character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- EffectContext's gate. Read live on every check, never cached, so a
-- player can't act from a spot they left a moment ago.
local function gate(id: number): boolean
	local participant = Participants.get(id)
	local area = practiceArea
	if participant == nil or area == nil then
		return false
	end

	local player = participant.player
	if player ~= nil and (Loader.get("MatchmakingService") :: any).isDeparting(player) then
		return false
	end

	local position = rootPosition(participant)
	if position == nil or not isInside(area, position) then
		return false
	end
	local zone = noEffectZone
	return zone == nil or not isInside(zone, position)
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
-- or an item gets cleared, whether they walked out, walked onto the
-- queue pad, or got matched. There's no "was inside" state to go stale.
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
	practiceArea = findOne("HubPracticeArea")
	if practiceArea == nil then
		warn("PracticeService: no HubPracticeArea under Workspace.Hub - practice is off on this server")
		return
	end
	noEffectZone = findOne("HubQueueNoEffectZone")
	if noEffectZone == nil then
		warn("PracticeService: no HubQueueNoEffectZone - the queue pad has no no-effect zone")
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
