--!strict
-- How a debuffed racer looks while it lasts (PowerUpDef.victimLook), on
-- every screen, their own included: Frozen in a block of ice, Blinded in
-- a cloud of ink round the head, Ragdoll knocked flat. Fed by the same
-- StatusEffectsVisual broadcast as EffectLabelController, which drops
-- its word for a racer with a look.
--
-- All cosmetic. The server already holds the racer still (WalkSpeed 0)
-- and, for a Ragdoll, has already loosened the rig's joints
-- (server/Ragdoll.luau) so every client sees the same flop. The one
-- thing done here that isn't drawing: a ragdolled player's own client
-- puts its Humanoid in the Physics state, because a client owns its own
-- character's Humanoid and a walking Humanoid would hold the limp rig
-- upright. Skipping that gains a cheater nothing - they still can't move.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Env = require(script.Parent.Parent.UI.Components.Env)

local selfId = Players.LocalPlayer.UserId

local ICE = Color3.fromRGB(150, 215, 255)
local INK = Color3.fromRGB(25, 20, 35)

type Shown = { look: string, clear: () -> () }

-- Weak keys: a rig that's gone takes its entry with it.
local shown: { [Model]: Shown } = setmetatable({}, { __mode = "k" }) :: any

local fxFolder: Folder? = nil

local function folder(): Folder
	if fxFolder == nil or fxFolder.Parent == nil then
		local f = Instance.new("Folder")
		f.Name = "VictimLooks"
		f.Parent = Workspace
		fxFolder = f
	end
	return fxFolder :: Folder
end

local function fxPart(name: string, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Material = Enum.Material.Ice
	part.Color = color
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	return part
end

local function rootOf(character: Model): BasePart?
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

-- ===== the looks ============================================================

-- A translucent ice block welded round the rig, the body tinted icy
-- under it. It shatters when the freeze ends.
local function frozen(character: Model): () -> ()
	local root = rootOf(character)
	if root == nil then
		return function() end
	end
	local reduced = Env.reducedMotion()
	local boxCFrame, extents = character:GetBoundingBox()
	local size = Vector3.new(math.max(extents.X, 3), extents.Y, math.max(extents.Z, 3)) + Vector3.one * 0.6

	local block = fxPart("IceBlock", ICE)
	block.Transparency = 0.4
	block.Size = if reduced then size else size * 0.6
	block.CFrame = CFrame.new(boxCFrame.Position) * root.CFrame.Rotation
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = block
	weld.Part1 = root
	weld.Parent = block
	block.Parent = folder()
	if not reduced then
		TweenService:Create(block, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = size,
		}):Play()
	end

	local tint = Instance.new("Highlight")
	tint.Name = "FrozenTint"
	tint.Adornee = character
	tint.FillColor = ICE
	tint.FillTransparency = 0.5
	tint.OutlineColor = Color3.new(1, 1, 1)
	tint.OutlineTransparency = 0.4
	tint.DepthMode = Enum.HighlightDepthMode.Occluded
	tint.Parent = folder()

	return function()
		local at = block.Position
		block:Destroy()
		tint:Destroy()
		if reduced then
			return
		end
		for _ = 1, 6 do
			local shard = fxPart("IceShard", ICE)
			shard.Anchored = true
			shard.Size = Vector3.new(0.5, 0.5, 0.9)
			shard.Transparency = 0.3
			shard.CFrame = CFrame.new(at) * CFrame.Angles(math.random() * 6, math.random() * 6, 0)
			shard.Parent = folder()
			local angle = math.random() * 2 * math.pi
			local out = Vector3.new(math.cos(angle), 0, math.sin(angle)) * (2 + math.random() * 2)
			local tween = TweenService:Create(
				shard,
				TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ CFrame = CFrame.new(at + out - Vector3.new(0, 2, 0)), Transparency = 1 }
			)
			tween.Completed:Once(function()
				shard:Destroy()
			end)
			tween:Play()
		end
	end
end

-- A swirl of dark ink round the head.
local function blinded(character: Model): () -> ()
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return function() end
	end
	local anchor = Instance.new("Attachment")
	anchor.Name = "BlindInk"
	anchor.Parent = head
	local ink = Instance.new("ParticleEmitter")
	ink.Color = ColorSequence.new(INK)
	ink.LightEmission = 0
	ink.LightInfluence = 1
	ink.Rate = if Env.reducedMotion() then 8 else 24
	ink.Lifetime = NumberRange.new(0.6, 0.9)
	ink.Speed = NumberRange.new(0.5, 1.5)
	ink.SpreadAngle = Vector2.new(180, 180)
	ink.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 2.2),
		NumberSequenceKeypoint.new(1, 1.5),
	})
	ink.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(0.3, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	ink.RotSpeed = NumberRange.new(-90, 90)
	ink.Parent = anchor
	return function()
		-- Let the cloud already out drift away rather than pop.
		ink.Enabled = false
		task.delay(1, function()
			anchor:Destroy()
		end)
	end
end

-- The rig's joints are the server's; this is only the owner's Humanoid.
local function ragdoll(character: Model, isSelf: boolean): () -> ()
	if not isSelf then
		return function() end
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return function() end
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	return function()
		if humanoid.Parent ~= nil and humanoid.Health > 0 then
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end
end

local function draw(character: Model, look: string, isSelf: boolean): () -> ()
	if look == "Frozen" then
		return frozen(character)
	elseif look == "Blinded" then
		return blinded(character)
	elseif look == "Ragdoll" then
		return ragdoll(character, isSelf)
	end
	return function() end
end

local function setLook(character: Model, look: string?, isSelf: boolean)
	local current = shown[character]
	if current ~= nil and current.look == look then
		return
	end
	if current ~= nil then
		shown[character] = nil
		current.clear()
	end
	if look ~= nil then
		shown[character] = { look = look, clear = draw(character, look, isSelf) }
	end
end

local VictimLookController: Loader.Controller = {
	name = "VictimLookController",
	dependencies = { "EffectLabelController" },
}

function VictimLookController:init()
	Net.onClientEvent("StatusEffectsVisual", function(payload: any)
		if type(payload) ~= "table" or type(payload.playerId) ~= "number" then
			return
		end
		local character = (Loader.get("EffectLabelController") :: any).characterFor(payload.playerId) :: Model?
		if character == nil then
			return
		end
		local look = if type(payload.look) == "string" then payload.look else nil
		setLook(character, look, payload.playerId == selfId)
	end)
end

return VictimLookController
