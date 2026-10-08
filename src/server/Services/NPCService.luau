--!strict
-- NPC fill (P3-5): when matchmaking doesn't find 6 humans, bots take the
-- remaining seats so the round still works. architecture.md §4 is the
-- design; this is the Roblox-touching half of it. Everything that is
-- arithmetic rather than engine - how many to spawn, which skill profile
-- each draws, how long it works at a station, the fairness floor, the
-- route through the nav graph, its name - lives in NPCLogic.luau, which
-- is unit-tested headlessly (Ground Rule 4).
--
-- THE CENTRAL DESIGN DECISION, restated because everything here depends
-- on it: NPCs do NOT play the minigames. A bot walks to a station and
-- "works" for a sampled duration, then reports completion through
-- TaskService.recordCompletionFor - the same function P2-5's validated
-- TaskHandler calls for a human, one layer down from the Player-shaped
-- wrapper. There is no NPC branch in TaskService, Qualification,
-- Outcomes or DecisionService, and adding one would be a bug.
--
-- WHY A BOT CAN'T FAKE ITS WAY PAST A HUMAN: NPCLogic.sampleWorkSeconds
-- floors every sampled duration at the median human time for that task
-- (this server, this round - see `humanDurationSamples` below), so a
-- lucky roll on a strong profile still can't beat the median human.
-- A real player's result counts however many seats are bots
-- (design-decisions.md Q5's 2026-10-02 applied case); docs/npc-notes.md
-- states where NPC presence can still distort the leaderboard.
--
-- WHERE THE MAP COMES FROM: the same injection-point pattern TaskService
-- and PowerUpService already use (see either file's header) - no
-- map-loading service exists yet, so nav nodes and spawn points arrive
-- through `setNavNodes`/`setSpawnPoints`, with Studio-only
-- `debugLoadFromMap` filling both in from a real map's CollectionService
-- tags today.
--
-- TICK, NOT HEARTBEAT: one timer drives every NPC at
-- GameConfig.npc.tickHz (architecture.md §4's 5-10 Hz, validated into
-- that range at boot), not a RunService.Heartbeat connection and not one
-- coroutine per bot yielding on MoveToFinished. docs/npc-notes.md
-- derives the whole per-server cost from that one number.

local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Tasks = require(ReplicatedStorage.Shared.Config.Tasks)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local Participants = require(ServerScriptService.Server.Participants)
local NPCLogic = require(ServerScriptService.Server.NPCLogic)
local NPCAnimator = require(ServerScriptService.Server.NPCAnimator)
local StationOccupancy = require(ServerScriptService.Server.StationOccupancy)

local taskDefsById: { [string]: Validate.TaskDef } = {}
for _, entry in Tasks do
	local def = entry.def :: Validate.TaskDef
	taskDefsById[def.id] = def
end

-- How close a rig has to get to the CURRENT path waypoint before the
-- tick advances it to the next one. Distinct from the arrival radius at
-- a station (config): this is a pathing detail, not a gameplay knob.
local WAYPOINT_REACHED_STUDS = 4
-- Measured flat, with the height checked separately: waypoints sit on
-- the navmesh, ~3 studs below the root, and on a steep ramp the navmesh
-- itself can sit another 1-2 studs under the surface. A 3D check then
-- never fires while the Humanoid, which judges MoveTo flat, has already
-- stopped on the waypoint - the bot stands still until the stuck timer
-- gives up (Factory's bridge ramps, 2026-10-03).
local WAYPOINT_REACHED_HEIGHT_STUDS = 6
-- A rig that has moved less than this since the last tick is making no
-- progress, for the stuck timer's purposes. Small enough that a bot
-- shuffling on the spot against a wall still counts as stuck.
local PROGRESS_EPSILON_STUDS = 0.5
-- A hop to a nav node no further than this, along a clear line with
-- continuous floor, is walked straight instead of pathfound. Covers the
-- node spacing on ramps (~15 studs) with room to spare, while leaving
-- long hops to PathfindingService, which routes round what a straight
-- line can't see. See canWalkStraight.
local DIRECT_WALK_MAX_STUDS = 24
-- Floor is sampled this often along a straight-walk line...
local DIRECT_WALK_SAMPLE_STUDS = 2
-- ...and two neighbouring samples may differ by at most this much: about
-- what a Humanoid steps up without jumping. More is a ledge or a gap.
local DIRECT_WALK_MAX_STEP_STUDS = 1.2
-- The body clearance swept along the line. Just under AgentRadius so a
-- lane the navmesh would accept isn't rejected here.
local DIRECT_WALK_CLEARANCE_STUDS = 1.5

export type NavNodeRecord = {
	nodeId: string,
	position: Vector3,
	connectedNodeIds: { string },
}

type NPCPhase = "Idle" | "Walking" | "Working" | "Finished"

type NPCRecord = {
	id: number,
	displayName: string,
	profile: NPCLogic.SkillProfile,
	nextRandom: () -> number,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,

	phase: NPCPhase,
	targetStationId: string?,
	-- The coarse route through the nav graph, plus how far along it we
	-- are. `nodeIndex > #nodeRoute` means "past the last node, heading
	-- for the station part itself."
	nodeRoute: { string },
	nodeIndex: number,
	waypoints: { Vector3 },
	jumpWaypoints: { [number]: boolean },
	waypointIndex: number,
	repathsThisStation: number,
	blocked: boolean,
	blockedConnection: RBXScriptConnection?,

	workEndsAt: number?,
	lastPosition: Vector3?,
	lastProgressAt: number,
}

local navNodes: { [string]: NavNodeRecord } = {}
local spawnPoints: { BasePart } = {}
local npcs: { [number]: NPCRecord } = {}
local npcFolder: Folder? = nil
local tickThread: thread? = nil
local mapDifficultyModifier = 1.0
local roundSeed = 0

-- Real human completion times, per task id, for this server. The
-- fairness floor is measured against the median of these - see
-- NPCLogic.fairnessFloorSeconds for what happens before there are
-- enough of them (the catalogue range stands in, so the guarantee holds
-- from the first second of the race rather than only once three humans
-- have finished something).
local humanDurationSamples: { [string]: { number } } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- ===== map injection ========================================================

local function setNavNodes(nodes: { NavNodeRecord })
	navNodes = {}
	for _, node in nodes do
		navNodes[node.nodeId] = node
	end
end

local function setSpawnPoints(points: { BasePart })
	spawnPoints = points
end

-- MapDef.npcDifficultyModifier for the map in play (0.5-2.0, 1.0 =
-- baseline). Defaults to 1.0 until whatever loads a map calls this -
-- no map registry has an entry yet (src/shared/Config/Maps/init.luau).
local function setMapDifficultyModifier(modifier: number)
	mapDifficultyModifier = modifier
end

-- Studio-only convenience, same shape as TaskService.
-- debugLoadStationsFromMap: fills in both nav nodes and spawn points
-- from a real map's own tags. Works against P2-3's GrayBoxTest today.
local function debugLoadFromMap(mapRoot: Instance)
	local nodes: { NavNodeRecord } = {}
	for _, instance in CollectionService:GetTagged("NavNode") do
		if not (instance:IsDescendantOf(mapRoot) and instance:IsA("Attachment")) then
			continue
		end

		local nodeId = instance:GetAttribute("NodeId") :: string?
		if nodeId == nil then
			warn(string.format("NPCService: %s is missing NodeId - skipped", instance:GetFullName()))
			continue
		end

		local connectedRaw = instance:GetAttribute("ConnectedNodeIds") :: string?
		local connected = if connectedRaw ~= nil and connectedRaw ~= ""
			then string.split(connectedRaw, ",")
			else {} :: { string }

		table.insert(nodes, {
			nodeId = nodeId,
			position = instance.WorldPosition,
			connectedNodeIds = connected,
		})
	end

	local points: { BasePart } = {}
	for _, instance in CollectionService:GetTagged("SpawnPoint") do
		if instance:IsDescendantOf(mapRoot) and instance:IsA("BasePart") then
			table.insert(points, instance)
		end
	end

	setNavNodes(nodes)
	setSpawnPoints(points)
	print(
		string.format(
			"NPCService: loaded %d nav node(s) and %d spawn point(s) from %s",
			#nodes,
			#points,
			mapRoot:GetFullName()
		)
	)
end

-- The pure id-only view of the graph NPCLogic.findNodePath searches.
local function navGraph(): NPCLogic.NavGraph
	local graph: NPCLogic.NavGraph = {}
	for nodeId, node in navNodes do
		graph[nodeId] = node.connectedNodeIds
	end
	return graph
end

local function toPoint(position: Vector3): NPCLogic.Point
	return { x = position.X, y = position.Y, z = position.Z }
end

local function navPoints(): { [string]: NPCLogic.Point }
	local points: { [string]: NPCLogic.Point } = {}
	for nodeId, node in navNodes do
		points[nodeId] = toPoint(node.position)
	end
	return points
end

local function nearestNodeId(position: Vector3): string?
	local bestId: string? = nil
	local bestDistance = math.huge
	for nodeId, node in navNodes do
		local distance = (node.position - position).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			bestId = nodeId
		end
	end
	return bestId
end

-- The coarse route between two points as NavNode positions, ends
-- trimmed the way a bot's are, and without the two points themselves.
-- Empty on a map with no nodes or a disconnected graph. NavigationService
-- draws a player's path line through these: the graph is server-only
-- (MapStreaming), and walking it costs no ComputeAsync.
local function routeBetween(from: Vector3, to: Vector3): { Vector3 }
	local fromNode = nearestNodeId(from)
	local toNode = nearestNodeId(to)
	if fromNode == nil or toNode == nil then
		return {}
	end
	local route = NPCLogic.findNodePath(navGraph(), fromNode, toNode) or {}
	local trimmed = NPCLogic.trimRoute(route, navPoints(), toPoint(from), toPoint(to))
	local positions: { Vector3 } = {}
	for _, nodeId in trimmed do
		table.insert(positions, navNodes[nodeId].position)
	end
	return positions
end

-- ===== rigs =================================================================

-- A rig template hand-built in Studio is preferred, for the same reason
-- maps are (CLAUDE.md: the .rbxl is authoritative for content, this repo
-- for code) - drop a Model named "NPCRig" in ServerStorage and it is
-- used as-is. The code-built fallback below exists so the system runs
-- today, before anyone has built one, and so a missing template can
-- never silently produce an NPC-less round.
--
-- NOT VERIFIED IN STUDIO YET: the fallback's proportions and HipHeight
-- are the standard minimal-Humanoid recipe (a HumanoidRootPart, a Head -
-- a Humanoid whose Head is missing dies immediately - and a Humanoid),
-- but this specific rig has not been walked around a real map. See
-- docs/npc-notes.md's integration checklist: if bots sink into the floor
-- or refuse to path, this function is the first place to look.
local function buildFallbackRig(): Model
	local model = Instance.new("Model")

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.CanCollide = false
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.BrickColor = BrickColor.new("Bright blue")
	torso.CanCollide = false
	torso.Parent = model

	local torsoWeld = Instance.new("WeldConstraint")
	torsoWeld.Part0 = root
	torsoWeld.Part1 = torso
	torsoWeld.Parent = root

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1, 1, 1)
	head.BrickColor = BrickColor.new("Bright yellow")
	head.CanCollide = false
	head.CFrame = root.CFrame * CFrame.new(0, 1.5, 0)
	head.Parent = model

	local headWeld = Instance.new("WeldConstraint")
	headWeld.Part0 = root
	headWeld.Part1 = head
	headWeld.Parent = root

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.HipHeight = 1.5
	humanoid.Parent = model

	model.PrimaryPart = root
	return model
end

-- A real R15 avatar dressed from GameConfig.npc.appearance, so a bot
-- looks like any other player in the lobby. Yields on a web call to
-- build the model, and returns nil if that fails (a bad asset id, the
-- avatar service being down) - the caller falls back to the plain rig
-- rather than losing the bot.
local function buildAvatarRig(appearance: NPCLogic.Appearance): Model?
	local description = Instance.new("HumanoidDescription")
	description.HairAccessory = tostring(appearance.hair)
	description.HatAccessory = if appearance.hat ~= nil then tostring(appearance.hat) else ""
	description.Face = appearance.face
	description.Shirt = appearance.shirt
	description.Pants = appearance.pants
	local tone = Color3.fromRGB(appearance.skinTone[1], appearance.skinTone[2], appearance.skinTone[3])
	description.HeadColor = tone
	description.TorsoColor = tone
	description.LeftArmColor = tone
	description.RightArmColor = tone
	description.LeftLegColor = tone
	description.RightLegColor = tone

	local ok, result = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
	end)
	description:Destroy()
	if not ok then
		warn(string.format("NPCService: avatar build failed, using the plain rig - %s", tostring(result)))
		return nil
	end
	return result
end

-- Every performance measure architecture.md §4 asks for, in one place:
-- server network ownership, unused Humanoid state types disabled, and
-- no client-side animation/physics work to do. docs/npc-notes.md
-- explains what each one is actually buying.
local function configureRigForPerformance(model: Model, humanoid: Humanoid, root: BasePart)
	root:SetNetworkOwner(nil)

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, false)

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CastShadow = false
		end
	end
