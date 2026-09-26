--!strict
-- Builds the shared Decision Studio set from the Blocky Cave place
-- (2026-09-25). Runs under Lune, not Studio:
--
--   lune run scripts/build-decision-studio "<Blocky Cave.rbxl>" "<out DecisionStudio.rbxm>"
--
-- What it does to the cave's BlockyCave model:
--   1. Removes the ramp to the upper level: the six wooden planks and
--      the slate slope beside them. They're unnamed free-model parts,
--      so they're found by position and size (RAMP below), and the
--      script fails rather than guess if any one isn't where expected.
--   2. Adds StudioStage: the StudioAnchor at the centre of the ground
--      next to the waterfall, three StudioPodiumSlot podiums around it
--      (SlotIndex 1-3), and a StudioBoundary (map-kit-spec.md).
--   3. Adds StudioSpectators: six StudioSpectatorSpawn pads on the
--      walkway behind the east fence, and a StudioSpectatorArea box
--      around that walkway. StudioStageService puts anyone who leaves the
--      box - over the fence, off either end - straight back.
--   4. Renames the model DecisionStudio (GameConfig.decisionStudioStage
--      .mapId) and writes it as a model file.
--
-- Then in Studio: right-click ServerStorage.Maps > Insert from File, and
-- pick the .rbxm. The set is authored at the cave's own coordinates;
-- StudioStageService moves it clear of the race map at runtime.
--
-- Everything added is its own model, so it can be nudged by hand in
-- Studio (move StudioStage to move the podium ring as one) without
-- re-running this. Positions were read from the place's geometry, not
-- seen: check them in Studio (docs/decision-studio.md "The set").

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Instance = roblox.Instance
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
local Color3 = roblox.Color3
local Enum = roblox.Enum

local args = table.clone(process.args)
if args[1] == "--" then
	table.remove(args, 1)
end
local inputPath, outputPath = args[1], args[2]
if inputPath == nil or outputPath == nil then
	error('usage: lune run scripts/build-decision-studio "<Blocky Cave.rbxl>" "<out.rbxm>"')
end

local game = roblox.deserializePlace(fs.readFile(inputPath))
local cave = game:GetService("Workspace"):FindFirstChild("BlockyCave")
assert(cave ~= nil and cave:IsA("Model"), "no Workspace.BlockyCave model in " .. inputPath)

-- ===== 1. the ramp ==========================================================

-- Centre and size of every ramp part, as read from the place.
local RAMP: { { position: Vector3, size: Vector3 } } = {
	-- The wooden planks, bottom to top along Z = 8.
	{ position = Vector3.new(36, 21, 8), size = Vector3.new(11, 5, 1) },
	{ position = Vector3.new(44, 24, 8), size = Vector3.new(11, 5, 1) },
	{ position = Vector3.new(53, 27, 8), size = Vector3.new(11, 5, 1) },
	{ position = Vector3.new(61, 29, 8), size = Vector3.new(11, 5, 1) },
	{ position = Vector3.new(70, 32, 8), size = Vector3.new(11, 5, 1) },
	{ position = Vector3.new(78, 35, 8), size = Vector3.new(11, 5, 1) },
	-- The slate slope and the wedge under it.
	{ position = Vector3.new(55, 25, 17), size = Vector3.new(58, 1, 18) },
	{ position = Vector3.new(55, 25, 20), size = Vector3.new(27, 18, 55) },
}
local TOLERANCE = 1

local function matches(part: any, spec: { position: Vector3, size: Vector3 }): boolean
	local p, s = part.CFrame.Position, part.Size
	return (p - spec.position).Magnitude <= TOLERANCE
		and math.abs(s.X - spec.size.X) <= TOLERANCE
		and math.abs(s.Y - spec.size.Y) <= TOLERANCE
		and math.abs(s.Z - spec.size.Z) <= TOLERANCE
end

local removed = 0
for _, spec in RAMP do
	local found = nil
	for _, instance in cave:GetDescendants() do
		if instance:IsA("BasePart") and matches(instance, spec) then
			found = instance
			break
		end
	end
	if found == nil then
		error(string.format("ramp part at %s not found - the place changed; update RAMP", tostring(spec.position)))
	end
	local parent = found.Parent
	found:Destroy()
	removed += 1
	-- The planks came in their own model; don't leave it empty.
	if parent ~= nil and parent ~= cave and parent:IsA("Model") and #parent:GetChildren() == 0 then
		parent:Destroy()
	end
end

-- ===== helpers ==============================================================

