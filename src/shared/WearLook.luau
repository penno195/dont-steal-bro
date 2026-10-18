--!strict
-- A wearable cosmetic (Hat, BackItem) as an Accessory, shared so the
-- server's real one (CosmeticService) and the menus' try-on preview
-- (client, UI/AvatarPreview) are built the same way and sit in the same
-- spot.
--
-- The handle is a plain Part + SpecialMesh rather than a MeshPart:
-- MeshPart.MeshId can't be set from a script, and a SpecialMesh's
-- MeshId/TextureId/Scale can, with no async load to wait on.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticLogic = require(ReplicatedStorage.Shared.CosmeticLogic)

local WearLook = {}

local ACCESSORY_TYPE: { [string]: Enum.AccessoryType } = {
	Hat = Enum.AccessoryType.Hat,
	BackItem = Enum.AccessoryType.Back,
}

-- The Accessory for `def`, a Hat or BackItem with its wear fields set.
-- nil for any other category. The caller names and parents it.
function WearLook.accessory(def: CosmeticLogic.CosmeticDef): Accessory?
	local attachmentName = CosmeticLogic.wearAttachmentFor(def.category)
	if attachmentName == nil or def.wearMeshAssetId == nil or def.wearScale == nil then
		return nil
	end
	local accessory = Instance.new("Accessory")
	accessory.AccessoryType = ACCESSORY_TYPE[def.category]

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.one
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.Parent = accessory

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = string.format("rbxassetid://%d", def.wearMeshAssetId :: number)
	mesh.TextureId = string.format("rbxassetid://%d", def.wearTextureAssetId or 0)
	mesh.Scale = Vector3.one * (def.wearScale :: number)
	mesh.Parent = handle

	-- The weld lines this attachment up with the body's, so the mesh's
	-- offset from the body is this attachment's inverse.
	local o = def.wearOffset or { 0, 0, 0 }
	local r = def.wearRotation or { 0, 0, 0 }
	local attachment = Instance.new("Attachment")
	attachment.Name = attachmentName
	local placement = CFrame.new(o[1], o[2], o[3]) * CFrame.Angles(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
	attachment.CFrame = placement:Inverse()
	attachment.Parent = handle

	return accessory
end

-- ===== Fit: the engine's accessory rescale, measured ======================
--
-- Humanoid:AddAccessory resizes a Classic accessory to the body it goes
-- on: on an Rthro-proportioned head the Rookie Cap comes out at 0.625x,
-- non-uniformly with BodyProportionScale, and differently again per body
-- part. The menus' preview can't call it (a copy in a ViewportFrame gets
-- no weld and no rescale, client or not), so it showed the cap 1.6x too
-- big, down over the face (2026-10-18 playtest). Rather than copy the
-- engine's scale tables, the server measures the result once per
-- character (CosmeticService) and stores it here; the copy is a clone,
-- so it carries the attribute into the preview.

-- The character attribute holding `category`'s fit (a Vector3).
function WearLook.fitAttribute(category: string): string
	return "DSBWearFit" .. category
end

-- An invisible, meshless stand-in for `category`'s accessory: its
-- Handle's size after AddAccessory is the engine's rescale. nil for a
-- category that isn't worn.
function WearLook.probe(category: string): Accessory?
	local attachmentName = CosmeticLogic.wearAttachmentFor(category)
	if attachmentName == nil then
		return nil
	end
	local accessory = Instance.new("Accessory")
	accessory.AccessoryType = ACCESSORY_TYPE[category]
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.one
	handle.Transparency = 1
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.Parent = accessory
	local attachment = Instance.new("Attachment")
	attachment.Name = attachmentName
	attachment.Parent = handle
	return accessory
end

-- Scales `accessory` (from WearLook.accessory) as AddAccessory would on
-- a body whose measured fit is `fit`: the mesh and the attachment's
-- offset, per axis, in the handle's own space.
function WearLook.fit(accessory: Accessory, fit: Vector3)
	local handle = accessory:FindFirstChild("Handle")
	if handle == nil or not handle:IsA("BasePart") then
		return
	end
	handle.Size *= fit
	local mesh = handle:FindFirstChildOfClass("SpecialMesh")
	if mesh ~= nil then
		mesh.Scale *= fit
	end
	local attachment = handle:FindFirstChildOfClass("Attachment")
	if attachment ~= nil then
		local cf = attachment.CFrame
		attachment.CFrame = CFrame.new(cf.Position * fit) * cf.Rotation
	end
end

-- ===== Skin: classic clothing on a textured body ==========================
--
-- A body part's own TextureID draws over a Shirt and Pants, so on a
-- textured avatar (Rthro, robots: the owner's own) the Founder's Kit
-- showed nothing at all (2026-10-18 playtest). Wearing a skin clears the
-- body parts' textures, all but the Head's (the face). Returns what was
-- cleared, to put back on unequip.
function WearLook.clearBodyTextures(character: Model): { [MeshPart]: string }
	local cleared: { [MeshPart]: string } = {}
	for _, child in character:GetChildren() do
		if child:IsA("MeshPart") and child.Name ~= "Head" and child.TextureID ~= "" then
			cleared[child] = child.TextureID
			child.TextureID = ""
		end
	end
	return cleared
end

-- Welds `accessory` onto `character` at its matching body attachment by
-- hand, as Humanoid:AddAccessory would. For a model that isn't a live
-- character (the preview's copy in a ViewportFrame), where AddAccessory
-- can't be relied on to place the handle. Returns false if the body has
-- no such attachment.
function WearLook.weld(character: Model, accessory: Accessory): boolean
	local handle = accessory:FindFirstChild("Handle")
	local own = if handle then handle:FindFirstChildOfClass("Attachment") else nil
	if handle == nil or not handle:IsA("BasePart") or own == nil then
		return false
	end
	local body: Attachment? = nil
	for _, d in character:GetDescendants() do
		if d:IsA("Attachment") and d.Name == own.Name and not d:IsDescendantOf(accessory) then
			body = d
			break
		end
	end
	if body == nil or not (body.Parent :: Instance):IsA("BasePart") then
		return false
	end
	local part = body.Parent :: BasePart
	handle.CFrame = part.CFrame * body.CFrame * own.CFrame:Inverse()
	local weld = Instance.new("Weld")
	weld.Name = "AccessoryWeld"
	weld.Part0 = part
	weld.Part1 = handle
	weld.C0 = body.CFrame
	weld.C1 = own.CFrame
	weld.Parent = handle
	accessory.Parent = character
	return true
end

return WearLook
