--!strict
-- Gray-box hub world builder (P5-4). Paste this whole file into Studio's
-- Command Bar in the HUB place (never the match place) and run it.
-- Builds Workspace.Hub: spawn plaza, queue pad + countdown display, map
-- vote board wall, store front with three podiums, a leaderboard wall
-- with daily/weekly/all-time surfaces, and a practice area - every piece
-- tagged per docs/hub-spec.md, then validated and measured.
--
-- NOT SYNCED BY ROJO, ON PURPOSE - same reasoning as build-graybox.luau:
-- world geometry lives in the .rbxl, this repo only versions the script.
-- Unlike the race maps, the hub is a place's own world, not a clonable
-- ServerStorage.Maps entry, so it builds straight into Workspace.
--
-- IDEMPOTENT. Destroys and rebuilds Workspace.Hub every run. Nothing
-- outside that model is touched - stray SpawnLocations elsewhere (the
-- template's default one, say) are reported, not deleted, because they
-- may be somebody's hand-built work.
--
-- LAYOUT READS FROM SPAWN. The player spawns facing -Z, straight at the
-- queue pad, with the back wall (vote board | countdown | leaderboards)
-- behind it; the store is off to the left and the practice area to the
-- right, away from the queue pad so practice griefing can't spill onto
-- it (P5-5's no-effect zone). Everything is within one short walk.

local CollectionService = game:GetService("CollectionService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local HUB_NAME = "Hub"
local GREY = Color3.fromRGB(128, 128, 128)
local DARK_GREY = Color3.fromRGB(90, 90, 90)

-- Walk-time budget from the task brief: any zone further than this from
-- spawn gets flagged.
local MAX_WALK_SECONDS = 8

-- Portrait phone, default 70-degree vertical FOV, ~9:19.5 aspect gives a
-- horizontal half-angle of about 18 degrees. The queue pad has to sit
-- inside that without the player turning, so 15 leaves a margin.
local QUEUE_MAX_ANGLE_DEGREES = 15

-- Standing eye height above the floor, for the line-of-sight ray.
local EYE_HEIGHT = 5

-- ===== layout (studs; floor top is Y = 0) ====================================

local SPAWN_POSITION = Vector3.new(0, 0, 10)
local QUEUE_POSITION = Vector3.new(0, 0, -60)
local BACK_WALL_Z = -92

-- One approach point per zone: where a player stands to use it. Walk
-- times are measured to these, and each zone model carries its own as an
-- `ApproachPoint` attribute for later wayfinding (arrows, tutorial).
local ZONES: { { id: string, approach: Vector3 } } = {
	{ id = "SpawnPlaza", approach = SPAWN_POSITION },
	{ id = "QueuePad", approach = Vector3.new(0, 0, -46) },
	{ id = "VoteBoard", approach = Vector3.new(-50, 0, -78) },
	{ id = "StoreFront", approach = Vector3.new(-42, 0, -20) },
	{ id = "Leaderboards", approach = Vector3.new(52, 0, -78) },
	{ id = "PracticeArea", approach = Vector3.new(40, 0, -12) },
}

-- ===== small generic helpers ================================================

local function makePart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	parent: Instance,
	canCollide: boolean,
	canTouch: boolean,
	transparency: number?
): Part
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

-- Invisible, non-colliding volume. CanQuery is off so it never eats
-- camera or click raycasts; consumers test containment against its
-- CFrame and Size (or use it as the shape for GetPartsInPart).
local function makeVolume(name: string, size: Vector3, cframe: CFrame, parent: Instance): BasePart
	local part = makePart(name, size, cframe, parent, false, false, 1)
	part.CanQuery = false
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

-- Upright part at `position` whose Front face looks at `target` on the
-- horizontal plane - walls and boards face the player, never tilt.
local function facing(position: Vector3, target: Vector3): CFrame
	return CFrame.lookAt(position, Vector3.new(target.X, position.Y, target.Z))
end

-- Placeholder text on a part's Front face, so gray-box signage reads in
-- a playtest. Client UI code replaces or drives it later.
local function label(part: BasePart, text: string)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Display"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "Text"
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.TextScaled = true
	textLabel.TextColor3 = Color3.new(1, 1, 1)
	textLabel.Text = text
	textLabel.Parent = gui
	gui.Parent = part
end

local zoneModels: { [string]: Model } = {}
local function zoneModel(id: string): Model
	return zoneModels[id]
end

-- ===== idempotent root =======================================================

local existing = Workspace:FindFirstChild(HUB_NAME)
if existing ~= nil then
	existing:Destroy()
end

local hub = Instance.new("Model")
hub.Name = HUB_NAME
hub.Parent = Workspace

for _, zone in ZONES do
	local model = Instance.new("Model")
	model.Name = zone.id
	model.Parent = hub
	tagWith(model, "HubZone", { ZoneId = zone.id, ApproachPoint = zone.approach })
	zoneModels[zone.id] = model
end

-- One floor for the whole hub, with a thin border so the edge is visible.
makePart("Floor", Vector3.new(220, 2, 220), CFrame.new(0, -1, -40), hub, true, false)
for index, spec in
	{
		{ Vector3.new(220, 4, 2), Vector3.new(0, 2, 69) },
		{ Vector3.new(220, 4, 2), Vector3.new(0, 2, -149) },
		{ Vector3.new(2, 4, 220), Vector3.new(109, 2, -40) },
		{ Vector3.new(2, 4, 220), Vector3.new(-109, 2, -40) },
	}
do
	makePart("Edge" .. index, spec[1], CFrame.new(spec[2]), hub, true, false)
end

-- ===== spawn plaza ===========================================================

local spawnPlaza = zoneModel("SpawnPlaza")
makePart(
	"PlazaPad",
	Vector3.new(36, 0.2, 36),
	CFrame.new(SPAWN_POSITION + Vector3.new(0, 0.1, 0)),
	spawnPlaza,
	false,
	false
).Color =
	DARK_GREY

-- Faces the queue pad; the spawned character takes this orientation.
local spawnLocation = Instance.new("SpawnLocation")
spawnLocation.Name = "Spawn"
spawnLocation.Size = Vector3.new(8, 1, 8)
spawnLocation.CFrame = facing(SPAWN_POSITION + Vector3.new(0, 0.5, 0), QUEUE_POSITION)
spawnLocation.Anchored = true
spawnLocation.Neutral = true
spawnLocation.Material = Enum.Material.SmoothPlastic
spawnLocation.Color = GREY
spawnLocation.Parent = spawnPlaza
tagWith(spawnLocation, "HubSpawn")

-- ===== queue pad =============================================================

local queueZone = zoneModel("QueuePad")
local queuePad = makePart(
	"Pad",
	Vector3.new(1, 24, 24),
	CFrame.new(QUEUE_POSITION + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
	queueZone,
	true,
	false
)
queuePad.Shape = Enum.PartType.Cylinder
queuePad.Color = DARK_GREY
tagWith(queuePad, "HubQueuePad")

-- P5-5's griefing guard: no practice effects inside this box.
tagWith(
	makeVolume("NoEffectZone", Vector3.new(44, 20, 44), CFrame.new(QUEUE_POSITION + Vector3.new(0, 10, 0)), queueZone),
	"HubQueueNoEffectZone"
)

-- Raised over the back wall so it reads over the heads of a crowd.
local countdown = makePart(
	"CountdownDisplay",
	Vector3.new(20, 10, 1),
	facing(Vector3.new(0, 18, BACK_WALL_Z), SPAWN_POSITION),
	queueZone,
	true,
	false
)
label(countdown, "0:00")
tagWith(countdown, "HubQueueCountdown")
makePart("CountdownPost", Vector3.new(2, 13, 1), CFrame.new(0, 6.5, BACK_WALL_Z - 1), queueZone, true, false)

-- ===== map vote board wall ===================================================

-- Signage only: each group's live ballot is a per-player overlay
-- (docs/voting.md), since several groups vote at once on one server.
local voteZone = zoneModel("VoteBoard")
local voteBoard = makePart(
	"Board",
	Vector3.new(36, 14, 1),
	facing(Vector3.new(-50, 8, BACK_WALL_Z), Vector3.new(-50, 0, 0)),
	voteZone,
	true,
	false
)
label(voteBoard, "MAP VOTE")
tagWith(voteBoard, "HubVoteBoard")

-- ===== store front ===========================================================

local storeZone = zoneModel("StoreFront")
local storeFacade = makePart("Facade", Vector3.new(1, 16, 40), CFrame.new(-72, 8, -20), storeZone, true, false)
storeFacade.Color = DARK_GREY
local storeSign = makePart(
	"Sign",
	Vector3.new(24, 4, 1),
	facing(Vector3.new(-71, 14, -20), Vector3.new(0, 14, -20)),
	storeZone,
	false,
	false
)
label(storeSign, "STORE")

for slot, z in { -32, -20, -8 } do
	local podium = makePart("Podium" .. slot, Vector3.new(6, 3, 6), CFrame.new(-58, 1.5, z), storeZone, true, false)
	tagWith(podium, "HubStorePodium", { Slot = slot })
end

-- ===== leaderboard wall ======================================================

local boardsZone = zoneModel("Leaderboards")
makePart("Wall", Vector3.new(50, 18, 1), CFrame.new(52, 9, BACK_WALL_Z - 1), boardsZone, true, false).Color = DARK_GREY
for index, period in { "Daily", "Weekly", "AllTime" } do
	local x = 52 + (index - 2) * 16
	local surface = makePart(
		"Board" .. period,
		Vector3.new(14, 14, 0.5),
		facing(Vector3.new(x, 9, BACK_WALL_Z - 0.25), Vector3.new(x, 0, 0)),
		boardsZone,
		true,
		false
	)
	label(surface, string.upper(period))
	tagWith(surface, "HubLeaderboardSurface", { Period = period })
end

-- ===== practice area =========================================================

local PRACTICE_CENTER = Vector3.new(66, 0, -12)
local PRACTICE_HALF = 22

local practiceZone = zoneModel("PracticeArea")
makePart(
	"PracticePad",
	Vector3.new(44, 0.2, 44),
	CFrame.new(PRACTICE_CENTER + Vector3.new(0, 0.1, 0)),
	practiceZone,
	false,
	false
).Color =
	DARK_GREY
tagWith(
	makeVolume(
		"Bounds",
		Vector3.new(PRACTICE_HALF * 2, 20, PRACTICE_HALF * 2),
		CFrame.new(PRACTICE_CENTER + Vector3.new(0, 10, 0)),
		practiceZone
	),
	"HubPracticeArea"
)

-- Soft barriers: knee-high rails a player can hop (default JumpHeight
-- clears 3 studs) but won't wander over by accident. The side facing
-- spawn has a gap in the middle as the obvious way in.
local RAIL_HEIGHT = 3
local railSpecs: { { size: Vector3, offset: Vector3 } } = {
	{ size = Vector3.new(44, RAIL_HEIGHT, 1), offset = Vector3.new(0, 0, -PRACTICE_HALF) },
	{ size = Vector3.new(44, RAIL_HEIGHT, 1), offset = Vector3.new(0, 0, PRACTICE_HALF) },
	{ size = Vector3.new(1, RAIL_HEIGHT, 44), offset = Vector3.new(PRACTICE_HALF, 0, 0) },
	{ size = Vector3.new(1, RAIL_HEIGHT, 16), offset = Vector3.new(-PRACTICE_HALF, 0, -14) },
	{ size = Vector3.new(1, RAIL_HEIGHT, 16), offset = Vector3.new(-PRACTICE_HALF, 0, 14) },
}
for index, rail in railSpecs do
	local part = makePart(
		"Rail" .. index,
		rail.size,
		CFrame.new(PRACTICE_CENTER + rail.offset + Vector3.new(0, RAIL_HEIGHT / 2, 0)),
		practiceZone,
		true,
		false
	)
	tagWith(part, "HubSoftBarrier")
end

for index, offset in
	{
		Vector3.new(-12, 0, -12),
		Vector3.new(12, 0, -12),
		Vector3.new(-12, 0, 12),
		Vector3.new(12, 0, 12),
		Vector3.new(0, 0, 0),
		Vector3.new(14, 0, 0),
	}
do
	local itemSpawn = makePart(
		"ItemSpawn" .. index,
		Vector3.new(3, 0.4, 3),
		CFrame.new(PRACTICE_CENTER + offset + Vector3.new(0, 0.2, 0)),
		practiceZone,
		false,
		true -- detects a player walking over it to pick up
	)
	itemSpawn.Color = DARK_GREY
	tagWith(itemSpawn, "HubPracticeItemSpawn")
end

-- ===== validation ============================================================

local failures: { string } = {}

-- Exact/min/max tag counts from docs/hub-spec.md, counted inside Hub only.
local TAG_COUNTS: { { tag: string, min: number, max: number } } = {
	{ tag = "HubZone", min = 6, max = 6 },
	{ tag = "HubSpawn", min = 1, max = 1 },
	{ tag = "HubQueuePad", min = 1, max = 1 },
	{ tag = "HubQueueNoEffectZone", min = 1, max = 1 },
	{ tag = "HubQueueCountdown", min = 1, max = 1 },
	{ tag = "HubVoteBoard", min = 1, max = 1 },
	{ tag = "HubStorePodium", min = 3, max = 3 },
	{ tag = "HubLeaderboardSurface", min = 3, max = 3 },
	{ tag = "HubPracticeArea", min = 1, max = 1 },
	{ tag = "HubPracticeItemSpawn", min = 4, max = 8 },
	{ tag = "HubSoftBarrier", min = 1, max = math.huge },
}

local counts: { [string]: number } = {}
for _, rule in TAG_COUNTS do
	local count = 0
	for _, instance in CollectionService:GetTagged(rule.tag) do
		if instance:IsDescendantOf(hub) then
			count += 1
		end
	end
	counts[rule.tag] = count
	if count < rule.min or count > rule.max then
		table.insert(
			failures,
			string.format("%s: %d tagged, expected %d-%s", rule.tag, count, rule.min, tostring(rule.max))
		)
	end
end

-- The queue no-effect zone and the practice area must never overlap, or
-- practice effects could land on someone standing on the pad.
local function horizontalOverlap(a: BasePart, b: BasePart): boolean
	local aMin, aMax = a.Position - a.Size / 2, a.Position + a.Size / 2
	local bMin, bMax = b.Position - b.Size / 2, b.Position + b.Size / 2
	return aMin.X < bMax.X and bMin.X < aMax.X and aMin.Z < bMax.Z and bMin.Z < aMax.Z
end
local noEffect = queueZone:FindFirstChild("NoEffectZone") :: BasePart
local practiceBounds = practiceZone:FindFirstChild("Bounds") :: BasePart
if horizontalOverlap(noEffect, practiceBounds) then
	table.insert(failures, "HubQueueNoEffectZone overlaps HubPracticeArea")
end

-- Queue pad in view from spawn without turning: inside the portrait
-- field of view, and nothing solid between the eye and the pad.
local eye = SPAWN_POSITION + Vector3.new(0, EYE_HEIGHT, 0)
local toPad = QUEUE_POSITION - SPAWN_POSITION
local look = spawnLocation.CFrame.LookVector
local flatLook = Vector3.new(look.X, 0, look.Z).Unit
local queueAngle = math.deg(math.acos(math.clamp(flatLook:Dot(Vector3.new(toPad.X, 0, toPad.Z).Unit), -1, 1)))
if queueAngle > QUEUE_MAX_ANGLE_DEGREES then
	table.insert(
		failures,
		string.format("queue pad is %.1f deg off the spawn facing (max %d)", queueAngle, QUEUE_MAX_ANGLE_DEGREES)
	)
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { spawnLocation }
-- Aim at the pad's centre, inside the part, so the ray can't stop just
-- short of its top surface and report a false "clear".
local hit = Workspace:Raycast(eye, queuePad.Position - eye, rayParams)
local sightClear = hit ~= nil and hit.Instance == queuePad
if not sightClear then
	table.insert(
		failures,
		string.format(
			"line of sight from spawn to queue pad blocked by %s",
			if hit ~= nil then hit.Instance:GetFullName() else "nothing (ray missed the pad)"
		)
	)
end

local otherSpawns: { string } = {}
for _, instance in Workspace:GetDescendants() do
	if instance:IsA("SpawnLocation") and not instance:IsDescendantOf(hub) then
		table.insert(otherSpawns, instance:GetFullName())
	end
end

-- ===== summary ===============================================================

print(string.format("Built Workspace.%s (P5-4 gray-box hub).", HUB_NAME))
print("Tag counts:")
for _, rule in TAG_COUNTS do
	print(string.format("  %-22s %d", rule.tag, counts[rule.tag]))
end

-- Straight-line distance at the configured walk speed: a lower bound,
-- which is fine here because the plaza between zones is open floor.
local walkSpeed = StarterPlayer.CharacterWalkSpeed
print(string.format("Walk time from spawn at %g studs/s (budget %ds):", walkSpeed, MAX_WALK_SECONDS))
for _, zone in ZONES do
	if zone.id ~= "SpawnPlaza" then
		local delta = zone.approach - SPAWN_POSITION
		local seconds = Vector3.new(delta.X, 0, delta.Z).Magnitude / walkSpeed
		local over = seconds > MAX_WALK_SECONDS
		print(string.format("  %-13s %4.1fs%s", zone.id, seconds, if over then "  <-- OVER BUDGET" else ""))
		if over then
			table.insert(
				failures,
				string.format("%s is %.1fs from spawn (budget %ds)", zone.id, seconds, MAX_WALK_SECONDS)
			)
		end
	end
end
print(
	string.format(
		"Queue pad: %.1f deg off spawn facing, line of sight %s.",
		queueAngle,
		if sightClear then "clear" else "BLOCKED"
	)
)

if #otherSpawns > 0 then
	warn(string.format("%d SpawnLocation(s) outside Hub - players may spawn there instead:", #otherSpawns))
	for _, name in otherSpawns do
		warn("  - " .. name)
	end
end

print("")
if #failures == 0 then
	print("All docs/hub-spec.md requirements satisfied.")
else
	warn(string.format("%d docs/hub-spec.md requirement(s) NOT satisfied:", #failures))
	for _, message in failures do
		warn("  - " .. message)
	end
end