end

-- ===== spawning =============================================================

local function ensureFolder(): Folder
	local existing = npcFolder
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "NPCs"
	folder.Parent = Workspace
	npcFolder = folder
	return folder
end

-- A spawn pad no human is standing on. map-kit-spec.md guarantees
-- exactly 6 SpawnPoints and the roster never exceeds 6, so this only
-- runs out if a map is mis-tagged - in which case the bot spawns on a
-- shared pad rather than not at all.
local function chooseSpawnCFrame(index: number): CFrame
	if #spawnPoints == 0 then
		return CFrame.new(0, 10, 0)
	end
	local point = spawnPoints[((index - 1) % #spawnPoints) + 1]
	return point.CFrame + Vector3.new(0, 4, 0)
end

-- architecture.md §4's "names that can never collide with real
-- usernames" - the format guarantees the username half (see
-- NPCLogic.generateDisplayName), and this predicate covers the display
-- names actually in the server right now, so a bot can never appear to
-- be impersonating someone in the same round.
local function nameIsTaken(name: string): boolean
	local lowered = string.lower(name)
	for _, player in Players:GetPlayers() do
		if string.lower(player.DisplayName) == lowered or string.lower(player.Name) == lowered then
			return true
		end
	end
	for _, participant in Participants.all() do
		if string.lower(participant.displayName) == lowered then
			return true
		end
	end
	return false
end

local function spawnNPC(index: number): NPCRecord?
	local id = Participants.allocateNPCId()
	-- Seeded from the round seed and the NPC's own id, so one bot's
	-- draws never shift another's - see NPCLogic.newRng's own comment.
	local nextRandom = NPCLogic.newRng(roundSeed + id * 7919)
	-- Named before the avatar build yields, so bots spawning side by side
	-- (fillSeats) each see the others' names as taken.
	local displayName = NPCLogic.generateDisplayName(nextRandom, nameIsTaken)
	Participants.register({
		id = id,
		displayName = displayName,
		isNPC = true,
		player = nil,
		character = nil,
	})

	-- A real avatar first, then a hand-built "NPCRig" in ServerStorage,
	-- then the code-built block - each only if the one before it fails.
	local appearance = NPCLogic.pickAppearance(GameConfig.npc.appearance, nextRandom)
	local template = ServerStorage:FindFirstChild("NPCRig")
	local model = buildAvatarRig(appearance)
		or if template ~= nil and template:IsA("Model") then template:Clone() else buildFallbackRig()

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		warn("NPCService: rig template has no Humanoid/HumanoidRootPart - skipping this NPC")
		model:Destroy()
		Participants.unregister(id)
		return nil
	end

	model.Name = displayName
	model:PivotTo(chooseSpawnCFrame(index))
	model.Parent = ensureFolder()

	configureRigForPerformance(model, humanoid, root)
	NPCAnimator.start(model, humanoid)

	local profile = NPCLogic.pickSkillProfile(GameConfig.npc.skillProfiles, nextRandom())
	humanoid.WalkSpeed = 16 * profile.moveSpeedScale

	local record: NPCRecord = {
		id = id,
		displayName = displayName,
		profile = profile,
		nextRandom = nextRandom,
		model = model,
		humanoid = humanoid,
		root = root,

		phase = "Idle",
		targetStationId = nil,
		nodeRoute = {},
		nodeIndex = 1,
		waypoints = {},
		jumpWaypoints = {},
		waypointIndex = 1,
		repathsThisStation = 0,
		blocked = false,
		blockedConnection = nil,

		workEndsAt = nil,
		lastPosition = nil,
		lastProgressAt = now(),
	}

	npcs[id] = record
	Participants.setCharacter(id, model)

	return record
end

local function despawnNPC(record: NPCRecord)
	if record.blockedConnection ~= nil then
		record.blockedConnection:Disconnect()
	end

	local StatusEffects = Loader.get("StatusEffects") :: any
	StatusEffects.clearFor(record.id)

	local TaskService = Loader.get("TaskService") :: any
	TaskService.removeRacer(record.id)

	StationOccupancy.leave(record.id)
	Participants.unregister(record.id)
	npcs[record.id] = nil
	record.model:Destroy()
end

local function despawnAll()
	for _, record in npcs do
		despawnNPC(record)
	end
	npcs = {}
end

-- Broadcast so a client can put a name to a negative id when it sees one
-- in TaskProgress or the qualification result. Nothing secret is in it -
-- the bots are standing in the map in plain sight.
local function broadcastRoster()
	local roster = {}
	for _, record in npcs do
		table.insert(roster, { id = record.id, displayName = record.displayName })
	end
	Net.fireAllClients("NPCRoster", { npcs = roster })
end

-- ===== pathing ==============================================================

local function currentTargetPosition(record: NPCRecord): Vector3?
	local stationId = record.targetStationId
	if stationId == nil then
		return nil
	end

	-- Still walking the coarse graph: head for the next nav node.
	local nodeId = record.nodeRoute[record.nodeIndex]
	if nodeId ~= nil then
		local node = navNodes[nodeId]
		if node ~= nil then
			return node.position
		end
	end

	-- Past the last node (or no graph at all): head for the station.
	local TaskService = Loader.get("TaskService") :: any
	local part = TaskService.getStationPart(stationId) :: BasePart?
	return if part ~= nil then part.Position else nil
end

-- Whether a bot can walk straight from `from` to `to` with no pathfinding:
-- short enough, nothing solid in the way at body height, and floor under
-- every sample with no ledge or gap between them. Only collidable parts
-- count (RespectCanCollide), and rigs are ignored so a bot is never
-- blocked by itself or a rival.
--
-- WHY THIS EXISTS: the engine's navmesh can silently drop a walkable
-- surface. On SpaceStation the south central ramp gets no navmesh at all
-- at its built position (the identical north ramp is fine, and the same
-- part shifted 12 studs sideways is fine too), so ComputeAsync snapped
-- bots on it to the floor underneath and sent them on a 280-stud detour.
-- A PathfindingLink across it was ignored as well. Ramps are exactly
-- where map-kit-spec.md puts nav nodes (top, bottom and along), so hops
-- between them are short straight lines this check can vouch for itself.
local function canWalkStraight(from: Vector3, to: Vector3): boolean
	local offset = to - from
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude > DIRECT_WALK_MAX_STUDS then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	local ignore: { Instance } = {}
	if npcFolder ~= nil then
		table.insert(ignore, npcFolder)
	end
	for _, player in Players:GetPlayers() do
		if player.Character ~= nil then
			table.insert(ignore, player.Character)
		end
	end
	params.FilterDescendantsInstances = ignore

	if flat.Magnitude > 0.1 and Workspace:Spherecast(from, DIRECT_WALK_CLEARANCE_STUDS, offset, params) ~= nil then
		return false
	end

	-- Both ends sit about a hip height above their floor, so a ray from
	-- just above each sample down 6 studs finds this floor and never the
	-- level below a ramp or a catwalk.
	local samples = math.max(2, math.ceil(flat.Magnitude / DIRECT_WALK_SAMPLE_STUDS) + 1)
	local heights: { number } = {}
	for i = 0, samples - 1 do
		local point = from:Lerp(to, i / (samples - 1))
		local hit = Workspace:Raycast(point + Vector3.new(0, 1, 0), Vector3.new(0, -6, 0), params)
		if hit == nil then
			return false
		end
		table.insert(heights, hit.Position.Y)
	end
	return NPCLogic.isContinuousFloor(heights, DIRECT_WALK_MAX_STEP_STUDS)
end

-- One ComputeAsync per hop, and only when something actually needs one:
-- a new hop, a Blocked signal, or the stuck timer. Never per tick and
-- never per frame - architecture.md §4's "recompute only when blocked."
local function computePath(record: NPCRecord): boolean
	local target = currentTargetPosition(record)
	if target == nil then
		return false
	end

	if record.blockedConnection ~= nil then
		record.blockedConnection:Disconnect()
		record.blockedConnection = nil
	end

	-- A short, clear hop is walked straight - see canWalkStraight for why
	-- this can't be left to the navmesh. Cheaper than ComputeAsync too.
	-- The stuck timer still covers it if something moves into the way.
	if canWalkStraight(record.root.Position, target) then
		record.waypoints = { target }
		record.jumpWaypoints = {}
		record.waypointIndex = 1
		record.blocked = false
		return true
	end

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
	})

	local ok = pcall(function()
		path:ComputeAsync(record.root.Position, target)
	end)

	if not ok or path.Status ~= Enum.PathStatus.Success then
		-- No computable path to this hop. Walking straight at it is the
		-- honest fallback: on a sane map the next hop is close and in
		-- line of sight, and the stuck timer catches it if it isn't.
		record.waypoints = { target }
		record.jumpWaypoints = {}
		record.waypointIndex = 1
		record.blocked = false
		return true
	end

	local waypoints: { Vector3 } = {}
	local jumpWaypoints: { [number]: boolean } = {}
	for index, waypoint in path:GetWaypoints() do
		table.insert(waypoints, waypoint.Position)
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			jumpWaypoints[index] = true
		end
	end

	record.waypoints = waypoints
	record.jumpWaypoints = jumpWaypoints
	record.waypointIndex = 1
	record.blocked = false
	record.blockedConnection = path.Blocked:Connect(function(blockedWaypointIndex: number)
		-- Flagged, not recomputed inline: the recompute happens on the
		-- next tick, so a path that blocks and unblocks repeatedly can't
		-- turn into a ComputeAsync storm between ticks.
		if blockedWaypointIndex >= record.waypointIndex then
			record.blocked = true
		end
	end)

	return true
