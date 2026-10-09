--!strict
-- Animates decorative conveyor lines. Purely cosmetic and client-side:
-- the server never moves any of these parts, so nothing here touches
-- gameplay, and MovementWatch has nothing to see (wave 1 forbids moving
-- floors, so the belt never carries anyone; its own parts stay still and
-- only client-made slats scroll across its top).
--
-- A map opts in with tags, no code (all parts anchored):
--   ConveyorBelt  the belt part. It runs along its own +X axis, top face
--                 up (rotate the part 180 to reverse it). Attributes:
--                 Speed (studs/s, default SPEED), DwellSeconds (stop per
--                 stamp, default DWELL).
--   ConveyorItem  a part sitting on a belt (a carton). It rides the belt
--                 and wraps from the far end back to the start.
--   ConveyorPress a press ram above a belt. Whenever an item reaches a
--                 press the whole belt stops; every press with an item
--                 under it slams down onto it, flashes, and lifts, and
--                 then the belt indexes on.
-- Items and presses belong to the belt whose top face they sit over, so
-- one map can have several lines.
--
-- STREAMING. Tagged parts can arrive in any order and leave again, so
-- items and presses are kept in flat sets and matched to a belt every
-- frame (cheap: a handful of parts), never at registration.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)

local BELT_TAG = "ConveyorBelt"
local ITEM_TAG = "ConveyorItem"
local PRESS_TAG = "ConveyorPress"

local SPEED = 6 -- studs/s
local DWELL = 1.0 -- seconds the belt stands still per stamp
local SLAT_SPACING = 3 -- studs between the scrolling slats
local SLAT_COLOR = Color3.fromRGB(38, 40, 44)
local LIGHT_COLOR = Color3.fromRGB(255, 196, 120)
local LIGHT_BRIGHTNESS = 6
-- Only animate a belt someone could plausibly see. Past this the line
-- freezes where it is, which costs nothing on a cheap phone.
local ACTIVE_RANGE = 260

local SLAM = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local LIFT = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GLOW_OUT = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOLD = 0.25 -- seconds the ram rests on the carton

type Belt = {
	part: BasePart,
	offset: number, -- studs the belt has run since it was registered (mod length)
	pausedUntil: number,
	slats: { BasePart },
	slatCFrames: { CFrame },
}

type Item = {
	along: number, -- distance from the belt's start at offset 0
	belt: Belt?,
}

type Press = {
	rest: CFrame,
	light: PointLight,
	sparks: ParticleEmitter,
	busy: boolean,
}

local belts: { [BasePart]: Belt } = {}
local items: { [BasePart]: Item } = {}
local presses: { [BasePart]: Press } = {}

local function speedOf(belt: Belt): number
	local speed = belt.part:GetAttribute("Speed")
	return if type(speed) == "number" and speed > 0 then speed else SPEED
end

local function dwellOf(belt: Belt): number
	local dwell = belt.part:GetAttribute("DwellSeconds")
	return if type(dwell) == "number" and dwell >= 0 then dwell else DWELL
end

-- The belt-space coordinates of a world point: x along the run measured
-- from the belt's start (its -X end), and whether the point sits over
-- the belt's top face.
local function project(belt: BasePart, point: Vector3): (number, boolean)
	local localPoint = belt.CFrame:PointToObjectSpace(point)
	local size = belt.Size
	local over = math.abs(localPoint.Z) <= size.Z / 2 and localPoint.Y >= 0 and math.abs(localPoint.X) <= size.X / 2 + 1
	return localPoint.X + size.X / 2, over
end

local function findBelt(point: Vector3): Belt?
	for _, belt in belts do
		local _, over = project(belt.part, point)
		if over then
			return belt
		end
	end
	return nil
end

-- Where an item is drawn: its spawn position plus the belt's run, wrapped
-- to the belt's length. `along` is fixed at registration.
local function itemAlong(belt: Belt, item: Item): number
	return (item.along + belt.offset) % belt.part.Size.X
end

local function itemCFrame(belt: Belt, part: BasePart, along: number): CFrame
	local beltCF = belt.part.CFrame
	local localPoint = beltCF:PointToObjectSpace(part.Position)
	local shifted = Vector3.new(along - belt.part.Size.X / 2, localPoint.Y, localPoint.Z)
	return part.CFrame.Rotation + beltCF:PointToWorldSpace(shifted)
