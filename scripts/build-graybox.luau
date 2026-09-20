--!strict
-- Gray-box test map builder (P2-3). Paste this whole file into Studio's
-- Command Bar (or wire a plugin button to the same source) and run it.
-- Builds a map-kit-spec.md-conformant test map under ServerStorage.Maps.
-- GrayBoxTest: every required CollectionService tag and attribute from
-- the spec, correct part counts, a bounded 250x250 arena with two floor
-- levels and ramps. Nothing here is meant to look good or be played -
-- the point is a map service code (RoundService, TaskService,
-- PowerUpService, a future DecisionService) can be pointed at in
-- Studio's "Clients and Servers" test mode, standing in for a real
-- hand-built map until one exists. Keep it ugly, keep it fast.
--
-- NOT SYNCED BY ROJO, ON PURPOSE. CLAUDE.md is explicit that every map,
-- including this one, lives only in the .rbxl under ServerStorage.Maps,
-- never in this repo's src/ tree - default.project.json has no `$path`
-- pointing at `scripts/` for exactly that reason. This file is checked
-- into git for version control and review, but it only ever RUNS pasted
-- into the Command Bar; nothing requires it as a ModuleScript.
--
-- IDEMPOTENT. Deletes and rebuilds ServerStorage.Maps.GrayBoxTest from
-- scratch every run, rather than accumulating a second copy alongside
-- the first - see MAP_NAME below.

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local MAP_NAME = "GrayBoxTest"
local GREY = Color3.fromRGB(128, 128, 128)

-- ===== small generic helpers ================================================

-- One shared appearance for every visible part in this map - "neutral
-- grey, no textures" (the task's own requirement) applies uniformly, so
-- CollectionService tags, not color, are what tells one kind of object
-- from another here. `canTouch` follows the map-kit-spec.md builder's
-- checklist rule directly: "only parts that need to detect a player
-- (kill zones, task station triggers) should have CanTouch = true" -
-- every call site below sets it explicitly rather than defaulting it on.
local function makePart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	parent: Instance,
	canCollide: boolean,
	canTouch: boolean,
	transparency: number?
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.Material = Enum.Material.SmoothPlastic
	part.Color = GREY
	part.CanCollide = canCollide
	part.CanTouch = canTouch
	part.CanQuery = true
	part.Transparency = transparency or 0
	part.Parent = parent
	return part
end

-- A ramp is just a part whose long (Z) axis points from `bottom` at
-- `top` - CFrame.lookAt(center, top) already builds exactly that
-- rotation, so there's no manual incline trigonometry to get wrong.
local function makeRamp(
	name: string,
	bottom: Vector3,
	top: Vector3,
	width: number,
	thickness: number,
	parent: Instance
): BasePart
	local center = bottom:Lerp(top, 0.5)
	local length = (top - bottom).Magnitude
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(width, thickness, length)
	part.CFrame = CFrame.lookAt(center, top)
	part.Anchored = true
	part.Material = Enum.Material.SmoothPlastic
	part.Color = GREY
	part.CanCollide = true
	part.CanTouch = false
	part.CanQuery = true
	part.Parent = parent
	return part
end

local function tagWith(instance: Instance, tag: string, attributes: { [string]: any }?)
	CollectionService:AddTag(instance, tag)
	if attributes ~= nil then
		for key, value in attributes do
			instance:SetAttribute(key, value)
		end
	end
end

local function getOrCreateFolder(parent: Instance, name: string): Instance
	local existingFolder = parent:FindFirstChild(name)
	if existingFolder ~= nil then
		return existingFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Evenly spaced points on an X/Z grid, at a fixed height. `columns` or
-- `rows` of 1 centers that single row/column instead of dividing by
-- zero - used for every station/pad/spawn layout below, so the layout
-- is mechanical (fixed spec -> fixed geometry) rather than hand-placed.
local function grid(
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	columns: number,
	rows: number,
	y: number
): { Vector3 }
	local points: { Vector3 } = {}
	for row = 0, rows - 1 do
		local z = if rows == 1 then (minZ + maxZ) / 2 else minZ + (maxZ - minZ) * (row / (rows - 1))
		for col = 0, columns - 1 do
			local x = if columns == 1 then (minX + maxX) / 2 else minX + (maxX - minX) * (col / (columns - 1))
			table.insert(points, Vector3.new(x, y, z))
		end
	end
	return points