end

-- ===== the race =============================================================

local function beginWorking(record: NPCRecord, stationId: string)
	local TaskService = Loader.get("TaskService") :: any
	local taskId = TaskService.getTaskIdForRacer(record.id, stationId) :: string?
	local taskDef = if taskId ~= nil then taskDefsById[taskId] else nil

	if taskDef == nil then
		-- Assigned a station whose task has no config - finish it
		-- immediately rather than stalling the bot forever on a station
		-- it can never leave. Loud, because it means the map and the
		-- task registry disagree.
		warn(string.format("NPCService: no task def for station %s - completing immediately", stationId))
		TaskService.recordCompletionFor(record.id, stationId)
		record.phase = "Idle"
		return
	end

	local samples = humanDurationSamples[taskDef.id]
	local observedMedian: number? = nil
	if samples ~= nil and #samples >= GameConfig.npc.medianSampleMinimum then
		observedMedian = NPCLogic.median(samples)
	end

	local sample = NPCLogic.sampleWorkSeconds({
		expected = taskDef.expectedDurationSeconds,
		profile = record.profile,
		mapDifficultyModifier = mapDifficultyModifier,
		observedMedianSeconds = observedMedian,
		floorScale = GameConfig.npc.fairnessFloorScale,
		roll = record.nextRandom(),
	})

	if sample.flooredBy ~= nil then
		-- Deliberately a print, not a warn: being floored is the system
		-- working. It's logged at all so the rate is visible - see
		-- Validate.checkNPCConfig's note on what a profile that is
		-- ALWAYS floored means.
		print(
			string.format(
				"NPCService: %s floored on %s (%.1fs, profile %s)",
				record.displayName,
				taskDef.id,
				sample.seconds,
				record.profile.id
			)
		)
	end

	record.phase = "Working"
	record.workEndsAt = now() + sample.seconds
	record.humanoid:Move(Vector3.zero)
	-- A bot at a station is a rival there, the same as a human.
	local station = TaskService.getStationPart(stationId) :: BasePart?
	if station ~= nil then
		StationOccupancy.enter(record.id, station)
	end
