--!strict
-- Gray-box Decision Studio set builder (P3-4). Paste into Studio's
-- Command Bar (or a plugin button wired to the same source) and run.
-- Builds a map-kit-spec.md-conformant Decision Studio set under
-- ServerStorage.Maps.GrayBoxTest.DecisionStudio - a small enclosed room,
-- three podiums, camera framing, a spotlight rig, a spectator backdrop,
-- and player entry points - the same "validate code against, not a map
-- anyone plays" spirit as P2-3's scripts/build-graybox.luau, applied to
-- the Studio instead of the race arena.
--
-- SUPERSEDES build-graybox.luau's OWN PLACEHOLDER STUDIO MARKERS. P2-3's
-- script already tags a minimal StudioAnchor/StudioPodiumSlot x3/
-- StudioBoundary/StudioSpectatorArea (flat pads, no real geometry) so
-- the race-to-Studio hand-off contract exists at all before this task
-- was reached. map-kit-spec.md requires EXACT counts for three of those
-- four tags (StudioAnchor: 1, StudioPodiumSlot: 3, StudioBoundary: 1) -
-- building a second, independent set alongside the first would break
-- that invariant, not satisfy it twice. This script's idempotent root
-- handling below destroys any existing instances of all four tags under
-- the map first, then builds its own complete replacement - whichever
-- of the two scripts ran most recently is what the map actually has.
--
-- NOT SYNCED BY ROJO, ON PURPOSE - same reasoning as build-graybox.luau:
-- CLAUDE.md is explicit that every map (the Decision Studio included)
-- lives only in the .rbxl, never in this repo's src/ tree.
--
-- IDEMPOTENT: deletes and rebuilds ONLY its own "DecisionStudio" child
-- model under ServerStorage.Maps.GrayBoxTest - never touches
-- GrayBoxTest's own race-arena content (build-graybox.luau's job),
-- creating the GrayBoxTest map model itself if it doesn't exist yet, so
-- this script is runnable standalone even before build-graybox.luau
-- ever has been.

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MAP_NAME = "GrayBoxTest"
local STUDIO_MODEL_NAME = "DecisionStudio"
local GREY = Color3.fromRGB(128, 128, 128)

-- The whole set sits at the same origin build-graybox.luau's own
-- placeholder studio markers used, so this script's output replaces
-- them in place rather than relocating the race-to-Studio hand-off
-- point somewhere new.
local STUDIO_ORIGIN = Vector3.new(220, 1, 0)

-- Podium triangle radius: how far each podium sits from the shared
-- center. Chosen so adjacent podiums end up ~17.3 studs apart
-- (equilateral triangle, side length = radius * sqrt(3)) - comfortably
-- inside GameConfig.decisionStudioChatRangeStuds (30 studs, P3-3's own
-- proximity-chat/voice range) with real headroom for imprecise standing
-- positions, while still being a genuine face-to-face conversational
-- distance, not a shout across a room. See the self-check at the bottom
-- of this script for a live comparison against the real configured
-- value.
local PODIUM_RADIUS_STUDS = 10