end

-- ===== idempotent root =======================================================

local mapsFolder = getOrCreateFolder(ServerStorage, "Maps")

local existing = mapsFolder:FindFirstChild(MAP_NAME)
if existing ~= nil then
	existing:Destroy()
end

local mapModel = Instance.new("Model")
mapModel.Name = MAP_NAME
mapModel.Parent = mapsFolder

-- ===== arena shell: two floor levels, ramps, perimeter + a few internal walls ==

local WALL_HEIGHT = 24
local WALL_THICKNESS = 2

local lowerFloor = makePart("FloorLower", Vector3.new(250, 4, 250), CFrame.new(0, -2, 0), mapModel, true, false)

-- The mezzanine: a smaller elevated floor along the east edge, reached
-- by two ramps - "two floor levels connected by ramps" (the task's own
-- requirement). Kept clear of the lower-floor task/power-up grid below
-- (that grid stays at x <= 10, the ramps span x 35-65, the mezzanine
-- starts at x = 65), so nothing built on the lower floor ever sits
-- underneath the platform above it.
local upperFloor = makePart("FloorUpper", Vector3.new(50, 4, 110), CFrame.new(90, 18, 0), mapModel, true, false)

local RAMP_NORTH_BOTTOM, RAMP_NORTH_TOP = Vector3.new(35, 0, -35), Vector3.new(65, 20, -35)
local RAMP_SOUTH_BOTTOM, RAMP_SOUTH_TOP = Vector3.new(35, 0, 35), Vector3.new(65, 20, 35)
makeRamp("RampNorth", RAMP_NORTH_BOTTOM, RAMP_NORTH_TOP, 12, 2, mapModel)
makeRamp("RampSouth", RAMP_SOUTH_BOTTOM, RAMP_SOUTH_TOP, 12, 2, mapModel)

makePart(
	"WallNorth",
	Vector3.new(254, WALL_HEIGHT, WALL_THICKNESS),
	CFrame.new(0, WALL_HEIGHT / 2, 125),
	mapModel,
	true,
	false
)
makePart(
	"WallSouth",
	Vector3.new(254, WALL_HEIGHT, WALL_THICKNESS),
	CFrame.new(0, WALL_HEIGHT / 2, -125),
	mapModel,
	true,
	false
)
makePart(
	"WallEast",
	Vector3.new(WALL_THICKNESS, WALL_HEIGHT, 254),
	CFrame.new(125, WALL_HEIGHT / 2, 0),
	mapModel,
	true,
	false
)
makePart(
	"WallWest",
	Vector3.new(WALL_THICKNESS, WALL_HEIGHT, 254),
	CFrame.new(-125, WALL_HEIGHT / 2, 0),
	mapModel,
	true,
	false
)

-- "A few internal walls" - short cover pieces on the lower floor, none
-- long enough to fully wall off a path. This is a gray box for testing
-- code against, not a real level-design pass.
makePart("InternalWallA", Vector3.new(2, 10, 30), CFrame.new(-40, 5, -30), mapModel, true, false)
makePart("InternalWallB", Vector3.new(2, 10, 30), CFrame.new(0, 5, 40), mapModel, true, false)
makePart("InternalWallC", Vector3.new(30, 10, 2), CFrame.new(-60, 5, 0), mapModel, true, false)

-- ===== out-of-bounds volume + kill zone ======================================

local playableBounds =
	makePart("PlayableBounds", Vector3.new(258, 80, 258), CFrame.new(0, 18, 0), mapModel, false, false, 1)
tagWith(playableBounds, "PlayableBounds")

-- CanTouch = true here (unlike every other marker above) - "a volume
-- that returns a fallen player to safety" only works if it can actually
-- detect the player falling through it. Spans well past the arena
-- footprint so nothing can fall past its edges rather than through it.
local killZone = makePart("KillZoneFloor", Vector3.new(400, 10, 400), CFrame.new(0, -60, 0), mapModel, false, true, 1)
tagWith(killZone, "KillZone")

-- ===== spawn points (6, map-kit-spec.md exact) ===============================

local SPAWN_Z = -105
local SPAWN_Y = 1