end

local function chooseNextStation(record: NPCRecord)
	local TaskService = Loader.get("TaskService") :: any
	local remaining = TaskService.getRemainingStations(record.id) :: { { stationId: string, taskId: string } }

	if #remaining == 0 then
		record.phase = "Finished"
		return
	end

	local candidates: { NPCLogic.StationCandidate } = {}
	for _, assignment in remaining do
		local part = TaskService.getStationPart(assignment.stationId) :: BasePart?
		if part ~= nil then
			table.insert(candidates, {
				stationId = assignment.stationId,
				distance = (part.Position - record.root.Position).Magnitude,
			})
		end
	end

	local stationId = NPCLogic.chooseNextStation(candidates, record.nextRandom(), GameConfig.npc.nextStationTopK)
	if stationId == nil then
		record.phase = "Finished"
		return
	end

	record.targetStationId = stationId
	record.repathsThisStation = 0
	record.nodeRoute = {}
	record.nodeIndex = 1

	-- The coarse route: nearest node to us, nearest node to the station,
	-- BFS between them. A map with no nav nodes (or a disconnected
	-- graph) simply leaves nodeRoute empty, and the bot paths directly -
	-- worse for long routes, but never a stalled round.
	local TaskServicePart = TaskService.getStationPart(stationId) :: BasePart?
	if TaskServicePart ~= nil then
		local fromNode = nearestNodeId(record.root.Position)
		local toNode = nearestNodeId(TaskServicePart.Position)
		if fromNode ~= nil and toNode ~= nil then
			local route = NPCLogic.findNodePath(navGraph(), fromNode, toNode) or {}
			record.nodeRoute =
				NPCLogic.trimRoute(route, navPoints(), toPoint(record.root.Position), toPoint(TaskServicePart.Position))
		end
	end

	record.phase = "Walking"
	record.lastProgressAt = now()
	record.lastPosition = record.root.Position
	computePath(record)
