--!strict
-- THE PICKUP LOOK, shared so the race's pickups (PowerUpService, built
-- on the server) and the hub tutorial's personal pickup
-- (TutorialPickupController, built on its owner's client only) are the
-- same thing to look at.
--
-- The orb is the claimable part but is never drawn: what players see is
-- `Haze`, a slightly larger ForceField-material shell in the item's role
-- colour (PowerUpLogic.ROLE_RGB). ForceField draws mostly at the rim, so
-- it reads as a force field around the icon rather than a tinted bubble
-- hiding it (a ForceField ORB at 0.5 transparency was tried before and
-- swallowed the icon; the rim-only shell at full opacity doesn't). The
-- item's own model - PowerUpModels[<id>], built by
-- scripts/build-powerup-models.luau - is cloned in as `Visual`, and
-- PickupController spins it and breathes the haze client-side (a
-- server-side animation would replicate every frame). Two lights: a
-- role-coloured glow at the centre that spills onto the floor, and a
-- near-white key light above so the icon's non-neon faces aren't black
-- in a dark map. The energy-shield look comes from two additive,
-- lighting-independent sprites layered over that rim: a soft `Glow`
-- halo and a fast-turning `Vortex` swirl, both the engine's own legacy
-- ForceField textures (shipped in every client's content folder, so no
-- upload and no moderation). No model for an id is fine: the haze alone
-- still reads as a pickup. A race pickup also wears a flat `RarityRing`
-- floating above the shell in its rarity colour (PowerUpLogic.
-- RARITY_RGB): a hollow CylinderHandleAdornment, so no extra part and no
-- texture. The tutorial's pickup passes no rarity and shows none.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PowerUpLogic = require(ReplicatedStorage.Shared.PowerUpLogic)

local ORB_SIZE = 3.2 -- the invisible touch/claim ball
local HAZE_DIAMETER = 4.6
local HAZE_TRANSPARENCY = 0
local HAZE_WHITENESS = 0.35 -- rim and sprites: role colour lifted toward white
local VISUAL_FIT_STUDS = 2.4 -- the model's longest side, inside the orb
local KEY_LIGHT_HEIGHT = 2.4 -- studs above the orb centre
local KEY_LIGHT_WHITENESS = 0.7 -- lerp from role colour toward white
local MOTE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local GLOW_TEXTURE = "rbxasset://textures/particles/forcefield_glow_main.dds"
local VORTEX_TEXTURE = "rbxasset://textures/particles/forcefield_vortex_main.dds"
local RING_HEIGHT = 3.1 -- studs above the orb centre, clear of the shell's top
local RING_RADIUS = 1.1
local RING_INNER_RADIUS = 0.8
local RING_THICKNESS = 0.18

local PickupLook = {}

-- One of the shield sprites: spawned at the orb centre, locked to it,
-- fading in and out while it spins so overlapping copies read as a
-- continuous shimmer rather than a blinking decal.
local function shieldSprite(
	parent: Instance,
	name: string,
	texture: string,
	size: number,
	peakOpacity: number,
	spin: number,
	rate: number
): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.LockedToPart = true
	emitter.Size = NumberSequence.new(size)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.4, 1 - peakOpacity),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(1.2, 1.6)
	emitter.Rate = rate
	emitter.Speed = NumberRange.new(0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-spin, spin)
	emitter.Enabled = false
	emitter.Parent = parent
	return emitter
end

function PickupLook.roleColor(role: string): Color3
	local rgb = PowerUpLogic.ROLE_RGB[role]
	return if rgb then Color3.fromRGB(rgb[1], rgb[2], rgb[3]) else Color3.fromRGB(255, 255, 255)
end

-- The orb with its shell, lights and sprites, all hidden until `show`.
-- Not parented: the caller decides where it lives (and wires touches).
function PickupLook.build(cframe: CFrame): BasePart
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(ORB_SIZE, ORB_SIZE, ORB_SIZE)
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Transparency = 1
	part.CFrame = cframe

	local haze = Instance.new("Part")
	haze.Name = "Haze"
	haze.Shape = Enum.PartType.Ball
	haze.Size = Vector3.new(HAZE_DIAMETER, HAZE_DIAMETER, HAZE_DIAMETER)
	haze.Material = Enum.Material.ForceField
	haze.Transparency = 1
	haze.Anchored = true
	haze.CanCollide = false
	haze.CanTouch = false
	haze.CanQuery = false
	haze.CastShadow = false
	haze.CFrame = part.CFrame
	haze:SetAttribute("BaseDiameter", HAZE_DIAMETER) -- PickupController breathes around this
	haze.Parent = part

	local glow = Instance.new("PointLight")
	glow.Name = "Glow"
	glow.Range = 10
	glow.Brightness = 1.5
	glow.Shadows = false
	glow.Enabled = false
	glow.Parent = part

	local keyAttachment = Instance.new("Attachment")
	keyAttachment.Name = "KeyLight"
	keyAttachment.Position = Vector3.new(0, KEY_LIGHT_HEIGHT, 0)
	keyAttachment.Parent = part
	local key = Instance.new("PointLight")
	key.Range = 5
	key.Brightness = 3
	key.Shadows = false
	key.Enabled = false
	key.Parent = keyAttachment

	local motes = Instance.new("ParticleEmitter")
	motes.Name = "Motes"
	motes.Texture = MOTE_TEXTURE
	motes.LightEmission = 1
	motes.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	motes.Transparency = NumberSequence.new(0.2)
	motes.Lifetime = NumberRange.new(1, 1.6)
	motes.Rate = 8
	motes.Speed = NumberRange.new(0.3, 0.6)
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.Shape = Enum.ParticleEmitterShape.Sphere
	motes.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	motes.Enabled = false
	motes.Parent = part

	-- An attachment emits from a point, so the sprites sit dead centre.
	local core = Instance.new("Attachment")
	core.Name = "Core"
	core.Parent = part
	-- Sizes tuned by eye in playtest: the glow texture is a soft centre
	-- blob so it matches the shell at ~HAZE_DIAMETER, but the vortex's
	-- swirl reaches the sprite edge, so it needs a much smaller size to
	-- sit just outside the rim instead of drawing a second ring.
	shieldSprite(core, "Glow", GLOW_TEXTURE, HAZE_DIAMETER - 0.2, 0.6, 20, 3)
	shieldSprite(core, "Vortex", VORTEX_TEXTURE, 3.6, 0.85, 120, 5)

	-- A cylinder runs along its CFrame's Z, so turn it to lie flat.
	local ring = Instance.new("CylinderHandleAdornment")
	ring.Name = "RarityRing"
	ring.Adornee = part
	ring.CFrame = CFrame.new(0, RING_HEIGHT, 0) * CFrame.Angles(math.rad(90), 0, 0)
	ring.Radius = RING_RADIUS
	ring.InnerRadius = RING_INNER_RADIUS
	ring.Height = RING_THICKNESS
	ring.Visible = false
	ring.Parent = part
	return part
end

local function clearVisual(part: BasePart)
	local visual = part:FindFirstChild("Visual")
	if visual ~= nil then
		visual:Destroy()
	end
end

-- Lights the orb up in `color` and puts a clone of `source` (the item's
-- icon model, if there is one) inside it as `Visual`. `rarity` lights
-- the ring; nil leaves it off.
function PickupLook.show(part: BasePart, color: Color3, source: Instance?, rarity: string?)
	part.Color = color
	local ring = part:FindFirstChild("RarityRing")
	if ring ~= nil and ring:IsA("CylinderHandleAdornment") then
		local rgb = if rarity ~= nil then PowerUpLogic.RARITY_RGB[rarity] else nil
		ring.Visible = rgb ~= nil
		if rgb ~= nil then
			ring.Color3 = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		end
	end
	local shieldColor = color:Lerp(Color3.new(1, 1, 1), HAZE_WHITENESS)
	local haze = part:FindFirstChild("Haze")
	if haze ~= nil and haze:IsA("BasePart") then
		haze.Color = shieldColor
		haze.Transparency = HAZE_TRANSPARENCY
	end
	local core = part:FindFirstChild("Core")
	if core ~= nil then
		for _, sprite in core:GetChildren() do
			if sprite:IsA("ParticleEmitter") then
				sprite.Color = ColorSequence.new(shieldColor)
				sprite.Enabled = true
				sprite:Emit(6) -- start full rather than fading in from empty
			end
		end
	end
	local glow = part:FindFirstChild("Glow")
	if glow ~= nil and glow:IsA("PointLight") then
		glow.Color = color
		glow.Enabled = true
	end
	local keyAttachment = part:FindFirstChild("KeyLight")
	local key = if keyAttachment ~= nil then keyAttachment:FindFirstChildOfClass("PointLight") else nil
	if key ~= nil then
		key.Color = color:Lerp(Color3.new(1, 1, 1), KEY_LIGHT_WHITENESS)
		key.Enabled = true
	end
	local motes = part:FindFirstChild("Motes")
	if motes ~= nil and motes:IsA("ParticleEmitter") then
		motes.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.3))
		motes.Enabled = true
	end
	PickupLook.setVisual(part, source)