for index, position in grid(-100, 100, SPAWN_Z, SPAWN_Z, 6, 1, SPAWN_Y) do
	local part = makePart(
		string.format("SpawnPoint_%d", index),
		Vector3.new(4, 0.2, 4),
		CFrame.new(position),
		mapModel,
		false,
		false,
		0.5
	)
	tagWith(part, "SpawnPoint", { SpawnIndex = index })
end

-- ===== task stations (12: 8 lower floor, 4 mezzanine) ========================

-- Both real task ids in tasks-catalogue.md today (see src/shared/Config/
-- Tasks/) - every station accepts either, so TaskService always has a
-- valid roll here regardless of how many more tasks exist by the time
-- this map is actually used.
local ACCEPTED_TASK_IDS = "pressure-valve,vent-purge"

local taskStationPositions: { Vector3 } = {}
for _, position in grid(-100, 0, -60, 30, 4, 2, 3) do
	table.insert(taskStationPositions, position)
end
for _, position in grid(75, 105, -25, 25, 2, 2, 23) do
	table.insert(taskStationPositions, position)
end

local stationParts: { BasePart } = {}
for index, position in taskStationPositions do
	local part = makePart(
		string.format("TaskStation_%02d", index),
		Vector3.new(3, 3, 3),
		CFrame.new(position),
		mapModel,
		false,
		true
	)
	tagWith(part, "TaskStation", {
		StationId = string.format("station-%02d", index),
		AcceptedTaskIds = ACCEPTED_TASK_IDS,
	})
	table.insert(stationParts, part)
end

-- ===== power-up spawns (8: 6 lower floor, 2 mezzanine) =======================

local powerUpPositions: { Vector3 } = {}
for _, position in grid(-110, 10, -90, 80, 3, 2, 2) do
	table.insert(powerUpPositions, position)
end
for _, position in grid(90, 90, -40, 40, 1, 2, 23) do
	table.insert(powerUpPositions, position)
end

-- Common/Uncommon/Rare, roughly weighted toward Common - matches
-- powerups.md's rarity split at a small scale (4/3/1 across 8 pads).
local RARITY_BY_INDEX: { string } =
	{ "Common", "Common", "Common", "Common", "Uncommon", "Uncommon", "Uncommon", "Rare" }

local powerUpParts: { BasePart } = {}
for index, position in powerUpPositions do
	local part = makePart(
		string.format("PowerUpSpawn_%02d", index),
		Vector3.new(2, 2, 2),
		CFrame.new(position),
		mapModel,
		false,
		true
	)
	tagWith(part, "PowerUpSpawn", {
		Rarity = RARITY_BY_INDEX[index],
		AllowedPowerUpIds = "",
	})
	table.insert(powerUpParts, part)
end

-- ===== nav node graph =========================================================
--
-- One NavNode at (just above) every TaskStation and PowerUpSpawn -
-- trivially satisfies "every TaskStation and PowerUpSpawn must have at
-- least one NavNode within reasonable walking proximity" - plus a spawn-
-- area hub and a bottom/top pair on RampNorth so the graph actually
-- crosses between floors. 12 + 8 + 1 + 2 = 23 nodes, inside map-kit-
-- spec.md's "~1.5-2x the TaskStation count" guidance band (18-24).
--
-- CONNECTIVITY: every node below is appended to `navChain` in a single
-- fixed sequence, and `connectChain` links each node only to its
-- immediate predecessor/successor in that sequence. A chain (a path
-- graph) is a connected graph by construction - there is no way for this
-- to produce an orphaned node, which is what map-kit-spec.md actually
-- requires ("a single connected component - no orphaned nodes"). A real
-- hand-built map should wire NavNode edges by actual walkable proximity
-- for NPCs to path well; this generator only has to satisfy the
-- contract for code-testing purposes, so the simpler guaranteed-correct
-- construction wins here.

local function makeNavNode(id: string, position: Vector3, parent: BasePart): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = string.format("NavNode_%s", id)
	attachment.Parent = parent
	attachment.WorldPosition = position
	tagWith(attachment, "NavNode", { NodeId = id })
	return attachment
end

type ChainNode = { id: string, attachment: Attachment }

local navChain: { ChainNode } = {}
local function appendNode(id: string, position: Vector3, parent: BasePart)
	table.insert(navChain, { id = id, attachment = makeNavNode(id, position, parent) })