end

local function makeSlats(belt: Belt)
	local part = belt.part
	local count = math.floor(part.Size.X / SLAT_SPACING)
	for i = 1, count do
		local slat = Instance.new("Part")
		slat.Name = "ClientSlat"
		slat.Anchored = true
		slat.CanCollide = false
		slat.CanQuery = false
		slat.CanTouch = false
		slat.CastShadow = false
		slat.Material = Enum.Material.SmoothPlastic
		slat.Color = SLAT_COLOR
		slat.Size = Vector3.new(0.35, 0.05, part.Size.Z - 0.6)
		slat.Parent = part
		belt.slats[i] = slat
		belt.slatCFrames[i] = CFrame.identity
	end
end

local function placeSlats(belt: Belt)
	local part = belt.part
	local length = part.Size.X
	local top = part.Size.Y / 2 + 0.03
	local shift = belt.offset % SLAT_SPACING
	for i, _ in belt.slats do
		local along = ((i - 1) * SLAT_SPACING + shift) % length
		belt.slatCFrames[i] = part.CFrame * CFrame.new(along - length / 2, top, 0)
	end
	Workspace:BulkMoveTo(belt.slats, belt.slatCFrames, Enum.BulkMoveMode.FireCFrameChanged)
end

local function registerBelt(instance: Instance)
	if not instance:IsA("BasePart") or belts[instance] then
		return
	end
	local belt: Belt = { part = instance, offset = 0, pausedUntil = 0, slats = {}, slatCFrames = {} }
	belts[instance] = belt
	makeSlats(belt)
	placeSlats(belt)
	-- Items that streamed in first measured nothing; rematch them.
	for part, item in items do
		if item.belt == nil then
			local along, over = project(instance, part.Position)
			if over then
				item.along, item.belt = along, belt
			end
		end
	end
end

local function unregisterBelt(instance: Instance)
	local belt = belts[instance :: BasePart]
	if belt == nil then
		return
	end
	belts[instance :: BasePart] = nil
	for _, slat in belt.slats do
		slat:Destroy()
	end
	for _, item in items do
		if item.belt == belt then
			item.belt = nil
		end
	end
end

local function registerItem(instance: Instance)
	if not instance:IsA("BasePart") or items[instance] then
		return
	end
	-- Locally only, so a carton can never snag the local character while
	-- it travels; the server's copy (where it never moves) is unchanged.
	instance.CanCollide = false
	local item: Item = { along = 0, belt = nil }
	local belt = findBelt(instance.Position)
	if belt then
		-- Undo the belt's run so far: the part arrives at its spawn pose.
		item.along = (project(belt.part, instance.Position) - belt.offset) % belt.part.Size.X
		item.belt = belt
	end
	items[instance] = item
end

local function registerPress(instance: Instance)
	if not instance:IsA("BasePart") or presses[instance] then
		return
	end
	local light = Instance.new("PointLight")
	light.Color = LIGHT_COLOR
	light.Brightness = 0
	light.Range = 14
	light.Shadows = false
	light.Parent = instance

	local attachment = Instance.new("Attachment")
	attachment.Name = "ClientSparks"
	attachment.Position = Vector3.new(0, -instance.Size.Y / 2, 0)
	attachment.Parent = instance
	local sparks = Instance.new("ParticleEmitter")
	sparks.Enabled = false
	sparks.Color = ColorSequence.new(LIGHT_COLOR)
	sparks.LightEmission = 1
	sparks.Lifetime = NumberRange.new(0.2, 0.4)
	sparks.Speed = NumberRange.new(8, 14)
	sparks.SpreadAngle = Vector2.new(80, 80)
	sparks.Size = NumberSequence.new(0.25, 0)
	sparks.Acceleration = Vector3.new(0, -60, 0)
	sparks.Parent = attachment

	presses[instance] = { rest = instance.CFrame, light = light, sparks = sparks, busy = false }
end

local function unregisterItem(instance: Instance)
	items[instance :: BasePart] = nil
end

local function unregisterPress(instance: Instance)
	presses[instance :: BasePart] = nil
end

