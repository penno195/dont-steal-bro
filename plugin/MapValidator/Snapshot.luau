--!strict
-- Turns a real map Model into MapCheck's plain-table MapSnapshot (P7-1).
-- The only file in the validator that reads an Instance tree, and it
-- runs in two different engines: inside Studio (the plugin) and inside
-- Lune's `@lune/roblox` (scripts/validate-maps.luau, headless CI). So it
-- sticks to the methods both implement - GetDescendants, IsA, GetTags,
-- GetAttributes, GetFullName, and CFrame/Vector3 maths - and never calls
-- game:GetService or any Studio-only property.
--
-- Every property read is pcall'd. Lune's deserializer throws on a
-- property the place file didn't serialize rather than returning the
-- class default (verified against lune 0.10.5: reading an unset
-- MeshPart.CollisionFidelity or Attachment.Position raises "missing
-- default value"), and a missing reading must degrade to "unknown", not
-- abort the whole map.

local MapCheck = require(script.Parent.MapCheck)

local Snapshot = {}

-- The only classes MapCheck asks about. IsA resolves inheritance, so a
-- MeshPart lands with BasePart, MeshPart and TriangleMeshPart all true.
local CLASSES = {
	"BasePart",
	"MeshPart",
	"TriangleMeshPart",
	"Attachment",
	"LuaSourceContainer",
	"Decal",
	"SurfaceAppearance",
}

-- Texture-bearing ContentId properties per class. Only the ContentId
-- form is read: the newer `*Content` properties are Content objects
-- Lune can't stringify, and every current Studio build still serializes
-- the ContentId alongside them. Decal also covers Texture (a subclass).
local TEXTURE_PROPS: { [string]: { string } } = {
	MeshPart = { "TextureID" },
	Decal = { "Texture", "ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap" },
	SurfaceAppearance = { "ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap" },
}

local function read(instance: any, prop: string): any
	local ok, value = pcall(function()
		return instance[prop]
	end)
	return if ok then value else nil
end

local function vec(v: any): MapCheck.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function boxOf(part: any): MapCheck.Box?
	local cf = read(part, "CFrame")
	local size = read(part, "Size")
	if cf == nil or size == nil then
		return nil
	end
	return {
		center = vec(cf.Position),
		right = vec(cf.RightVector),
		up = vec(cf.UpVector),
		back = vec(-cf.LookVector),
		size = vec(size),
	}
end

-- Attachment world position, computed from the parent's CFrame rather
-- than read from WorldPosition: that's a derived property, never saved
-- to a place file, so Lune can't see it.
local function attachmentPosition(attachment: any): MapCheck.Vec3?
	local parentCf = read(attachment.Parent, "CFrame")
	local localCf = read(attachment, "CFrame")
	if parentCf == nil then
		return nil
	end
	if localCf == nil then
		return vec(parentCf.Position) -- unset = identity offset
	end
	return vec((parentCf * localCf).Position)
end

-- Path relative to the map root: "GrayBoxTest.Floor.Station3" rather
-- than the full "ServerStorage.Maps.GrayBoxTest.Floor.Station3".
local function relativePath(instance: any, prefixLength: number): string
	local full = instance:GetFullName() :: string
	return string.sub(full, prefixLength + 1)
end

-- `root` is the map Model. Returns the snapshot plus the id -> Instance
-- list the plugin needs for click-to-select; node.id is its index in
-- both, which MapCheck relies on to look nodes up by id.
function Snapshot.build(root: any): (MapCheck.MapSnapshot, { any })
	local prefixLength = #(root:GetFullName() :: string) - #(root.Name :: string)
	local nodes: { MapCheck.Node } = {}
	local instances: { any } = {}

	for _, instance in root:GetDescendants() do
		local isA: { [string]: boolean } = {}
		for _, class in CLASSES do
			if instance:IsA(class) then
				isA[class] = true
			end
		end

		local textureIds = {}
		for class, props in TEXTURE_PROPS do
			if isA[class] then
				for _, prop in props do
					local value = read(instance, prop)
					if type(value) == "string" and value ~= "" then
						table.insert(textureIds, value)
					end
				end
			end
		end

		local node: MapCheck.Node = {
			id = #nodes + 1,
			path = relativePath(instance, prefixLength),
			className = instance.ClassName,
			isA = isA,
			tags = instance:GetTags(),
			attributes = instance:GetAttributes(),
			textureIds = textureIds,
		}

		if isA.BasePart then
			node.box = boxOf(instance)
			node.anchored = read(instance, "Anchored")
			node.canCollide = read(instance, "CanCollide")
			node.canTouch = read(instance, "CanTouch")
			node.canQuery = read(instance, "CanQuery")
		end
		if isA.TriangleMeshPart then
			local fidelity = read(instance, "CollisionFidelity")
			node.collisionFidelity = if fidelity ~= nil then read(fidelity, "Name") else nil
		end
		if isA.MeshPart then
			local meshId = read(instance, "MeshId")
			node.meshId = if type(meshId) == "string" then meshId else nil
		end
		if isA.Attachment then
			node.position = attachmentPosition(instance)
		end

		table.insert(nodes, node)
		table.insert(instances, instance)
	end

	return { name = root.Name, nodes = nodes }, instances
end

return Snapshot
