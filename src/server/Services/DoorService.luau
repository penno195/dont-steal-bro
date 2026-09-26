--!strict
-- Proximity doors: open when someone walks up, close when everyone has
-- gone. Any Model tagged ProximityDoor with a BasePart child named
-- "Hinge" works, in the hub or on a map - adding a door is tagging it,
-- never editing this file. docs/hub-spec.md "Doors" has the contract.
--
-- SPLIT. The server decides (DoorLogic, from the characters it knows
-- about) and publishes two attributes on the Model: Open (boolean) and
-- OpenSide (+1/-1, the way to swing - away from whoever opened it).
-- DoorController on each client animates the swing from those. Moving
-- anchored parts on the server would replicate a CFrame every frame per
-- part and still look choppy; a client tween is smooth and costs nothing
-- on the wire.
--
-- COLLISION. While a door is open, the server turns its solid parts'
-- CanCollide off (and restores them on close). Player characters are
-- simulated on their own client, which sees the door swung aside anyway,
-- but server-simulated rigs (NPCs) only see the server's copy - still
-- closed - and would otherwise walk into it. It only closes once nobody
-- is within closeRadius, so it never shuts on someone in the doorway.
--
-- A client can of course swing its own copy open; doors guard nothing,
-- so that's harmless (Ground Rule 1 is about state that matters).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local DoorLogic = require(ServerScriptService.Server.DoorLogic)

local TAG = "ProximityDoor"
local config = GameConfig.doors

type Door = {
	model: Model,
	center: DoorLogic.Vec3, -- closed position, fixed at registration
	normal: DoorLogic.Vec3, -- the closed panel's facing
	solid: { BasePart }, -- parts that collide when closed
	open: boolean,
}

local doors: { [Model]: Door } = {}

local function toVec3(v: Vector3): DoorLogic.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function register(instance: Instance)
	if not instance:IsA("Model") or doors[instance] then
		return
	end
	local hinge = instance:FindFirstChild("Hinge")
	if hinge == nil or not hinge:IsA("BasePart") then
		warn(`DoorService: {instance:GetFullName()} is tagged {TAG} but has no Hinge part - ignored`)
		return
	end
	local cf, size = instance:GetBoundingBox()
	-- The panel's thinnest horizontal axis is the way it faces.
	local normal = if size.X < size.Z then cf.RightVector else cf.LookVector
	local solid = {}
	for _, d in instance:GetDescendants() do
		if d:IsA("BasePart") and d ~= hinge and d.CanCollide then
			table.insert(solid, d)
		end
	end
	doors[instance] = {
		model = instance,
		center = toVec3(cf.Position),
		normal = toVec3(normal),
		solid = solid,
		open = false,
	}
	instance:SetAttribute("Open", false)
	instance:SetAttribute("OpenSide", 1)
end

local function unregister(instance: Instance)
	doors[instance :: Model] = nil
end

-- Everyone a door should react to: players, and NPC rigs when a round
-- has them (NPCService names them under Workspace.NPCs).
local function positions(): { DoorLogic.Vec3 }
	local list = {}
	local function add(model: Instance?)
		local root = if model then model:FindFirstChild("HumanoidRootPart") else nil
		if root ~= nil and root:IsA("BasePart") then
			table.insert(list, toVec3(root.Position))
		end
	end
	for _, player in Players:GetPlayers() do
		add(player.Character)
	end
	local npcs = Workspace:FindFirstChild("NPCs")
	if npcs ~= nil then
		for _, rig in npcs:GetChildren() do
			add(rig)
		end
	end
	return list
end

local function check()
	if next(doors) == nil then
		return
	end
	local here = positions()
	for model, door in doors do
		local open = DoorLogic.nextOpen(door.open, door.center, here, config.openRadius, config.closeRadius)
		if open == door.open then
			continue
		end
		door.open = open
		if open then
			local opener = DoorLogic.nearest(door.center, here)
			if opener ~= nil then
				model:SetAttribute("OpenSide", DoorLogic.swingSide(door.center, door.normal, opener))
			end
		end
		for _, part in door.solid do
			part.CanCollide = not open
		end
		model:SetAttribute("Open", open)
	end
end

local DoorService: Loader.Service = {
	name = "DoorService",
}

function DoorService:start()
	for _, instance in CollectionService:GetTagged(TAG) do
		register(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(register)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unregister)
	task.spawn(function()
		while true do
			task.wait(config.checkSeconds)
			check()
		end
	end)
end

return DoorService
