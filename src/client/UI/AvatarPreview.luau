--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- Try it on (owner, 2026-10-17): a slowly turning copy of the player's
-- own avatar in a ViewportFrame, wearing a cosmetic or playing an emote,
-- for the Store's panel, the Locker and the season pass's item preview.
--
-- The copy is a clone of the live character, so it already wears what
-- the player has on (the server's real cosmetics included); the item
-- being tried goes on top, hiding whatever it would hide when worn
-- (CosmeticLogic.clashesWith, as CosmeticService does). Client-only and
-- never parented to the workspace: nobody else sees it.
--
-- Only what reads on a still body previews: hats, back items, skins and
-- emotes. A trail (Trails don't render in a ViewportFrame), a podium
-- flourish, a nameplate and the rest keep their picture; `supports`
-- says which. With no character to copy (dead, loading) the fallback
-- shows instead.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local CosmeticLogic = require(ReplicatedStorage.Shared.CosmeticLogic)
local WearLook = require(ReplicatedStorage.Shared.WearLook)

local create = vide.create
local source = vide.source
local effect = vide.effect
local cleanup = vide.cleanup

local AvatarPreview = {}

type Def = CosmeticLogic.CosmeticDef

local TURN_DEG_PER_SECOND = 24
local FOV = 30
-- What a copied character must not bring along: its scripts (Animate
-- would fight the emote), sounds, overhead guis and effects that don't
-- belong in a still portrait.
local STRIP: { string } = {
	"BaseScript",
	"ModuleScript",
	"Sound",
	"BillboardGui",
	"ParticleEmitter",
	"Trail",
	"Beam",
	"ForceField",
	"Highlight",
}

-- Whether `def` previews on the avatar (else show its picture).
function AvatarPreview.supports(def: Def?): boolean
	if def == nil then
		return false
	elseif def.category == "Hat" or def.category == "BackItem" then
		return def.wearMeshAssetId ~= nil and def.wearMeshAssetId > 0
	elseif def.category == "Skin" then
		return (def.shirtAssetId or 0) > 0 or (def.pantsAssetId or 0) > 0
	elseif def.category == "Emote" then
		return (def.animationAssetId or 0) > 0
	end
	return false
end

local function copyCharacter(): Model?
	local character = Players.LocalPlayer.Character
	if character == nil or character:FindFirstChildOfClass("Humanoid") == nil then
		return nil
	end
	local archivable = character.Archivable
	character.Archivable = true
	local copy = character:Clone()
	character.Archivable = archivable
	if copy == nil then
		return nil
	end
	for _, d in copy:GetDescendants() do
		for _, class in STRIP do
			if d:IsA(class) then
				d:Destroy()
				break
			end
		end
	end
	local humanoid = copy:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	local root = copy:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end
	copy:PivotTo(CFrame.new())
	return copy
end

local function handleAttachmentNames(accessory: Accessory): { string }
	local names = {}
	local handle = accessory:FindFirstChild("Handle")
	if handle then
		for _, child in handle:GetChildren() do
			if child:IsA("Attachment") then
				table.insert(names, child.Name)
			end
		end
	end
	return names
end

-- Puts `def` on the copy. An emote is played later, once the copy is in
-- its WorldModel; returns its Animation, if any.
local function dress(copy: Model, def: Def): Animation?
	if def.category == "Hat" or def.category == "BackItem" then
		for _, child in copy:GetChildren() do
			if
				child:IsA("Accessory")
				and CosmeticLogic.clashesWith(def.category, child.AccessoryType.Name, handleAttachmentNames(child))
			then
				child:Destroy()
			end
		end
		local accessory = WearLook.accessory(def)
		if accessory then
			accessory.Name = "Preview" .. def.category
			if not WearLook.weld(copy, accessory) then
				accessory:Destroy()
			end
		end
	elseif def.category == "Skin" then
		local shirt = copy:FindFirstChildOfClass("Shirt") or Instance.new("Shirt")
		local pants = copy:FindFirstChildOfClass("Pants") or Instance.new("Pants")
		if (def.shirtAssetId or 0) > 0 then
			shirt.ShirtTemplate = string.format("rbxassetid://%d", def.shirtAssetId :: number)
			shirt.Parent = copy
		end
		if (def.pantsAssetId or 0) > 0 then
			pants.PantsTemplate = string.format("rbxassetid://%d", def.pantsAssetId :: number)
			pants.Parent = copy
		end
	elseif def.category == "Emote" then
		local animation = Instance.new("Animation")
		animation.AnimationId = string.format("rbxassetid://%d", def.animationAssetId :: number)
		return animation
	end
	return nil
end

export type Props = {
	-- The item tried on; nil shows the avatar as it is.
	def: () -> Def?,
	-- Read to re-copy the character when what it wears changes (the
	-- Locker's equipped set); optional.
	refresh: (() -> any)?,
	-- Shown when there's no character to copy.
	fallback: Instance?,
	zIndex: number?,
}

-- Fills its parent; the caller sizes and places it.
function AvatarPreview.view(props: Props): Frame
	local hasModel = source(false)
	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	local world = Instance.new("WorldModel")
	local viewport = create("ViewportFrame")({
		Name = "Avatar",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Ambient = Color3.fromRGB(200, 196, 215),
		LightColor = Color3.new(1, 1, 1),
		LightDirection = Vector3.new(-1, -1.5, -1),
		CurrentCamera = camera,
		ZIndex = props.zIndex,
	}) :: ViewportFrame
	camera.Parent = viewport
	world.Parent = viewport

	-- The turntable: the camera circles the copy, looking at its middle
	-- from far enough back that the whole body fits.
	local centre, distance, angle = Vector3.zero, 10, 0
	local function place()
		local look = CFrame.Angles(0, math.rad(angle), 0)
		camera.CFrame = CFrame.lookAt(centre + look:VectorToWorldSpace(Vector3.new(0, 0, -distance)), centre)
	end

	effect(function()
		local def = props.def()
		if props.refresh then
			props.refresh()
		end
		local copy = copyCharacter()
		hasModel(copy ~= nil)
		if copy == nil then
			return
		end
		local animation = if def then dress(copy, def) else nil
		copy.Parent = world
		-- Something worn up top frames the upper body (the item reads
		-- bigger); a skin or an emote frames the whole body.
		local box, size = copy:GetBoundingBox()
		local upper = def ~= nil and (def.category == "Hat" or def.category == "BackItem")
		local tall = if upper then size.Y * 0.6 else math.max(size.Y, size.X * 0.8)
		centre = box.Position + Vector3.new(0, if upper then size.Y * 0.24 else 0, 0)
		distance = (tall / 2) / math.tan(math.rad(FOV / 2)) * 1.15
		-- A back item shows its back first; everything else the front.
		angle = if def and def.category == "BackItem" then 180 else 0
		place()
		local track: AnimationTrack? = nil
		if animation then
			local humanoid = copy:FindFirstChildOfClass("Humanoid")
			local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
			if animator then
				local ok, loaded = pcall(animator.LoadAnimation, animator, animation)
				if ok and loaded then
					track = loaded
					loaded.Looped = true
					loaded:Play()
				end
			end
		end
		cleanup(function()
			if track then
				track:Stop(0)
			end
			copy:Destroy()
		end)
	end)

	local turning = RunService.RenderStepped:Connect(function(dt: number)
		if hasModel() and viewport.Visible then
			angle = (angle + TURN_DEG_PER_SECOND * dt) % 360
			place()
		end
	end)
	cleanup(function()
		turning:Disconnect()
	end)

	local fallback = props.fallback
	if fallback and fallback:IsA("GuiObject") then
		effect(function()
			fallback.Visible = not hasModel()
		end)
	end

	local frame = create("Frame")({
		Name = "AvatarPreview",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}) :: Frame
	viewport.Parent = frame
	if fallback then
		fallback.Parent = frame
	end
	return frame
end

return AvatarPreview