local function stamp(part: BasePart, press: Press, itemTop: number)
	press.busy = true
	local drop = (press.rest.Position.Y - part.Size.Y / 2) - itemTop
	local down = press.rest - Vector3.new(0, math.max(drop, 0), 0)
	local slam = TweenService:Create(part, SLAM, { CFrame = down })
	slam.Completed:Once(function()
		press.light.Brightness = LIGHT_BRIGHTNESS
		press.sparks:Emit(10)
		TweenService:Create(press.light, GLOW_OUT, { Brightness = 0 }):Play()
		task.delay(HOLD, function()
			if part.Parent == nil then
				return
			end
			local lift = TweenService:Create(part, LIFT, { CFrame = press.rest })
			lift.Completed:Once(function()
				press.busy = false
			end)
			lift:Play()
		end)
	end)
	slam:Play()
end

-- Every press on this belt with an item right under it stamps that item.
local function stampAll(belt: Belt)
	local length = belt.part.Size.X
	for part, press in presses do
		if press.busy then
			continue
		end
		local pressAlong, over = project(belt.part, part.Position)
		if not over then
			continue
		end
		for itemPart, item in items do
			local gap = (itemAlong(belt, item) - pressAlong) % length
			if item.belt == belt and math.min(gap, length - gap) < 0.05 then
				stamp(part, press, itemPart.Position.Y + itemPart.Size.Y / 2)
				break
			end
		end
	end
end

-- The smallest run (> 0, ≤ limit) that brings some item exactly under
-- some press, or nil if none does within limit.
local function nextStop(belt: Belt, limit: number): number?
	local length = belt.part.Size.X
	local best: number? = nil
	for part, _ in presses do
		local pressAlong, over = project(belt.part, part.Position)
		if not over then
			continue
		end
		for _, item in items do
			if item.belt ~= belt then
				continue
			end
			local gap = (pressAlong - itemAlong(belt, item)) % length
			if gap > 1e-3 and gap <= limit and (best == nil or gap < best) then
				best = gap
			end
		end
	end
	return best
end

local function step(dt: number)
	local now = os.clock()
	local camera = Workspace.CurrentCamera
	local focus = if camera then camera.CFrame.Position else Vector3.zero
	for _, belt in belts do
		if now < belt.pausedUntil then
			continue
		end
		local part = belt.part
		local nearest = part.CFrame:PointToObjectSpace(focus)
		local outside = math.max(math.abs(nearest.X) - part.Size.X / 2, 0)
		if outside + math.abs(nearest.Z) > ACTIVE_RANGE then
			continue
		end

		local run = speedOf(belt) * dt
		local stop = nextStop(belt, run)
		if stop then
			run = stop
			belt.pausedUntil = now + dwellOf(belt)
		end
		belt.offset = (belt.offset + run) % part.Size.X

		local moved: { BasePart } = {}
		local poses: { CFrame } = {}
		for itemPart, item in items do
			if item.belt == belt then
				table.insert(moved, itemPart)
				table.insert(poses, itemCFrame(belt, itemPart, itemAlong(belt, item)))
			end
		end
		Workspace:BulkMoveTo(moved, poses, Enum.BulkMoveMode.FireCFrameChanged)
		placeSlats(belt)

		if belt.pausedUntil > now then
			stampAll(belt)
		end
	end
end

local ConveyorController: Loader.Controller = {
	name = "ConveyorController",
}

function ConveyorController:start()
	for _, instance in CollectionService:GetTagged(BELT_TAG) do
		registerBelt(instance)
	end
	CollectionService:GetInstanceAddedSignal(BELT_TAG):Connect(registerBelt)
	CollectionService:GetInstanceRemovedSignal(BELT_TAG):Connect(unregisterBelt)

	for _, instance in CollectionService:GetTagged(ITEM_TAG) do
		registerItem(instance)
	end
	CollectionService:GetInstanceAddedSignal(ITEM_TAG):Connect(registerItem)
	CollectionService:GetInstanceRemovedSignal(ITEM_TAG):Connect(unregisterItem)

	for _, instance in CollectionService:GetTagged(PRESS_TAG) do
		registerPress(instance)
	end
	CollectionService:GetInstanceAddedSignal(PRESS_TAG):Connect(registerPress)
	CollectionService:GetInstanceRemovedSignal(PRESS_TAG):Connect(unregisterPress)

	RunService.RenderStepped:Connect(step)
end

return ConveyorController
