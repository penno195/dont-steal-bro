--!strict
-- Power-up pickup models + the hub training dummy. Paste into Studio's
-- Command Bar (or run via the Studio MCP) in BOTH the match place and
-- the hub place.
--
-- Builds:
--   ServerStorage.PowerUpModels.<power-up id>  one small icon model per
--     item, which PowerUpService clones into the glowing pickup orb
--     (scaled to fit, pivot = centre) and PickupController spins.
--   ServerStorage.PracticeDummy  a still R15 rig PracticeService puts
--     on each HubPracticeDummy part in the hub. Harmless in the match
--     place (nothing there reads it).
--
-- NOT SYNCED BY ROJO: models live in the .rbxl like the maps; this repo
-- versions the script. IDEMPOTENT: destroys and rebuilds both every run.
--
-- Each icon is a few primitives, no meshes or textures: cheap on a
-- low-end phone and readable at pickup distance. The orb carries the
-- role colour, so icons use white/ice/black accents to stand out
-- against it rather than repeating it.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local WHITE = Color3.fromRGB(245, 245, 245)
local BLACK = Color3.fromRGB(25, 25, 30)
local ICE = Color3.fromRGB(170, 230, 255)
local GOLD = Color3.fromRGB(255, 205, 60)
local SKY = Color3.fromRGB(90, 160, 255)
local RED = Color3.fromRGB(235, 70, 70)