local function part(name: string, size: Vector3, cf: any, parent: any, visible: boolean): any
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = visible
	p.CanTouch = false
	p.CanQuery = visible
	p.CastShadow = visible
	p.Transparency = if visible then 0 else 1
	p.Parent = parent
	return p
end

local function model(name: string, parent: any): any
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- ===== 2. the podium ring ===================================================

-- The flat slate floor east of the waterfall's pool (top at Y 16.4,
-- X 14..60, Z -45..-2), clear of the rocks around it.
local FLOOR_Y = 16.4
local CENTRE = Vector3.new(34, FLOOR_Y, -32)
-- 8 studs out: ~14 apart, facing each other well inside
-- GameConfig.decisionStudioChatRangeStuds (30).
local RING_RADIUS = 8
local PODIUM_HEIGHT = 2
local PODIUM_DIAMETER = 6

local stageModel = model("StudioStage", cave)

local anchor =
	part("StudioAnchor", Vector3.new(2, 0.2, 2), CFrame.new(CENTRE + Vector3.new(0, 0.1, 0)), stageModel, false)
anchor:AddTag("StudioAnchor")

local boundary =
	part("StudioBoundary", Vector3.new(1, 0.2, 1), CFrame.new(CENTRE + Vector3.new(0, 0.1, 0)), stageModel, false)
boundary:AddTag("StudioBoundary")
boundary:SetAttribute("Radius", RING_RADIUS + 6)

for index = 1, 3 do
	-- Slot 1 on the far side from the waterfall, then round.
	local angle = math.rad(90 + (index - 1) * 120)
	local at = CENTRE + Vector3.new(math.cos(angle) * RING_RADIUS, PODIUM_HEIGHT / 2, math.sin(angle) * RING_RADIUS)
	-- A Part cylinder's axis is X: turn it upright.
	local podium = part(
		string.format("StudioPodiumSlot_%d", index),
		Vector3.new(PODIUM_HEIGHT, PODIUM_DIAMETER, PODIUM_DIAMETER),
		CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90)),
		stageModel,
		true
	)
	podium.Shape = Enum.PartType.Cylinder
	podium.Material = Enum.Material.Marble
	podium.Color = Color3.fromRGB(226, 220, 205)
	podium:AddTag("StudioPodiumSlot")
	podium:SetAttribute("SlotIndex", index)
end

-- ===== 3. the upper level ===================================================

-- The walkway behind the east fence (the fence runs along X 83): a flat
-- floor at Y 40, X 84..102, Z -60..6, walled beyond X 104. Spectators
-- watch from here, over the fence, and may not cross onto the rocks in
-- front of it (a 2026-09-25 playtest call). Mapped by a height grid over
-- the cave's parts.
local WALK_Y = 40
local LOOKOUTS = {
	Vector3.new(88, WALK_Y, -45),
	Vector3.new(88, WALK_Y, -30),
	Vector3.new(88, WALK_Y, -15),
	Vector3.new(95, WALK_Y, -45),
	Vector3.new(95, WALK_Y, -30),
	Vector3.new(95, WALK_Y, -15),
}

local spectatorsModel = model("StudioSpectators", cave)
for index, at in LOOKOUTS do
	local pad = part(
		string.format("StudioSpectatorSpawn_%d", index),
		Vector3.new(4, 0.2, 4),
		CFrame.new(at + Vector3.new(0, 0.1, 0)),
		spectatorsModel,
		false
	)
	pad:AddTag("StudioSpectatorSpawn")
end

-- The walkway and the air above it. Leaving it any way - over the fence
-- (X < 83.5), down the 6-stud drop to the terraces at its north end
-- (Z > 6), round the corner onto the south walkway (Z < -60) - puts a
-- spectator back on a lookout. Its floor sits 2 studs under the
-- walkway's, so standing and jumping stay inside.
local AREA_MIN = Vector3.new(83.5, WALK_Y - 2, -60)
local AREA_MAX = Vector3.new(103, WALK_Y + 20, 6)
local area =
	part("StudioSpectatorArea", AREA_MAX - AREA_MIN, CFrame.new((AREA_MIN + AREA_MAX) / 2), spectatorsModel, false)
area:AddTag("StudioSpectatorArea")

-- ===== 4. write =============================================================

cave.Name = "DecisionStudio"
fs.writeFile(outputPath, roblox.serializeModel({ cave }))
print(
	string.format(
		"build-decision-studio: removed %d ramp parts; added 3 podiums and %d lookouts; wrote %s",
		removed,
		#LOOKOUTS,
		outputPath
	)
)