end

local ABOVE = Vector3.new(0, 2, 0)

appendNode("nav-spawn-hub", Vector3.new(0, SPAWN_Y + 2, SPAWN_Z), lowerFloor)
for i = 1, 8 do
	appendNode(string.format("nav-station-%02d", i), taskStationPositions[i] + ABOVE, stationParts[i])
end
for i = 1, 6 do
	appendNode(string.format("nav-powerup-%02d", i), powerUpPositions[i] + ABOVE, powerUpParts[i])
end
appendNode("nav-ramp-bottom", RAMP_NORTH_BOTTOM + ABOVE, lowerFloor)
appendNode("nav-ramp-top", RAMP_NORTH_TOP + ABOVE, upperFloor)
for i = 9, 12 do
	appendNode(string.format("nav-station-%02d", i), taskStationPositions[i] + ABOVE, stationParts[i])
end
for i = 7, 8 do
	appendNode(string.format("nav-powerup-%02d", i), powerUpPositions[i] + ABOVE, powerUpParts[i])
end

for index, node in navChain do
	local neighborIds: { string } = {}
	local previous = navChain[index - 1]
	local nextNode = navChain[index + 1]
	if previous ~= nil then
		table.insert(neighborIds, previous.id)
	end
	if nextNode ~= nil then
		table.insert(neighborIds, nextNode.id)
	end
	node.attachment:SetAttribute("ConnectedNodeIds", table.concat(neighborIds, ","))
end

