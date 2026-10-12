--!strict
-- Taco Tuesday's look (Config/Events/TacoTuesday.luau): tacos rain down
-- around the player and disco balls spin over the lobby (owner,
-- 2026-10-12, after the Squishie merge game's taco event). Built on
-- this client only, so every player sees their own rain.
--
-- RAIN. Tacos spawn in a ring around the camera's focus, under any roof
-- above it, and fall to whatever is below them. A taco that lands sits
-- for a moment, then shrinks away. They're anchored, can't be touched,
-- hit or collided with, and one Heartbeat moves all of them. The live
-- count is capped, lower on touch devices (Ground Rule 3).
--
-- DISCO BALLS. One under each part tagged EventDiscoAnchor in the Hub,
-- or, with none tagged, three over the spawn plaza (the HubSpawn tag).
-- Each spins, with coloured spotlights sweeping round under it.
--
-- The mesh is the Creator Store's "roblox-taco-v2" (asset
-- 137715879734128), drawn through a SpecialMesh because a MeshPart's
-- MeshId can't be set from a script.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local TACO_MESH = "rbxassetid://95303422523221"
local TACO_TEXTURE = "rbxassetid://122924055787756"
local TACO_SCALE = 2.2 -- the mesh is ~1.3 studs long at scale 1

local MAX_TACOS = if UserInputService.TouchEnabled then 40 else 70
local SPAWN_EVERY = if UserInputService.TouchEnabled then 0.12 else 0.07
local RING_RADIUS = 55
local DROP_HEIGHT = 45 -- above the focus, or just under a roof
local FALL_SPEED = 22 -- studs a second
local REST_SECONDS = 2.5
local SHRINK_SECONDS = 0.6

local DISCO_ANCHOR_TAG = "EventDiscoAnchor"
local BALL_SIZE = 4.5
local BALL_HANG = 6 -- studs under an anchor
local DISCO_COLOURS = {
	Color3.fromRGB(255, 70, 160),
	Color3.fromRGB(70, 200, 255),
	Color3.fromRGB(255, 220, 60),
	Color3.fromRGB(120, 255, 120),
}

type Taco = {
	part: Part,
	mesh: SpecialMesh,
	spin: Vector3,
	angles: Vector3,
	groundY: number,
	landedAt: number?,
}

local function newTaco(folder: Folder, at: Vector3, groundY: number): Taco
	local part = Instance.new("Part")
	part.Name = "Taco"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Size = Vector3.new(1, 1, 1) * TACO_SCALE
	part.Transparency = 0
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = TACO_MESH
	mesh.TextureId = TACO_TEXTURE
	mesh.Scale = Vector3.new(1, 1, 1) * TACO_SCALE
	mesh.Parent = part
	local angles = Vector3.new(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
	part.CFrame = CFrame.new(at) * CFrame.Angles(angles.X, angles.Y, angles.Z)
	part.Parent = folder
	return {
		part = part,
		mesh = mesh,
		spin = Vector3.new(math.random() * 4 - 2, math.random() * 4 - 2, math.random() * 4 - 2),
		angles = angles,
		groundY = groundY,
		landedAt = nil,
	}
end

local function newDiscoBall(folder: Folder, at: Vector3, hangFrom: Vector3?): (Part, { SpotLight })
	if hangFrom ~= nil then
		local length = (hangFrom - at).Magnitude
		local wire = Instance.new("Part")
		wire.Name = "DiscoWire"
		wire.Anchored = true
		wire.CanCollide = false
		wire.CanTouch = false
		wire.CanQuery = false
		wire.Color = Color3.fromRGB(40, 40, 40)
		wire.Size = Vector3.new(0.1, length, 0.1)
		wire.CFrame = CFrame.new((hangFrom + at) / 2)
		wire.Parent = folder
	end

	local ball = Instance.new("Part")
	ball.Name = "DiscoBall"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(1, 1, 1) * BALL_SIZE
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanTouch = false
	ball.CanQuery = false
	-- DiamondPlate's tread reads as mirror tiles. Lighter, or a light
	-- inside it, and the lobby's bloom blows it out to a white blob
	-- (seen in Studio).
	ball.Material = Enum.Material.DiamondPlate
	ball.Color = Color3.fromRGB(150, 155, 170)
	ball.Reflectance = 0.35
	ball.CFrame = CFrame.new(at)

	-- The spotlights barely show outdoors by day, so coloured sparkles
	-- fly off the surface as well.
	local keys = {}
	for i, colour in DISCO_COLOURS do
		table.insert(keys, ColorSequenceKeypoint.new((i - 1) / (#DISCO_COLOURS - 1), colour))
	end
	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkles.Shape = Enum.ParticleEmitterShape.Sphere
	sparkles.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	sparkles.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	sparkles.Rate = 30
	sparkles.Lifetime = NumberRange.new(0.6, 1.2)
	sparkles.Speed = NumberRange.new(6, 12)
	sparkles.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.1), NumberSequenceKeypoint.new(1, 0) })
	sparkles.LightEmission = 1
	sparkles.Color = ColorSequence.new(keys)
	sparkles.Parent = ball

	-- Spotlights fanned round the ball and tilted down; the ball's spin
	-- sweeps them across the floor.
	local spots: { SpotLight } = {}
	for i, colour in DISCO_COLOURS do
		local holder = Instance.new("Attachment")
		local yaw = (i - 1) / #DISCO_COLOURS * math.pi * 2
		holder.CFrame = CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-55), 0, 0)
		holder.Parent = ball
		local spot = Instance.new("SpotLight")
		spot.Face = Enum.NormalId.Front
		spot.Angle = 35
		spot.Range = 40
		spot.Brightness = 4
		spot.Color = colour
		spot.Shadows = false
		spot.Parent = holder
		table.insert(spots, spot)
	end
	ball.Parent = folder
	return ball, spots
