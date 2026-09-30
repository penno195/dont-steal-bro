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
-- PowerUpService's audit both check EffectContext.recordsStats(). A solve
-- at the practice task station never reaches TaskService.
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
local ServerStorage = game:GetService("ServerStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local Participants = require(ServerScriptService.Server.Participants)
local EffectContext = require(ServerScriptService.Server.EffectContext)

local config = GameConfig.practice

local powerUpDefsById: { [string]: Validate.PowerUpDef } = {}
for _, entry in PowerUps do
	powerUpDefsById[entry.def.id] = entry.def
end

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
	local participant = Participants.get(id)
	if participant ~= nil and participant.player ~= nil then
		(Loader.get("TaskHandlerService") :: any).endPracticeFor(participant.player)
	end
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

-- TRAINING DUMMIES: a still rig on each HubPracticeDummy part, so a lone
-- player can see what an item does without a second player. Each one is
-- an ordinary NPC participant (isNPC, no Player), which is all the real
-- targeting and StatusEffects need - there is no dummy branch in either.
-- The client finds it for lock-on and effect labels by its
-- PracticeDummy tag and ParticipantId attribute.
local DUMMY_NAME = "Training Dummy"
local DUMMY_HOME_DRIFT_STUDS = 4 -- knocked further than this, it's put back...
local DUMMY_RESET_SECONDS = 3 -- ...after this long, so the knockback is seen first

type Dummy = { id: number, model: Model, root: BasePart, home: CFrame, awaySince: number? }
local dummies: { Dummy } = {}

local function spawnDummies()
	local hub = Workspace:FindFirstChild("Hub")
	if hub == nil then
		return
	end
	local anchors = {}
	for _, instance in CollectionService:GetTagged("HubPracticeDummy") do
		if instance:IsA("BasePart") and instance:IsDescendantOf(hub) then
			table.insert(anchors, instance)
		end
	end
	if #anchors == 0 then
		return
	end
	-- Its own rig if one is built, else the NPC one.
	local template = ServerStorage:FindFirstChild("PracticeDummy") or ServerStorage:FindFirstChild("NPCRig")
	if template == nil or not template:IsA("Model") then
		warn("PracticeService: HubPracticeDummy placed but no ServerStorage.PracticeDummy/NPCRig - no dummies")
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "PracticeDummies"
	folder.Parent = Workspace
	for _, anchor in anchors do
		local model = template:Clone()
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if humanoid == nil or root == nil or not root:IsA("BasePart") then
			warn("PracticeService: dummy rig has no Humanoid/HumanoidRootPart - skipped")
			model:Destroy()
			continue
		end
		local id = Participants.allocateNPCId()
		local home = anchor.CFrame + Vector3.new(0, anchor.Size.Y / 2 + root.Size.Y / 2 + humanoid.HipHeight, 0)
		model.Name = DUMMY_NAME
		humanoid.DisplayName = DUMMY_NAME
		humanoid.BreakJointsOnDeath = false
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		model:PivotTo(home)
		model:SetAttribute("ParticipantId", id)
		model.Parent = folder
		CollectionService:AddTag(model, "PracticeDummy")
		root:SetNetworkOwner(nil) -- server physics, so a push lands the same for everyone
		Participants.register({ id = id, displayName = DUMMY_NAME, isNPC = true, player = nil, character = model })
		table.insert(dummies, { id = id, model = model, root = root, home = home, awaySince = nil })
	end
end

-- A dummy knocked off its spot walks nowhere on its own, so put it back
-- once it has been away a moment and nothing is still acting on it.
local function returnDummies()
	local StatusEffects = Loader.get("StatusEffects") :: any
	local t = os.clock()
	for _, dummy in dummies do
		local away = (dummy.root.Position - dummy.home.Position).Magnitude > DUMMY_HOME_DRIFT_STUDS
		if not away then
			dummy.awaySince = nil
		elseif dummy.awaySince == nil then
			dummy.awaySince = t
		elseif
			t - (dummy.awaySince :: number) >= DUMMY_RESET_SECONDS
			and #StatusEffects.getActiveEffectsFor(dummy.id) == 0
		then
			dummy.root.AssemblyLinearVelocity = Vector3.zero
			dummy.model:PivotTo(dummy.home)
			dummy.awaySince = nil
		end
	end
end

-- DUMMIES FIGHT BACK: every config.dummyAttackSeconds, one dummy throws
-- an attack at a player in the practice area. You feel what Blind or
-- Freeze does, and Second Wind and Phase Step - which do nothing with
-- no attacker - get something to counter. It goes through the real use
-- path (grantFor, then useForRacer, like an NPC), so range, the aim
-- cone, practice's shortened durations and the "X used Y on you" toast
-- all hold. Only players inside HubPracticeArea are targeted, so
-- nobody idling elsewhere in the hub is disturbed. A dummy that is
-- itself under an effect doesn't throw: you froze it, it's frozen.
local practiceArea: BasePart? = nil

local function isInPracticeArea(position: Vector3): boolean
	local area = practiceArea
	if area == nil then
		return false
	end
	local offset = area.CFrame:PointToObjectSpace(position)
	return math.abs(offset.X) <= area.Size.X / 2
		and math.abs(offset.Y) <= area.Size.Y / 2
		and math.abs(offset.Z) <= area.Size.Z / 2
end

-- Would `def`, thrown by `dummy`, land on someone standing at `position`?
-- An Aimed throw turns the dummy to face its target first (faceTarget),
-- as a player turns to aim, so only range limits it; the aim cone then
-- holds by construction and a dummy never throws something that misses.
local function dummyCanReach(dummy: Dummy, def: Validate.PowerUpDef, position: Vector3): boolean
	local from = dummy.root.Position
	if def.target == "Area" then
		return (position - from).Magnitude <= (def.areaRadiusStuds or 0)
	end
	return (position - from).Magnitude <= GameConfig.powerUpUseRangeStuds
end

local DUMMY_TURN_BACK_SECONDS = 1.5 -- long enough to see who threw it

-- Turns the dummy (yaw only) to face `position`, then back to its spot's
-- facing a moment later unless it has been knocked away meanwhile
-- (returnDummies puts that one back).
local function faceTarget(dummy: Dummy, position: Vector3)
	local root = dummy.root
	local flat = Vector3.new(position.X, root.Position.Y, position.Z)
	if (flat - root.Position).Magnitude < 0.1 then
		return
	end
	local pivotOffset = root.CFrame:ToObjectSpace(dummy.model:GetPivot())
	dummy.model:PivotTo(CFrame.lookAt(root.Position, flat) * pivotOffset)
	task.delay(DUMMY_TURN_BACK_SECONDS, function()
		if (dummy.root.Position - dummy.home.Position).Magnitude <= DUMMY_HOME_DRIFT_STUDS then
			dummy.model:PivotTo(dummy.home)
		end
	end)
end

local function shuffled<T>(list: { T }): { T }
	local copy = table.clone(list)
	for i = #copy, 2, -1 do
		local j = math.random(1, i)
		copy[i], copy[j] = copy[j], copy[i]
	end
	return copy
end

type Target = { id: number, position: Vector3 }

-- Throws one of `powerUpIds` at one of `targets`, from any dummy that
-- can reach. True if something was thrown.
local function throwAt(targets: { Target }, powerUpIds: { string }): boolean
	local PowerUpService = Loader.get("PowerUpService") :: any
	local StatusEffects = Loader.get("StatusEffects") :: any

	for _, dummy in shuffled(dummies) do
		if #StatusEffects.getActiveEffectsFor(dummy.id) > 0 then
			continue
		end
		for _, powerUpId in shuffled(powerUpIds) do
			local def = powerUpDefsById[powerUpId]
			if def == nil or PowerUpService.isOnCooldownFor(dummy.id, powerUpId) then
				continue
			end
			for _, target in shuffled(targets) do
				if dummyCanReach(dummy, def, target.position) then
					if def.target == "Aimed" then
						faceTarget(dummy, target.position)
					end
					PowerUpService.grantFor(dummy.id, powerUpId)
					PowerUpService.useForRacer(dummy.id, 1, if def.target == "Aimed" then target.id else nil)
					return true
				end
			end
		end
	end
	return false
end

-- A player mid-task at the practice station only ever gets a task attack
-- (Task Scramble), and gets it first: that's the one thing the station
-- is there to show, and a push or freeze would just end the attempt.
local function dummyAttack()
	local TaskHandlerService = Loader.get("TaskHandlerService") :: any

	local atTask: { Target } = {}
	local others: { Target } = {}
	for _, participant in Participants.all() do
		local player = participant.player
		local position = rootPosition(participant)
		if player ~= nil and position ~= nil and gate(participant.id) and isInPracticeArea(position) then
			local list = if TaskHandlerService.isAtPracticeTask(player) then atTask else others
			table.insert(list, { id = participant.id, position = position })
		end
	end

	if #atTask > 0 and throwAt(atTask, config.dummyTaskAttackPowerUpIds) then
		return -- one throw per interval
	end
	if #others > 0 then
		throwAt(others, config.dummyAttackPowerUpIds)
	end
end

-- PRACTICE TASK STATION: the HubPracticeTask part runs config.taskId
-- through the real TaskHandlerService, so Task Insight and Task Scramble
-- have a task to change. The server names it with a StationId attribute,
-- which the client's prompt reads. Anyone practising can use it, as often
-- as they like; a solve is only feedback (TaskHandlerService never calls
-- TaskService for it).
local PRACTICE_STATION_ID = "hub-practice-task"

local function setUpTaskStation()
	local part = findOne("HubPracticeTask")
	if part == nil then
		return
	end
	part:SetAttribute("StationId", PRACTICE_STATION_ID)
	local TaskHandlerService = Loader.get("TaskHandlerService") :: any
	TaskHandlerService.setPracticeStation(PRACTICE_STATION_ID, part, config.taskId, function(player: Player): boolean
		return gate(player.UserId)
	end)
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
	dependencies = {
		"ConfigValidator",
		"ParticipantService",
		"PowerUpService",
		"StatusEffects",
		"MatchmakingService",
		"TaskHandlerService",
	},

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
	PowerUpService.setSelectionBag(config.bagCopiesByRole)
	PowerUpService.startPickups()
	practiceArea = findOne("HubPracticeArea")
	spawnDummies()
	setUpTaskStation()

	-- No PlayerRemoving handler: PowerUpService and StatusEffects already
	-- drop a leaver's state, and clearing here would recreate it.
	task.spawn(function()
		while true do
			task.wait(config.zoneCheckSeconds)
			checkZones()
			returnDummies()
		end
	end)
	if #dummies > 0 and #config.dummyAttackPowerUpIds > 0 then
		task.spawn(function()
			while true do
				task.wait(config.dummyAttackSeconds)
				dummyAttack()
			end
		end)
	end
end

return PracticeService