-- ===== Decision Studio hand-off marker ========================================
--
-- Clear of the race arena (arena's own east wall sits at x = 125) so a
-- teleport into the Studio never has to worry about race geometry.

local STUDIO_ORIGIN = Vector3.new(220, 1, 0)
local STUDIO_RADIUS = 18

local studioAnchor =
	makePart("StudioAnchor", Vector3.new(4, 0.2, 4), CFrame.new(STUDIO_ORIGIN), mapModel, false, false, 0.5)
tagWith(studioAnchor, "StudioAnchor")

local PODIUM_OFFSETS: { Vector3 } = { Vector3.new(-10, 0, 0), Vector3.new(0, 0, 0), Vector3.new(10, 0, 0) }
for index, offset in PODIUM_OFFSETS do
	local part = makePart(
		string.format("StudioPodiumSlot_%d", index),
		Vector3.new(3, 0.2, 3),
		CFrame.new(STUDIO_ORIGIN + offset),
		mapModel,
		false,
		false,
		0.5
	)
	tagWith(part, "StudioPodiumSlot", { SlotIndex = index })
end

-- Radius is the authoritative boundary shape (map-kit-spec.md: "the
-- boundary check uses this rather than inferring a shape from the
-- part's mesh") - the part itself is just a flat marker, same as every
-- other marker in this file, deliberately not shaped like a circle.
local boundary = makePart(
	"StudioBoundary",
	Vector3.new(2 * STUDIO_RADIUS, 0.2, 2 * STUDIO_RADIUS),
	CFrame.new(STUDIO_ORIGIN),
	mapModel,
	false,
	false,
	0.8
)
tagWith(boundary, "StudioBoundary", { Radius = STUDIO_RADIUS })

local spectatorArea =
	makePart("StudioSpectatorArea", Vector3.new(60, 0.2, 60), CFrame.new(STUDIO_ORIGIN), mapModel, false, false, 0.9)
tagWith(spectatorArea, "StudioSpectatorArea")

-- ===== build summary + self-check against map-kit-spec.md ====================
--
-- Reads back the actually-built tags/attributes (not this script's own
-- in-memory bookkeeping above) so a future edit to this generator that
-- breaks the contract gets caught here too, not just trusted by
-- construction.

local TAG_REQUIREMENTS: { { tag: string, min: number, max: number? } } = {
	{ tag = "SpawnPoint", min = 6, max = 6 },
	{ tag = "TaskStation", min = 12, max = 24 },
	{ tag = "PowerUpSpawn", min = 8, max = 20 },
	{ tag = "NavNode", min = 1, max = nil },
	{ tag = "PlayableBounds", min = 1, max = 4 },
	{ tag = "KillZone", min = 1, max = nil },
	{ tag = "StudioAnchor", min = 1, max = 1 },
	{ tag = "StudioPodiumSlot", min = 3, max = 3 },
	{ tag = "StudioBoundary", min = 1, max = 1 },
	{ tag = "StudioSpectatorArea", min = 0, max = 1 },
}

local failures: { string } = {}

local function countTagged(tag: string): number
	local count = 0
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsDescendantOf(mapModel) then
			count += 1
		end
	end
	return count
end

print(string.format("=== %s build summary ===", MAP_NAME))
for _, requirement in TAG_REQUIREMENTS do
	local count = countTagged(requirement.tag)
	local inRange = count >= requirement.min and (requirement.max == nil or count <= requirement.max)
	local maxLabel = if requirement.max ~= nil then tostring(requirement.max) else "inf"
	print(
		string.format(
			"  %-20s %d  (expected %d..%s)%s",
			requirement.tag,
			count,
			requirement.min,
			maxLabel,
			if inRange then "" else "  <-- OUT OF RANGE"
		)
	)
	if not inRange then
		table.insert(
			failures,
			string.format("%s: got %d, expected %d..%s", requirement.tag, count, requirement.min, maxLabel)
		)
	end
end

-- NavNode graph connectivity, read back from the real attributes rather
-- than `navChain` above.
local adjacency: { [string]: { string } } = {}
for _, attachment in CollectionService:GetTagged("NavNode") do
	if not attachment:IsDescendantOf(mapModel) then
		continue
	end
	local nodeId = attachment:GetAttribute("NodeId") :: string?
	local connectedIds = attachment:GetAttribute("ConnectedNodeIds") :: string?
	if nodeId == nil then
		continue
	end
	adjacency[nodeId] = if connectedIds ~= nil and connectedIds ~= "" then string.split(connectedIds, ",") else {}
end

local allNodeIds: { string } = {}
for nodeId in adjacency do
	table.insert(allNodeIds, nodeId)
end

if #allNodeIds > 0 then
	local visited: { [string]: boolean } = { [allNodeIds[1]] = true }
	local queue: { string } = { allNodeIds[1] }
	local head = 1
	while head <= #queue do
		local currentId = queue[head]
		head += 1
		local neighbors = adjacency[currentId]
		if neighbors ~= nil then
			for _, neighborId in neighbors do
				if not visited[neighborId] then
					visited[neighborId] = true
					table.insert(queue, neighborId)
				end
			end
		end
	end

	local orphaned: { string } = {}
	for _, nodeId in allNodeIds do
		if not visited[nodeId] then
			table.insert(orphaned, nodeId)
		end
	end

	if #orphaned > 0 then
		print(string.format("  NavNode graph        NOT CONNECTED - %d orphaned node(s)", #orphaned))
		table.insert(failures, string.format("NavNode graph has orphaned node(s): %s", table.concat(orphaned, ", ")))
	else
		print(string.format("  NavNode graph        connected (%d nodes)", #allNodeIds))
	end
end

-- Proximity: every TaskStation/PowerUpSpawn must have a NavNode nearby.
local NAV_PROXIMITY_STUDS = 15

local navPositions: { Vector3 } = {}
for _, attachment in CollectionService:GetTagged("NavNode") do
	if attachment:IsDescendantOf(mapModel) and attachment:IsA("Attachment") then
		table.insert(navPositions, attachment.WorldPosition)
	end
end

local function hasNearbyNavNode(position: Vector3): boolean
	for _, navPosition in navPositions do
		if (navPosition - position).Magnitude <= NAV_PROXIMITY_STUDS then
			return true
		end
	end
	return false
end

for _, tag in { "TaskStation", "PowerUpSpawn" } do
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsDescendantOf(mapModel) and instance:IsA("BasePart") then
			local part = instance :: BasePart
			if not hasNearbyNavNode(part.Position) then
				table.insert(
					failures,
					string.format("%s %q has no NavNode within %d studs", tag, part.Name, NAV_PROXIMITY_STUDS)
				)
			end
		end
	end
end

print("")
if #failures == 0 then
	print("All map-kit-spec.md requirements satisfied.")
else
	warn(string.format("%d map-kit-spec.md requirement(s) NOT satisfied:", #failures))
	for _, message in failures do
		warn("  - " .. message)
	end
end