local function part(
	model: Model,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape ~= nil then
		p.Shape = shape
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function wedge(model: Model, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): WedgePart
	local w = Instance.new("WedgePart")
	w.Size = size
	w.CFrame = cf
	w.Color = color
	w.Material = material or Enum.Material.SmoothPlastic
	w.Anchored = true
	w.CanCollide = false
	w.CanTouch = false
	w.CanQuery = false
	w.CastShadow = false
	w.Parent = model
	return w
end

local C = CFrame.new
local A = CFrame.Angles
local R = math.rad
local NEON = Enum.Material.Neon

-- A disc facing the viewer (+Z): cylinders run along X, so turn it.
local function disc(model: Model, diameter: number, depth: number, cf: CFrame, color: Color3, material: Enum.Material?)
	return part(
		model,
		Vector3.new(depth, diameter, diameter),
		cf * A(0, R(90), 0),
		color,
		material,
		Enum.PartType.Cylinder
	)
end

local BUILDERS: { [string]: (Model) -> () } = {
	-- Lightning bolt.
	["sprint-boost"] = function(m)
		part(m, Vector3.new(0.5, 1.3, 0.4), C(0.25, 0.5, 0) * A(0, 0, R(-20)), GOLD, NEON)
		part(m, Vector3.new(1.1, 0.35, 0.4), C(0, 0, 0), GOLD, NEON)
		part(m, Vector3.new(0.5, 1.3, 0.4), C(-0.25, -0.5, 0) * A(0, 0, R(-20)), GOLD, NEON)
	end,

	-- Medical cross on a disc: cleanse.
	["second-wind"] = function(m)
		disc(m, 1.8, 0.3, C(0, 0, 0), WHITE)
		part(m, Vector3.new(0.4, 1.2, 0.4), C(0, 0, 0), SKY, NEON)
		part(m, Vector3.new(1.2, 0.4, 0.4), C(0, 0, 0), SKY, NEON)
	end,

	-- Light bulb: a better idea for your task.
	["task-insight"] = function(m)
		part(m, Vector3.new(1.3, 1.3, 1.3), C(0, 0.3, 0), GOLD, NEON, Enum.PartType.Ball)
		part(m, Vector3.new(0.6, 0.6, 0.6), C(0, -0.55, 0) * A(0, 0, R(90)), WHITE, nil, Enum.PartType.Cylinder)
		part(m, Vector3.new(0.2, 0.45, 0.45), C(0, -0.9, 0) * A(0, 0, R(90)), BLACK, nil, Enum.PartType.Cylinder)
	end,

	-- A see-through diamond: you're there but can't be touched.
	["phase-step"] = function(m)
		part(m, Vector3.new(1.1, 1.1, 1.1), C(0, 0, 0) * A(R(45), 0, R(45)), ICE, Enum.Material.ForceField)
		part(m, Vector3.new(0.6, 0.6, 0.6), C(0, 0, 0) * A(R(45), 0, R(45)), WHITE, NEON)
	end,

	-- Clock face with hands.
	["overclock"] = function(m)
		disc(m, 1.8, 0.3, C(0, 0, 0), WHITE)
		disc(m, 1.95, 0.2, C(0, 0, -0.05), GOLD, NEON)
		part(m, Vector3.new(0.12, 0.7, 0.1), C(0, 0.3, 0.2), BLACK)
		part(m, Vector3.new(0.5, 0.12, 0.1), C(0.22, 0, 0.2), BLACK)
	end,

	-- Snowflake.
	["freeze"] = function(m)
		for i = 0, 2 do
			part(m, Vector3.new(0.22, 1.9, 0.22), C(0, 0, 0) * A(0, 0, R(60 * i)), ICE, NEON)
		end
		part(m, Vector3.new(0.5, 0.5, 0.5), C(0, 0, 0) * A(0, 0, R(45)), WHITE)
	end,

	-- Hourglass: time drags.
	["slow-field"] = function(m)
		part(m, Vector3.new(1.4, 0.2, 1.4), C(0, 0.9, 0), WHITE)
		part(m, Vector3.new(1.4, 0.2, 1.4), C(0, -0.9, 0), WHITE)
		wedge(m, Vector3.new(1.1, 0.8, 0.55), C(0, 0.4, 0.275) * A(R(180), 0, 0), GOLD, NEON)
		wedge(m, Vector3.new(1.1, 0.8, 0.55), C(0, 0.4, -0.275) * A(R(180), R(180), 0), GOLD, NEON)
		wedge(m, Vector3.new(1.1, 0.8, 0.55), C(0, -0.4, 0.275) * A(0, R(180), 0), GOLD, NEON)
		wedge(m, Vector3.new(1.1, 0.8, 0.55), C(0, -0.4, -0.275), GOLD, NEON)
	end,

	-- Dark glasses.
	["blind"] = function(m)
		disc(m, 0.8, 0.2, C(-0.5, 0, 0), BLACK)
		disc(m, 0.8, 0.2, C(0.5, 0, 0), BLACK)
		part(m, Vector3.new(0.4, 0.12, 0.12), C(0, 0.12, 0), WHITE)
		part(m, Vector3.new(0.9, 0.12, 0.12), C(-0.55, 0, -0.45) * A(0, R(90), 0), WHITE)
		part(m, Vector3.new(0.9, 0.12, 0.12), C(0.55, 0, -0.45) * A(0, R(90), 0), WHITE)
	end,

	-- A jumbled 2x2 cube: your task, scrambled.
	["task-scramble"] = function(m)
		local colours = { WHITE, GOLD, SKY, RED, ICE, BLACK, GOLD, WHITE }
		local i = 0
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					i += 1
					part(m, Vector3.new(0.72, 0.72, 0.72), C(x * 0.38, y * 0.38, z * 0.38), colours[i])
				end
			end
		end
	end,

	-- A forward arrow: shove.
	["push-trip"] = function(m)
		part(m, Vector3.new(1.4, 0.35, 0.35), C(-0.2, 0, 0), WHITE)
		part(m, Vector3.new(0.9, 0.35, 0.35), C(0.3, 0.3, 0) * A(0, 0, R(-45)), WHITE)
		part(m, Vector3.new(0.9, 0.35, 0.35), C(0.3, -0.3, 0) * A(0, 0, R(45)), WHITE)
	end,
}

local folder = ServerStorage:FindFirstChild("PowerUpModels")
if folder ~= nil then
	folder:Destroy()
end
folder = Instance.new("Folder")
folder.Name = "PowerUpModels"

local built = {}
for id, build in BUILDERS do
	local model = Instance.new("Model")
	model.Name = id
	build(model)
	-- Pivot at the bounding-box centre, so PivotTo(orb) centres it.
	local centre = model:GetBoundingBox()
	model.WorldPivot = CFrame.new(centre.Position)
	model.Parent = folder
	table.insert(built, id)
end
folder.Parent = ServerStorage

-- THE DUMMY: a default-look R15 rig, recoloured as a training target.
local oldDummy = ServerStorage:FindFirstChild("PracticeDummy")
if oldDummy ~= nil then
	oldDummy:Destroy()
end
local description = Instance.new("HumanoidDescription")
local dummy = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
dummy.Name = "PracticeDummy"
local STRAW = Color3.fromRGB(205, 170, 110)
for _, d in dummy:GetDescendants() do
	if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
		d.Color = STRAW
		d.Material = Enum.Material.Fabric
	elseif d:IsA("Decal") and d.Name == "face" then
		d:Destroy() -- a faceless dummy, not a person
	elseif d:IsA("Script") or d:IsA("LocalScript") then
		d:Destroy() -- the default Animate/Health scripts: it stands still
	elseif d:IsA("BodyColors") or d:IsA("Clothing") or d:IsA("Accessory") then
		d:Destroy() -- BodyColors would override the straw colour above
	end
end
local torso = dummy:FindFirstChild("UpperTorso")
if torso ~= nil and torso:IsA("BasePart") then
	-- A target on the chest, so it reads as "hit me".
	for i, ring in { { 1.4, RED }, { 1.0, WHITE }, { 0.55, RED } } do
		local target = Instance.new("Part")
		target.Shape = Enum.PartType.Cylinder
		target.Size = Vector3.new(0.05 + i * 0.01, ring[1] :: number, ring[1] :: number)
		target.Color = ring[2] :: Color3
		target.Material = Enum.Material.SmoothPlastic
		target.CanCollide = false
		target.CanTouch = false
		target.CanQuery = false
		target.Massless = true
		target.CFrame = torso.CFrame
			* CFrame.new(0, 0.1, -torso.Size.Z / 2 - 0.02 - i * 0.01)
			* CFrame.Angles(0, math.rad(90), 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = torso
		weld.Part1 = target
		weld.Parent = target
		target.Parent = dummy
	end
end
local humanoid = dummy:FindFirstChildOfClass("Humanoid")
if humanoid ~= nil then
	humanoid.DisplayName = "Training Dummy"
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
end
dummy.Parent = ServerStorage

table.sort(built)
print(string.format("build-powerup-models: %d models (%s) + PracticeDummy", #built, table.concat(built, ", ")))
