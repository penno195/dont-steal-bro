--!strict
-- A thrown power-up, as everyone sees it: a role-coloured orb lobbed
-- from the thrower's hand, homing on the target, and a small explosion
-- where it lands. The local player also feels both ends: a recoil kick
-- when they throw, and a shunt when one lands on them.
--
-- All cosmetic except the two shoves. The server picked the target and
-- applies the effect itself when the flight ends (PowerUpService's
-- THROWS section); this only draws it. The shoves happen here because a
-- player's client owns its own character's physics - the server sends
-- the shunt's velocity (PowerUpHitYou.shunt), and the recoil is the same
-- ThrowLogic sum over the same GameConfig numbers the server uses.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local PowerUpLogic = require(ReplicatedStorage.Shared.PowerUpLogic)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local ThrowLogic = require(ReplicatedStorage.Shared.ThrowLogic)
local Env = require(script.Parent.Parent.UI.Components.Env)

local player = Players.LocalPlayer
local selfId = player.UserId

-- How long a shove's force is held before the character is let go.
-- Long enough to beat the Humanoid's ground friction, short enough that
-- control comes straight back.
local SHOVE_SECONDS = 0.15
local RECOIL_SECONDS = 0.1
local PROJECTILE_SIZE = 1.1

local roleById: { [string]: string } = {}
for _, entry in PowerUps do
	roleById[entry.def.id] = entry.def.role
end

local fxFolder: Folder? = nil

local function folder(): Folder
	if fxFolder == nil or fxFolder.Parent == nil then
		local f = Instance.new("Folder")
		f.Name = "ThrowFX"
		f.Parent = Workspace
		fxFolder = f
	end
	return fxFolder :: Folder
end

local function roleColor(powerUpId: string): Color3
	local rgb = PowerUpLogic.ROLE_RGB[roleById[powerUpId] or ""]
	return if rgb then Color3.fromRGB(rgb[1], rgb[2], rgb[3]) else Color3.new(1, 1, 1)
end

local function characterFor(id: number): Model?
	return (Loader.get("EffectLabelController") :: any).characterFor(id)
end

local function rootOf(character: Model?): BasePart?
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

-- Where the orb leaves from: the right hand (R15) or arm (R6), else
-- chest height off the root.
local function handPosition(character: Model): Vector3?
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand ~= nil and hand:IsA("BasePart") then
		return hand.Position
	end
	local root = rootOf(character)
	return if root ~= nil then root.Position + Vector3.new(0, 1, 0) else nil
end

local function vec3(v: Vector3): ThrowLogic.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function fireFeel(moment: string)
	(Loader.get("FeelController") :: any).fire(moment)
end

-- SHOVES -------------------------------------------------------------

-- Holds `velocity` on the local character for `seconds`, then lets go
-- and leaves the momentum to the Humanoid. A plain velocity set is
-- eaten by ground friction within a frame or two.
local function shoveSelf(velocity: Vector3, seconds: number)
	local root = rootOf(player.Character)
	if root == nil or root.Anchored then
		return
	end
	local attachment = root:FindFirstChild("RootAttachment")
	if attachment == nil or not attachment:IsA("Attachment") then
		return
	end
	root.AssemblyLinearVelocity = velocity
	local force = Instance.new("LinearVelocity")
	force.Name = "ThrowShove"
	force.Attachment0 = attachment
	force.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.VectorVelocity = velocity
	force.MaxForce = root.AssemblyMass * 3000
	force.Parent = root
	task.delay(seconds, function()
		force:Destroy()
	end)
end

-- EXPLOSION ----------------------------------------------------------

local function explode(position: Vector3, color: Color3)
	local config = GameConfig.powerUpThrow
	local radius = config.explosionRadiusStuds
	local reduced = Env.reducedMotion()

	if not reduced then
		-- The stock blast, purely visual: no pressure, breaks no joints.
		local blast = Instance.new("Explosion")
		blast.BlastPressure = 0
		blast.BlastRadius = radius
		blast.DestroyJointRadiusPercent = 0
		blast.ExplosionType = Enum.ExplosionType.NoCraters
		blast.Position = position
		blast.Parent = folder()
	end

	-- A role-coloured shell that swells and fades - under reduced motion
	-- it only fades, in place.
	local shell = Instance.new("Part")
	shell.Name = "ThrowBlast"
	shell.Shape = Enum.PartType.Ball
	shell.Material = Enum.Material.Neon
	shell.Color = color
	shell.Anchored = true
	shell.CanCollide = false
	shell.CanQuery = false
	shell.CanTouch = false
	shell.CastShadow = false
	shell.Transparency = 0.25
	local startSize = if reduced then radius * 1.2 else 1
	shell.Size = Vector3.one * startSize
	shell.Position = position
	shell.Parent = folder()
	local tween = TweenService:Create(
		shell,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * radius * 2, Transparency = 1 }
	)
	if reduced then
		tween = TweenService:Create(shell, TweenInfo.new(0.3), { Transparency = 1 })
	end
	tween.Completed:Once(function()
		shell:Destroy()
	end)
	tween:Play()
