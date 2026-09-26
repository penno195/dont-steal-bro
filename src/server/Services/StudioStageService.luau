--!strict
-- Stages the Decision Studio on its one shared set. Every finale, on
-- every race map, happens in the same place: ServerStorage.Maps.
-- <GameConfig.decisionStudioStage.mapId> (the Blocky Cave build, see
-- docs/decision-studio.md "The set"). The race map stays where it is;
-- the set is cloned beside it, `offsetStuds` along +X, when the race
-- resolves (Qualified), so it has streamed in by the time anyone is
-- moved there.
--
-- WHO GOES WHERE, when DecisionService opens Intro:
--   - The finalists (DecisionService's seat order, after any Q3
--     promotion) stand on the StudioPodiumSlot whose SlotIndex matches
--     their seat, facing the StudioAnchor at the centre - so the three
--     face each other - and are held there by anchoring the root part.
--     NPC finalists too: a bot is just a rig here.
--   - Everyone else, human or NPC, goes to a StudioSpectatorSpawn on the
--     walkway behind the fence, and anyone whose root leaves the
--     StudioSpectatorArea box around that walkway - over the fence onto
--     the rocks, down the terraces at its end, round the corner - is put
--     straight back.
--   - A character that respawns mid-finale is put back in its place.
-- Leaving DecisionStudio releases the anchors. The set stays until the
-- server shuts down: at Cleanup, MatchTeleportService sends everyone
-- home, and the floor must still be there while they go.
--
-- WHAT THIS DOESN'T DO: chat. Losers are watch-only, which StudioChat
-- enforces with StudioStageLogic's delivery rules.
--
-- SERVER AUTHORITY: nothing here reads the client. Positions are the
-- server's own; a modified client that walks its finalist off the
-- podium changes only its own view, and changes nothing about the vote,
-- which only ever arrives through DecisionService's validated remote.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local MapStreaming = require(ServerScriptService.Server.MapStreaming)
local Participants = require(ServerScriptService.Server.Participants)
local StudioStageLogic = require(ServerScriptService.Server.StudioStageLogic)

-- How often spectators are checked for having left the upper level.
local CONTAIN_INTERVAL = 0.25
-- Root height above the feet, when a rig has no Humanoid to ask.
local DEFAULT_STAND_HEIGHT = 3

type Stage = {
	root: Model,
	anchor: BasePart,
	podiums: { [number]: BasePart }, -- SlotIndex -> podium
	lookouts: { BasePart },
	area: BasePart?, -- nil = no StudioSpectatorArea, no containment
}

local stage: Stage? = nil
local staged = false
local finalists: { [number]: boolean } = {}
local podiumOf: { [number]: number } = {} -- racer id -> SlotIndex
local lookoutOf: { [number]: number } = {} -- racer id -> lookout index
local anchoredRoots: { BasePart } = {}
local containConnection: RBXScriptConnection? = nil

-- ===== loading the set ======================================================