end

-- Where the balls hang: under each tagged anchor, else over the plaza.
local function discoSpots(): { { at: Vector3, hangFrom: Vector3? } }
	local spots: { { at: Vector3, hangFrom: Vector3? } } = {}
	for _, anchor in CollectionService:GetTagged(DISCO_ANCHOR_TAG) do
		if anchor:IsA("BasePart") then
			table.insert(spots, { at = anchor.Position - Vector3.new(0, BALL_HANG, 0), hangFrom = anchor.Position })
		end
	end
	if #spots > 0 then
		return spots
	end
	local spawn = CollectionService:GetTagged("HubSpawn")[1]
	if spawn == nil or not spawn:IsA("BasePart") then
		return spots
	end
	-- World offsets, not the spawn's own: players face +Z from it, toward
	-- the hotel door, whichever way the SpawnLocation part is turned.
	for _, offset in { Vector3.new(0, 18, 22), Vector3.new(-15, 15, 34), Vector3.new(15, 15, 34) } do
		table.insert(spots, { at = spawn.Position + offset, hangFrom = nil })
	end
	return spots
end

local TacoTuesday = {}

function TacoTuesday.start(): () -> ()
	local folder = Instance.new("Folder")
	folder.Name = "TacoTuesday"
	folder.Parent = Workspace

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true

	local balls: { { part: Part, spots: { SpotLight } } } = {}
	for _, spot in discoSpots() do
		local part, lights = newDiscoBall(folder, spot.at, spot.hangFrom)
		table.insert(balls, { part = part, spots = lights })
	end

	local tacos: { Taco } = {}
	local sinceSpawn = 0
	local clock = 0

	local function exclude()
		local list: { Instance } = { folder }
		local character = Players.LocalPlayer.Character
		if character ~= nil then
			table.insert(list, character)
		end
		rayParams.FilterDescendantsInstances = list
	end

	local function spawnTaco()
		local camera = Workspace.CurrentCamera
		if camera == nil then
			return
		end
		local focus = camera.Focus.Position
		local angle = math.random() * math.pi * 2
		local distance = math.sqrt(math.random()) * RING_RADIUS
		local column = focus + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		local top = column.Y + DROP_HEIGHT
		local roof = Workspace:Raycast(column, Vector3.new(0, DROP_HEIGHT, 0), rayParams)
		if roof ~= nil then
			top = roof.Position.Y - 2
		end
		local ground = Workspace:Raycast(Vector3.new(column.X, top, column.Z), Vector3.new(0, -200, 0), rayParams)
		local groundY = if ground ~= nil then ground.Position.Y + TACO_SCALE * 0.3 else column.Y - 60
		if top - groundY < 4 then
			return -- no room to fall here
		end
		table.insert(tacos, newTaco(folder, Vector3.new(column.X, top, column.Z), groundY))
	end

	exclude()
	local connection = RunService.Heartbeat:Connect(function(dt: number)
		clock += dt
		sinceSpawn += dt
		if sinceSpawn >= SPAWN_EVERY then
			sinceSpawn = 0
			if #tacos < MAX_TACOS then
				exclude()
				spawnTaco()
			end
		end

		for i = #tacos, 1, -1 do
			local taco = tacos[i]
			local landedAt = taco.landedAt
			if landedAt == nil then
				local position = taco.part.Position - Vector3.new(0, FALL_SPEED * dt, 0)
				taco.angles += taco.spin * dt
				if position.Y <= taco.groundY then
					position = Vector3.new(position.X, taco.groundY, position.Z)
					taco.landedAt = clock
					-- Lands lying flat, facing wherever it was turning.
					taco.angles = Vector3.new(0, taco.angles.Y, 0)
				end
				taco.part.CFrame = CFrame.new(position) * CFrame.Angles(taco.angles.X, taco.angles.Y, taco.angles.Z)
			elseif clock - landedAt > REST_SECONDS then
				local shrink = 1 - (clock - landedAt - REST_SECONDS) / SHRINK_SECONDS
				if shrink <= 0 then
					taco.part:Destroy()
					table.remove(tacos, i)
				else
					taco.mesh.Scale = Vector3.new(1, 1, 1) * TACO_SCALE * shrink
				end
			end
		end

		for _, ball in balls do
			ball.part.CFrame = ball.part.CFrame * CFrame.Angles(0, dt * 0.9, 0)
		end
	end)

	return function()
		connection:Disconnect()
		folder:Destroy()
	end
end

return TacoTuesday