-- ===== small generic helpers (mirrors build-graybox.luau's own) ============

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

-- ===== idempotent root =======================================================

local mapsFolder = getOrCreateFolder(ServerStorage, "Maps")

local mapModel = mapsFolder:FindFirstChild(MAP_NAME)
if mapModel == nil then
	local model = Instance.new("Model")
	model.Name = MAP_NAME
	model.Parent = mapsFolder
	mapModel = model
end
local mapModelRef = mapModel :: Instance

-- Supersede build-graybox.luau's own placeholder studio markers - see
-- this file's own header comment. Only these four tags, only under this
-- specific map, are ever touched here.
for _, tag in { "StudioAnchor", "StudioPodiumSlot", "StudioBoundary", "StudioSpectatorArea" } do
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsDescendantOf(mapModelRef) then
			instance:Destroy()
		end
	end
end

local existingStudio = mapModelRef:FindFirstChild(STUDIO_MODEL_NAME)
if existingStudio ~= nil then
	existingStudio:Destroy()
end

local studioModel = Instance.new("Model")
studioModel.Name = STUDIO_MODEL_NAME
studioModel.Parent = mapModelRef

-- ===== room shell =============================================================

local ROOM_RADIUS_STUDS = 25 -- comfortably contains the podium triangle, the spectator ring, and the entry area
local ROOM_WALL_HEIGHT = 20
local ROOM_WALL_THICKNESS = 2

makePart(
	"StudioFloor",
	Vector3.new(ROOM_RADIUS_STUDS * 2, 2, ROOM_RADIUS_STUDS * 2),
	CFrame.new(STUDIO_ORIGIN - Vector3.new(0, 1, 0)),
	studioModel,
	true,
	false
)

-- A simple octagonal-ish enclosure (8 straight wall segments) rather
-- than a true cylinder - easier to reason about and just as enclosed for
-- a gray-box set nobody actually plays in.
local WALL_SIDES = 8
for i = 0, WALL_SIDES - 1 do
	local angle = (i / WALL_SIDES) * math.pi * 2
	local nextAngle = ((i + 1) / WALL_SIDES) * math.pi * 2
	local a = STUDIO_ORIGIN + Vector3.new(math.cos(angle), 0, math.sin(angle)) * ROOM_RADIUS_STUDS
	local b = STUDIO_ORIGIN + Vector3.new(math.cos(nextAngle), 0, math.sin(nextAngle)) * ROOM_RADIUS_STUDS
	local center = a:Lerp(b, 0.5) + Vector3.new(0, ROOM_WALL_HEIGHT / 2, 0)
	local length = (b - a).Magnitude

	local wall = Instance.new("Part")
	wall.Name = string.format("StudioWall_%d", i + 1)
	wall.Size = Vector3.new(length + 1, ROOM_WALL_HEIGHT, ROOM_WALL_THICKNESS)
	wall.CFrame = CFrame.lookAt(center, center + (b - a))
	wall.Anchored = true
	wall.Material = Enum.Material.SmoothPlastic
	wall.Color = GREY
	wall.CanCollide = true
	wall.CanTouch = false
	wall.CanQuery = true
	wall.Parent = studioModel
end

-- ===== podiums, in a triangle facing the shared center ======================

local PODIUM_ANGLES = { math.rad(90), math.rad(210), math.rad(330) } -- one facing the entry side, two flanking

local podiumPositions: { Vector3 } = {}
for index, angle in PODIUM_ANGLES do
	local position = STUDIO_ORIGIN + Vector3.new(math.cos(angle), 0, math.sin(angle)) * PODIUM_RADIUS_STUDS
	table.insert(podiumPositions, position)

	local podium = makePart(
		string.format("StudioPodium_%d", index),
		Vector3.new(4, 3, 4),
		CFrame.lookAt(position, STUDIO_ORIGIN) * CFrame.new(0, 1.5, 0),
		studioModel,
		true,
		false
	)
	tagWith(podium, "StudioPodiumSlot", { SlotIndex = index })

	-- One spotlight per podium, mounted on a small fixture directly
	-- above it, pointed straight down.
	local fixture = makePart(
		string.format("StudioSpotlightFixture_%d", index),
		Vector3.new(1, 1, 1),
		CFrame.new(position + Vector3.new(0, 14, 0)),
		studioModel,
		false,
		false,
		1
	)
	tagWith(fixture, "StudioSpotlight")

	local spotlight = Instance.new("SpotLight")
	spotlight.Name = "Spotlight"
	spotlight.Face = Enum.NormalId.Bottom
	spotlight.Range = 20
	spotlight.Angle = 60
	spotlight.Brightness = 3
	spotlight.Parent = fixture
end

local studioAnchor =
	makePart("StudioAnchor", Vector3.new(4, 0.2, 4), CFrame.new(STUDIO_ORIGIN), studioModel, false, false, 0.5)
tagWith(studioAnchor, "StudioAnchor")

local STUDIO_BOUNDARY_RADIUS = PODIUM_RADIUS_STUDS + 5 -- comfortably contains all 3 podiums, within map-kit-spec.md's 8-30 range
local boundary = makePart(
	"StudioBoundary",
	Vector3.new(STUDIO_BOUNDARY_RADIUS * 2, 0.2, STUDIO_BOUNDARY_RADIUS * 2),
	CFrame.new(STUDIO_ORIGIN),
	studioModel,
	false,
	false,
	0.8
)
tagWith(boundary, "StudioBoundary", { Radius = STUDIO_BOUNDARY_RADIUS })

local spectatorArea = makePart(
	"StudioSpectatorArea",
	Vector3.new(ROOM_RADIUS_STUDS * 1.8, 0.2, ROOM_RADIUS_STUDS * 1.8),
	CFrame.new(STUDIO_ORIGIN),
	studioModel,
	false,
	false,
	0.9
)
tagWith(spectatorArea, "StudioSpectatorArea")

-- ===== camera framing =========================================================

-- One personal-view camera per podium, positioned on the OPPOSITE side
-- of the shared center from its own podium (so it looks back across the
-- circle at the podium's occupant, catching their face rather than the
-- back of their head), elevated slightly for a flattering angle.
for index, angle in PODIUM_ANGLES do
	local oppositeAngle = angle + math.pi
	local cameraPosition = STUDIO_ORIGIN
		+ Vector3.new(math.cos(oppositeAngle), 0, math.sin(oppositeAngle)) * (PODIUM_RADIUS_STUDS + 6)
		+ Vector3.new(0, 5, 0)

	local camera = makePart(
		string.format("StudioPersonalCamera_%d", index),
		Vector3.new(1, 1, 1),
		CFrame.lookAt(cameraPosition, podiumPositions[index] + Vector3.new(0, 4, 0)),
		studioModel,
		false,
		false,
		1
	)
	tagWith(camera, "StudioPersonalCamera", { PodiumIndex = index })
end

-- One wide shot for the reveal - elevated well above the whole triangle,
-- looking straight down at its center.
local wideCamera = makePart(
	"StudioWideCamera",
	Vector3.new(1, 1, 1),
	CFrame.lookAt(STUDIO_ORIGIN + Vector3.new(0, 22, 0), STUDIO_ORIGIN),
	studioModel,
	false,
	false,
	1
)
tagWith(wideCamera, "StudioWideCamera")

-- ===== spectator-facing backdrop =============================================

-- A tall panel on the far side of the podium triangle from the entry/
-- spectator side, so a spectator looking toward the podiums sees this
-- behind the finalists rather than a bare wall.
local backdropAngle = math.rad(90) -- opposite the entry side, defined below
local backdropPosition = STUDIO_ORIGIN
	+ Vector3.new(math.cos(backdropAngle), 0, math.sin(backdropAngle)) * (ROOM_RADIUS_STUDS - 1)
local backdrop = makePart(
	"StudioBackdrop",
	Vector3.new(20, 14, 1),
	CFrame.lookAt(backdropPosition + Vector3.new(0, 7, 0), STUDIO_ORIGIN),
	studioModel,
	false,
	false
)
tagWith(backdrop, "StudioBackdrop")

-- ===== player entry positions =================================================

-- Six entry points (design-decisions.md Q3: "all finalists teleport into
-- the Studio together," up to 6) along the room's entry side, opposite
-- the backdrop.
local ENTRY_SIDE_ANGLE = math.rad(270)
local entryCenter = STUDIO_ORIGIN
	+ Vector3.new(math.cos(ENTRY_SIDE_ANGLE), 0, math.sin(ENTRY_SIDE_ANGLE)) * (ROOM_RADIUS_STUDS - 4)
local entryRight = Vector3.new(math.cos(ENTRY_SIDE_ANGLE + math.pi / 2), 0, math.sin(ENTRY_SIDE_ANGLE + math.pi / 2))

for index = 1, 6 do
	local offset = (index - 3.5) * 3 -- spaces 6 points 3 studs apart, centered on entryCenter
	local position = entryCenter + entryRight * offset

	local entryPoint = makePart(
		string.format("StudioEntryPoint_%d", index),
		Vector3.new(2.5, 0.2, 2.5),
		CFrame.new(position),
		studioModel,
		false,
		false,
		0.5
	)
	tagWith(entryPoint, "StudioEntryPoint", { EntryIndex = index })
end

-- ===== build summary + self-check ============================================

local TAG_REQUIREMENTS: { { tag: string, min: number, max: number? } } = {
	{ tag = "StudioAnchor", min = 1, max = 1 },
	{ tag = "StudioPodiumSlot", min = 3, max = 3 },
	{ tag = "StudioBoundary", min = 1, max = 1 },
	{ tag = "StudioSpectatorArea", min = 0, max = 1 },
	{ tag = "StudioPersonalCamera", min = 3, max = 3 },
	{ tag = "StudioWideCamera", min = 1, max = 1 },
	{ tag = "StudioEntryPoint", min = 6, max = 6 },
}

local failures: { string } = {}

local function countTagged(tag: string): number
	local count = 0
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsDescendantOf(studioModel) then
			count += 1
		end
	end
	return count
end

print(string.format("=== %s.%s build summary ===", MAP_NAME, STUDIO_MODEL_NAME))
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

-- Live check against the real configured chat/voice range, not just the
-- hard-coded reasoning in this script's own comments - if GameConfig.
-- decisionStudioChatRangeStuds is ever tuned down below what this
-- layout needs, this catches it instead of silently drifting stale.
local adjacentPodiumDistance = PODIUM_RADIUS_STUDS * math.sqrt(3)
print(
	string.format(
		"  Podium spacing: radius %d studs -> ~%.1f studs between adjacent podiums",
		PODIUM_RADIUS_STUDS,
		adjacentPodiumDistance
	)
)

local configOk, configResult = pcall(function()
	return (require(ReplicatedStorage.Shared.Config.GameConfig) :: any).decisionStudioChatRangeStuds
end)
if configOk and type(configResult) == "number" then
	print(string.format("  GameConfig.decisionStudioChatRangeStuds: %d studs", configResult))
	if adjacentPodiumDistance > configResult then
		table.insert(
			failures,
			string.format(
				"podium spacing (%.1f studs) exceeds GameConfig.decisionStudioChatRangeStuds (%d studs) - move podiums closer",
				adjacentPodiumDistance,
				configResult
			)
		)
	end
else
	warn(
		"  Could not read GameConfig.decisionStudioChatRangeStuds (is ReplicatedStorage.Shared synced?) - skipping the live spacing check"
	)
end

print("")
if #failures == 0 then
	print("All map-kit-spec.md requirements satisfied.")
else
	warn(string.format("%d requirement(s) NOT satisfied:", #failures))
	for _, message in failures do
		warn("  - " .. message)
	end
end