local function tagged(root: Instance, tag: string): { BasePart }
	local out: { BasePart } = {}
	for _, instance in root:GetDescendants() do
		if instance:IsA("BasePart") and CollectionService:HasTag(instance, tag) then
			table.insert(out, instance)
		end
	end
	-- Name order, so every server lists lookouts the same way.
	table.sort(out, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return out
end

local function loadStage(): Stage?
	if stage ~= nil then
		return stage
	end
	local config = GameConfig.decisionStudioStage
	local maps = ServerStorage:FindFirstChild("Maps")
	local source = if maps ~= nil then maps:FindFirstChild(config.mapId) else nil
	if source == nil or not source:IsA("Model") then
		warn(
			string.format(
				"StudioStageService: no model named %q in ServerStorage.Maps - the finale will run where everyone stands",
				config.mapId
			)
		)
		return nil
	end

	local root = source:Clone()
	-- Read the tags on the clone before parenting: GetTagged only sees
	-- the DataModel, and every map also carries its own copies.
	local anchors = tagged(root, "StudioAnchor")
	local lookouts = tagged(root, "StudioSpectatorSpawn")
	if #anchors ~= 1 or #lookouts == 0 then
		warn(
			string.format(
				"StudioStageService: %s needs exactly 1 StudioAnchor and at least 1 StudioSpectatorSpawn (has %d and %d)",
				config.mapId,
				#anchors,
				#lookouts
			)
		)
		root:Destroy()
		return nil
	end

	local podiums: { [number]: BasePart } = {}
	for _, podium in tagged(root, "StudioPodiumSlot") do
		local index = podium:GetAttribute("SlotIndex")
		if typeof(index) == "number" then
			podiums[index] = podium
		end
	end

	local areas = tagged(root, "StudioSpectatorArea")
	root:PivotTo(root:GetPivot() + Vector3.new(config.offsetStuds, 0, 0))

	MapStreaming.prepare(root)
	root.Parent = Workspace

	stage = {
		root = root,
		anchor = anchors[1],
		podiums = podiums,
		lookouts = lookouts,
		area = areas[1],
	}
	return stage
end

-- ===== placing characters ===================================================

local function rootOf(character: Model?): BasePart?
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local function standHeight(character: Model, root: BasePart): number
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return DEFAULT_STAND_HEIGHT
	end
	return humanoid.HipHeight + root.Size.Y / 2
end

local function podiumCFrame(s: Stage, podium: BasePart, character: Model, root: BasePart): CFrame
	local cf = podium.CFrame
	local top = StudioStageLogic.topY(
		podium.Position.Y,
		podium.Size.X,
		podium.Size.Y,
		podium.Size.Z,
		cf.RightVector.Y,
		cf.UpVector.Y,
		cf.LookVector.Y
	)
	local centre = s.anchor.Position
	local stand = StudioStageLogic.standOn(
		podium.Position.X,
		top,
		podium.Position.Z,
		standHeight(character, root),
		centre.X,
		centre.Z
	)
	local at = Vector3.new(stand.x, stand.y, stand.z)
	return CFrame.lookAt(at, at + Vector3.new(stand.lookX, 0, stand.lookZ))
end

local function lookoutCFrame(s: Stage, index: number, character: Model, root: BasePart): CFrame
	local lookout = s.lookouts[index]
	local top = lookout.Position.Y + lookout.Size.Y / 2
	-- Facing the podiums, so a spectator lands already watching.
	local at = Vector3.new(lookout.Position.X, top + standHeight(character, root), lookout.Position.Z)
	local centre = s.anchor.Position
	return CFrame.lookAt(at, Vector3.new(centre.X, at.Y, centre.Z))
end

-- Streams the spot to a human first (it yields), so nobody lands on
-- geometry their client hasn't loaded. Anchors a finalist once there.
local function moveTo(racer: Participants.Participant, target: CFrame, hold: boolean)
	local player = racer.player
	if player ~= nil then
		MapStreaming.streamAround(player, target.Position)
	end
	local character = racer.character
	local root = rootOf(character)
	if character == nil or root == nil or not staged then
		return
	end
	root.Anchored = false
	character:PivotTo(target)
	if hold then
		root.Anchored = true
		table.insert(anchoredRoots, root)
	end
end

-- Puts one racer where they belong for this finale. Safe to call again
-- (a respawn, or a spectator who jumped down).
local function place(racer: Participants.Participant)
	local s = stage
	local character = racer.character
	local root = rootOf(character)
	if s == nil or character == nil or root == nil then
		return
	end

	local slot = podiumOf[racer.id]
	if slot ~= nil then
		task.spawn(moveTo, racer, podiumCFrame(s, s.podiums[slot], character, root), true)
		return
	end
	if finalists[racer.id] then
		return -- a finalist with no podium of their own stays put; warned at staging
	end
	local lookout = lookoutOf[racer.id] or 1
	task.spawn(moveTo, racer, lookoutCFrame(s, lookout, character, root), false)
end

-- ===== the finale ===========================================================

local function contain()
	local s = stage
	local area = if s ~= nil then s.area else nil
	if area == nil then
		return
	end
	for _, racer in Participants.all() do
		if finalists[racer.id] then
			continue
		end
		local root = rootOf(racer.character)
		if root == nil then
			continue
		end
		local at = area.CFrame:PointToObjectSpace(root.Position)
		if not StudioStageLogic.isInsideArea(at.X, at.Y, at.Z, area.Size.X, area.Size.Y, area.Size.Z) then
			place(racer)
		end
	end
end

local function beginStaging()
	local s = loadStage()
	if s == nil then
		return
	end
	local DecisionService = Loader.get("DecisionService") :: any
	local qualifierIds = DecisionService.getQualifierIds() :: { number }

	finalists = {}
	for _, id in qualifierIds do
		finalists[id] = true
	end
	local slotIndices: { number } = {}
	for index in s.podiums do
		table.insert(slotIndices, index)
	end
	podiumOf = StudioStageLogic.podiumFor(qualifierIds, slotIndices)
	for seat, id in qualifierIds do
		if podiumOf[id] == nil then
			warn(string.format("StudioStageService: no StudioPodiumSlot with SlotIndex %d for seat %d", seat, seat))
		end
	end

	local spectatorIds: { number } = {}
	for _, racer in Participants.all() do
		if not finalists[racer.id] then
			table.insert(spectatorIds, racer.id)
		end
	end
	lookoutOf = StudioStageLogic.lookoutFor(spectatorIds, #s.lookouts)

	staged = true
	for _, racer in Participants.all() do
		place(racer)
	end

	local sinceCheck = 0
	containConnection = RunService.Heartbeat:Connect(function(dt: number)
		sinceCheck += dt
		if sinceCheck >= CONTAIN_INTERVAL then
			sinceCheck = 0
			contain()
		end
	end)
end

local function endStaging()
	staged = false
	if containConnection ~= nil then
		containConnection:Disconnect()
		containConnection = nil
	end
	for _, root in anchoredRoots do
		if root.Parent ~= nil then
			root.Anchored = false
		end
	end
	anchoredRoots = {}
	finalists = {}
	podiumOf = {}
	lookoutOf = {}
end

local function watchRespawns(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		if not staged then
			return
		end
		character:WaitForChild("HumanoidRootPart", 5)
		local racer = Participants.fromPlayer(player)
		if racer ~= nil and staged then
			place(racer)
		end
	end)
end

local StudioStageService: Loader.Service = {
	name = "StudioStageService",
	dependencies = { "ConfigValidator", "RoundService", "DecisionService", "ParticipantService" },
}

function StudioStageService:init()
	local RoundService = Loader.get("RoundService") :: any
	local DecisionService = Loader.get("DecisionService") :: any

	-- Loaded as the race resolves, so it has streamed in by Intro.
	RoundService.onEnter("Qualified", function()
		loadStage()
	end)
	DecisionService.onPhaseEnter("Intro", function()
		beginStaging()
	end)
	RoundService.onExit("DecisionStudio", endStaging)
	-- The set is NOT destroyed at Cleanup: that's when MatchTeleportService
	-- sends everyone home, and a teleport takes seconds - destroying the
	-- floor under them dropped players into the void mid-teleport. A
	-- match server runs one round and shuts down once everyone has left,
	-- which takes the set with it.
	RoundService.onEnter("Cleanup", endStaging)

	Players.PlayerAdded:Connect(watchRespawns)
	for _, player in Players:GetPlayers() do
		watchRespawns(player)
	end
end

return StudioStageService
