--!strict
-- Animates proximity doors (DoorService decides; this only draws). Each
-- ProximityDoor Model's parts swing about its Hinge part's up axis to
-- OpenSide * openAngle when the Open attribute is true, and back to 0
-- when it isn't. The Model's own OpenAngle attribute (degrees) overrides
-- GameConfig.doors.openAngle, for a door that hits a wall at 95.
--
-- Parts are anchored and moved locally, so every client sees its own
-- smooth tween; the server never moves them (see DoorService "SPLIT").

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)

local TAG = "ProximityDoor"
local config = GameConfig.doors
local SWING = TweenInfo.new(config.swingSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- STREAMING. With StreamingEnabled a door's parts can reach this client
-- after its tag does, in any order, and leave again. So parts are
-- tracked as they arrive: each is recorded in its closed pose (the
-- server never moves them, so that's how every part arrives) and then
-- posed at the current angle. Nothing assumes the hinge came first.
type Door = {
	hinge: BasePart?,
	closed: { [BasePart]: CFrame }, -- each part's closed, world-space pose
	angle: NumberValue, -- degrees; tweened, applied on Changed
	tween: Tween?,
	connections: { RBXScriptConnection },
}

local doors: { [Model]: Door } = {}

local function pose(door: Door, part: BasePart, closedPose: CFrame)
	local hinge = door.hinge
	if hinge == nil then
		return
	end
	local pivot = hinge.CFrame
	part.CFrame = pivot * CFrame.Angles(0, math.rad(door.angle.Value), 0) * pivot:ToObjectSpace(closedPose)
end

local function apply(door: Door)
	for part, closedPose in door.closed do
		pose(door, part, closedPose)
	end
end

local function track(model: Model, door: Door, d: Instance)
	if not d:IsA("BasePart") then
		return
	end
	if d.Name == "Hinge" and d.Parent == model then
		door.hinge = d
		apply(door)
	elseif not door.closed[d] then
		door.closed[d] = d.CFrame
		pose(door, d, d.CFrame)
	end
end

local function target(model: Model): number
	if model:GetAttribute("Open") ~= true then
		return 0
	end
	local side = model:GetAttribute("OpenSide")
	local angle = model:GetAttribute("OpenAngle")
	local degrees = if type(angle) == "number" then angle else config.openAngle
	return (if side == -1 then -1 else 1) * degrees
end

local function swingTo(model: Model, door: Door)
	if door.tween ~= nil then
		door.tween:Cancel()
	end
	local tween = TweenService:Create(door.angle, SWING, { Value = target(model) })
	door.tween = tween
	tween:Play()
end

local function register(instance: Instance)
	if not instance:IsA("Model") or doors[instance] then
		return
	end
	local door: Door = {
		hinge = nil,
		closed = {},
		angle = Instance.new("NumberValue"),
		tween = nil,
		connections = {},
	}
	doors[instance] = door
	-- Joining while a door is already open: snap, don't swing from shut.
	door.angle.Value = target(instance)
	for _, d in instance:GetDescendants() do
		track(instance, door, d)
	end
	table.insert(
		door.connections,
		instance.DescendantAdded:Connect(function(d)
			track(instance, door, d)
		end)
	)
	table.insert(
		door.connections,
		instance.DescendantRemoving:Connect(function(d)
			if d == door.hinge then
				door.hinge = nil
			elseif d:IsA("BasePart") then
				door.closed[d] = nil
			end
		end)
	)
	table.insert(
		door.connections,
		door.angle.Changed:Connect(function()
			apply(door)
		end)
	)
	table.insert(
		door.connections,
		instance:GetAttributeChangedSignal("Open"):Connect(function()
			swingTo(instance, door)
		end)
	)
end

local function unregister(instance: Instance)
	local door = doors[instance :: Model]
	if door == nil then
		return
	end
	doors[instance :: Model] = nil
	if door.tween ~= nil then
		door.tween:Cancel()
	end
	for _, c in door.connections do
		c:Disconnect()
	end
	door.angle:Destroy()
end

local DoorController: Loader.Controller = {
	name = "DoorController",
}

function DoorController:start()
	for _, instance in CollectionService:GetTagged(TAG) do
		register(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(register)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unregister)
end

return DoorController