end

-- Swaps the icon inside a lit orb for a clone of `source` (nil: none),
-- leaving the shell, lights and sprites alone. The daily hunt's drop
-- turns through every item this way.
function PickupLook.setVisual(part: BasePart, source: Instance?)
	clearVisual(part)
	if source == nil or not source:IsA("Model") then
		return
	end
	local visual = source:Clone()
	visual.Name = "Visual"
	for _, d in visual:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
		end
	end
	local extents = visual:GetExtentsSize()
	local longest = math.max(extents.X, extents.Y, extents.Z)
	if longest > 0 then
		visual:ScaleTo(visual:GetScale() * VISUAL_FIT_STUDS / longest)
	end
	visual:PivotTo(part.CFrame)
	visual.Parent = part
end

-- Puts the orb out again: shell, ring, lights, sprites and icon.
function PickupLook.hide(part: BasePart)
	local ring = part:FindFirstChild("RarityRing")
	if ring ~= nil and ring:IsA("CylinderHandleAdornment") then
		ring.Visible = false
	end
	local haze = part:FindFirstChild("Haze")
	if haze ~= nil and haze:IsA("BasePart") then
		haze.Transparency = 1
	end
	for _, d in part:GetDescendants() do
		if d:IsA("Light") then
			d.Enabled = false
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = false
			d:Clear()
		end
	end
	clearVisual(part)
end

return PickupLook