end

-- PROJECTILE ---------------------------------------------------------

local function projectile(color: Color3): BasePart
	local orb = Instance.new("Part")
	orb.Name = "ThrowOrb"
	orb.Shape = Enum.PartType.Ball
	orb.Material = Enum.Material.Neon
	orb.Color = color
	orb.Size = Vector3.one * PROJECTILE_SIZE
	orb.Anchored = true
	orb.CanCollide = false
	orb.CanQuery = false
	orb.CanTouch = false
	orb.CastShadow = false

	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, PROJECTILE_SIZE * 0.35, 0)
	a0.Parent = orb
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -PROJECTILE_SIZE * 0.35, 0)
	a1.Parent = orb
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(color)
	trail.LightEmission = 0.8
	trail.Lifetime = 0.2
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.Parent = orb

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 8
	light.Brightness = 2
	light.Parent = orb
	return orb
end

local function onThrown(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local casterId, targetId, powerUpId, flight =
		payload.casterId, payload.targetId, payload.powerUpId, payload.flightSeconds
	if type(casterId) ~= "number" or type(targetId) ~= "number" or type(powerUpId) ~= "string" then
		return
	end
	if type(flight) ~= "number" or flight ~= flight then
		flight = 0
	end
	flight = math.clamp(flight, 0, 1)

	local caster = characterFor(casterId)
	local target = characterFor(targetId)
	local targetRoot = rootOf(target)
	local startPosition = if caster ~= nil then handPosition(caster) else nil
	if targetRoot == nil or startPosition == nil then
		return
	end
	local color = roleColor(powerUpId)

	-- The thrower's own kick.
	if casterId == selfId then
		local casterRoot = rootOf(caster)
		if casterRoot ~= nil then
			local v = ThrowLogic.recoilVelocity(
				vec3(casterRoot.Position),
				vec3(targetRoot.Position),
				vec3(casterRoot.CFrame.LookVector),
				GameConfig.powerUpThrow
			)
			shoveSelf(Vector3.new(v.x, v.y, v.z), RECOIL_SECONDS)
		end
		fireFeel("ThrowRecoil")
	end

	if flight <= 0 then
		explode(targetRoot.Position, color)
		return
	end

	local orb = projectile(color)
	orb.Position = startPosition
	orb.Parent = folder()
	local from = vec3(startPosition)
	local lastTarget = targetRoot.Position
	local startedAt = os.clock()
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		-- Homes on the target as it moves; if its rig vanished, finishes
		-- on the last place it was.
		if targetRoot.Parent ~= nil then
			lastTarget = targetRoot.Position
		end
		local alpha = (os.clock() - startedAt) / flight
		if alpha >= 1 then
			if connection ~= nil then
				connection:Disconnect()
			end
			orb:Destroy()
			explode(lastTarget, color)
			return
		end
		local p = ThrowLogic.arcPoint(from, vec3(lastTarget), alpha, GameConfig.powerUpThrow.arcHeightStuds)
		orb.Position = Vector3.new(p.x, p.y, p.z)
	end)
end

-- The shunt: the server only sends it for a hit that actually landed.
local function onHitYou(payload: any)
	if type(payload) ~= "table" or type(payload.shunt) ~= "table" then
		return
	end
	local s = payload.shunt
	if type(s.x) ~= "number" or type(s.y) ~= "number" or type(s.z) ~= "number" then
		return
	end
	shoveSelf(Vector3.new(s.x, s.y, s.z), SHOVE_SECONDS)
	fireFeel("Shunted")
end

-- CONTROLLER ---------------------------------------------------------

local ThrowController: Loader.Controller = {
	name = "ThrowController",
	dependencies = { "EffectLabelController", "FeelController" },
}

function ThrowController:init()
	Net.onClientEvent("PowerUpThrown", onThrown)
	Net.onClientEvent("PowerUpHitYou", onHitYou)
end

return ThrowController