end

local function arrivedAtStation(record: NPCRecord): boolean
	local stationId = record.targetStationId
	if stationId == nil then
		return false
	end

	local TaskService = Loader.get("TaskService") :: any
	local part = TaskService.getStationPart(stationId) :: BasePart?
	if part == nil then
		return false
	end

	return (part.Position - record.root.Position).Magnitude <= GameConfig.npc.stationArrivalRadiusStuds
end

local function tickWalking(record: NPCRecord, nowValue: number)
	local stationId = record.targetStationId
	if stationId == nil then
		record.phase = "Idle"
		return
	end

	if arrivedAtStation(record) then
		beginWorking(record, stationId)
		return
	end

	-- Stuck detection, measured against real movement rather than
	-- against the Humanoid's own MoveDirection: a rig walking hard into
	-- a wall reports a direction the whole time it isn't going anywhere.
	local position = record.root.Position
	local last = record.lastPosition
	if last == nil or (position - last).Magnitude > PROGRESS_EPSILON_STUDS then
		record.lastPosition = position
		record.lastProgressAt = nowValue
	end

	local stuckFor = nowValue - record.lastProgressAt
	if record.blocked or stuckFor >= GameConfig.npc.repathAfterStuckSeconds then
		record.repathsThisStation += 1

		if record.repathsThisStation > GameConfig.npc.maxRepathsPerStation then
			-- Last resort, and a visible one: a bot that genuinely can't
			-- reach its station is teleported to it rather than left
			-- standing in a doorway for the rest of the race, which
			-- would quietly hand every human a free qualification slot.
			-- The warn is the point - it means the map's nav graph or
			-- geometry needs fixing (map-kit-spec.md's NavNode section).
			local TaskService = Loader.get("TaskService") :: any
			local part = TaskService.getStationPart(stationId) :: BasePart?
			warn(
				string.format(
					"NPCService: %s gave up pathing to %s after %d recomputes - teleporting",
					record.displayName,
					stationId,
					record.repathsThisStation - 1
				)
			)
			if part ~= nil then
				record.model:PivotTo(CFrame.new(part.Position + Vector3.new(0, 4, 0)))
			end
			record.lastProgressAt = nowValue
			return
		end

		record.lastProgressAt = nowValue
		computePath(record)
		return
	end

	local waypoint: Vector3? = record.waypoints[record.waypointIndex]
	if waypoint == nil then
		-- Ran out of waypoints for this hop: step to the next nav node,
		-- or to the station once the route is exhausted.
		record.nodeIndex += 1
		computePath(record)
		return
	end

	-- Honour the jump action returned by the engine before advancing this waypoint.
	if record.jumpWaypoints[record.waypointIndex] and record.humanoid.FloorMaterial ~= Enum.Material.Air then
		record.humanoid.Jump = true
		record.jumpWaypoints[record.waypointIndex] = nil
	end

	local offset = (waypoint :: Vector3) - position
	if
		Vector3.new(offset.X, 0, offset.Z).Magnitude <= WAYPOINT_REACHED_STUDS
		and math.abs(offset.Y) <= WAYPOINT_REACHED_HEIGHT_STUDS
	then
		record.waypointIndex += 1
		local nextWaypoint: Vector3? = record.waypoints[record.waypointIndex]
		if nextWaypoint ~= nil then
			record.humanoid:MoveTo(nextWaypoint)
		end
		return
	end

	-- Re-issued every tick rather than once per waypoint: MoveTo's own
	-- 8-second internal timeout would otherwise stop a bot mid-hop on a
	-- long stretch, and re-issuing the same destination is cheap.
	record.humanoid:MoveTo(waypoint :: Vector3)
end

local function tickNPC(record: NPCRecord, nowValue: number)
	if record.humanoid.Health <= 0 then
		return
	end

	if record.phase == "Idle" then
		chooseNextStation(record)
	elseif record.phase == "Walking" then
		tickWalking(record, nowValue)
	elseif record.phase == "Working" then
		local endsAt = record.workEndsAt
		local stationId = record.targetStationId
		if endsAt ~= nil and nowValue >= endsAt and stationId ~= nil then
			local TaskService = Loader.get("TaskService") :: any
			TaskService.recordCompletionFor(record.id, stationId)
			StationOccupancy.leave(record.id)
			record.targetStationId = nil
			record.workEndsAt = nil
			record.phase = "Idle"
		end
	end
end

local function startTicking()
	if tickThread ~= nil then
		return
	end

	local interval = 1 / GameConfig.npc.tickHz
	tickThread = task.spawn(function()
		local me = coroutine.running()
		while true do
			task.wait(interval)
			local nowValue = now()
			for _, record in npcs do
				-- stopTicking can run from INSIDE this loop (see there).
				if tickThread ~= me then
					return
				end
				-- One bot erroring must not stop every other bot's tick.
				-- The message is captured through the handler's upvalue
				-- rather than xpcall's second return, for the reason
				-- tests/TestRunner.luau documents: strict-mode return
				-- arity follows the wrapped function's own return count,
				-- which is zero here.
				local errMessage: string? = nil
				local ok = xpcall(tickNPC, function(err)
					errMessage = tostring(err)
				end, record, nowValue)
				if not ok then
					warn(string.format("NPCService: tick failed for %s - %s", record.displayName, tostring(errMessage)))
				end
			end
		end
	end)
end

-- Found in Studio: a bot finishing the race ends Race from inside its own
-- tick, so this runs on the tick thread's stack, and task.cancel throws
-- on a thread that isn't suspended. Clearing tickThread is what stops
-- the loop then; it checks before each bot and returns.
local function stopTicking()
	local thread = tickThread
	tickThread = nil
	if thread ~= nil and coroutine.status(thread) == "suspended" then
		task.cancel(thread)
	end
end

-- ===== fill =================================================================

-- architecture.md §4: derived on THIS server from who is actually here,
-- after a grace window, and never from TeleportData (threat-model.md §5
-- - the hint isn't even plumbed in; see NPCLogic.deriveFillCount).
-- P5-2: on a real match server, MatchTeleportService's arrival gate has
-- already waited out this grace window before requesting Loading, and
-- turned late arrivals away since. It says so here instead of the
-- window being served twice. Studio's debug path still waits.
local graceAlreadyServed = false

local function fillSeats()
	if not graceAlreadyServed then
		task.wait(GameConfig.npc.fillGraceSeconds)
	end

	roundSeed = math.floor(now() * 1000)

	local humansPresent = Participants.countHumans()
	local fillCount = NPCLogic.deriveFillCount(humansPresent, GameConfig.playerCount)
	if not Loader.get("LiveConfig").flags().npcFillEnabled then
		-- P8-5 switch: the round runs short-handed, and a race with fewer
		-- than 3 finishers already has its rule (design-decisions.md §2).
		fillCount = 0
	end

	-- Side by side: each spawn yields on its avatar build, and one after
	-- another would stack five web calls into the Loading window.
	local pending = fillCount
	for index = 1, fillCount do
		task.spawn(function()
			local ok, err = pcall(spawnNPC, index + humansPresent)
			if not ok then
				warn(string.format("NPCService: spawning NPC %d failed - %s", index, tostring(err)))
			end
			pending -= 1
		end)
	end
	while pending > 0 do
		task.wait()
	end

	broadcastRoster()
	-- Deferred: with the grace already served and no seats to fill, this
	-- runs inside Loading's onEnter, before MatchTeleportService has
	-- called Telemetry.roundStarted, and the event would carry no map.
	task.defer(Loader.get("Telemetry").npcCountInRound, Participants.countNPCs(), humansPresent)
	print(
		string.format(
			"NPCService: %d human(s) after a %.0fs grace window - spawned %d NPC(s)",
			humansPresent,
			if graceAlreadyServed then 0 else GameConfig.npc.fillGraceSeconds,
			Participants.countNPCs()
		)
	)
end

-- ===== service ==============================================================

local NPCService: Loader.Service = {
	name = "NPCService",
	dependencies = {
		"NetGuard",
		"ConfigValidator",
		"RoundService",
		"ParticipantService",
		"TaskService",
		"LiveConfig",
		"Telemetry",
	},

	setNavNodes = setNavNodes,
	setSpawnPoints = setSpawnPoints,
	setMapDifficultyModifier = setMapDifficultyModifier,
	debugLoadFromMap = debugLoadFromMap,
	routeBetween = routeBetween,

	markArrivalGraceServed = function()
		graceAlreadyServed = true
	end,

	getNPCSeatCount = function(): number
		return Participants.countNPCs()
	end,

	getNPCIds = function(): { number }
		local ids: { number } = {}
		for id in npcs do
			table.insert(ids, id)
		end
		table.sort(ids)
		return ids
	end,
}

function NPCService:init()
	local RoundService = Loader.get("RoundService") :: any

	-- Bots are spawned during Loading, so they're on the participant
	-- roster before TaskService assigns tasks on Race - which is what
	-- makes them ordinary racers to it rather than late arrivals it
	-- would have to special-case.
	RoundService.onEnter("Loading", function()
		task.spawn(fillSeats)
	end)

	RoundService.onEnter("Race", function()
		startTicking()
	end)

	RoundService.onExit("Race", function()
		stopTicking()
		-- Rigs stay in the world through Qualified/DecisionStudio: an
		-- NPC can qualify (design-decisions.md Q5), and P3-6 gives it
		-- something to say once it's there.
	end)

	RoundService.onEnter("Cleanup", function()
		despawnAll()
		humanDurationSamples = {}
	end)

	local TaskService = Loader.get("TaskService") :: any
	TaskService.onCompletion(function(racerId: number, _stationId: string, taskId: string, durationSeconds: number?)
		-- Only real humans feed the median an NPC is floored against.
		-- Letting bot times in would make the floor drift toward
		-- whatever the bots were already doing, which is a fairness
		-- guarantee that guarantees nothing.
		if durationSeconds == nil or Participants.isNPCId(racerId) then
			return
		end

		local samples = humanDurationSamples[taskId]
		if samples == nil then
			samples = {}
			humanDurationSamples[taskId] = samples
		end
		table.insert(samples, durationSeconds)
	end)
end

return NPCService
