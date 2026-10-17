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
