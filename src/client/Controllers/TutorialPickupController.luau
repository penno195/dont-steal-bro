--!strict
-- The hub tutorial's personal pickup (tutorial v2, "Mess with rivals"):
-- drawn on this client only, at the position PracticeService sends its
-- owner (TutorialPickupState). Nobody else's client is told where it
-- is, so nobody else sees or takes it.
--
-- HubIntroController asks for it (`request`) when its card opens. The
-- client never says which item: the server picked one and gives it on
-- a claim it has measured itself; the item then arrives through
-- PowerUpInventoryChanged like any pickup.
--
-- CLAIMING: walking into it, as with the daily hunt's. The client asks
-- once it's well inside the claim radius (CLAIM_SHARE of it, so a laggy
-- position still lands inside the server's check).
--
-- Unlike the hunt's find, this one is meant to be found at once: a
-- shaft of light rises from it, the same as a race station's marker.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local PowerUpLogic = require(ReplicatedStorage.Shared.PowerUpLogic)

local CLAIM_SHARE = 0.6 -- of practicePickupClaimRadius, where the client asks
local CHECK_SECONDS = 0.2 -- how often it measures the distance
local RETRY_SECONDS = 3 -- an unanswered claim may be asked again after this
local BOB_HEIGHT = 0.3
local BOB_SPEED = 2.5
local SPIN_SPEED = 1.5 -- radians a second
local DROP = 3 -- the server sends the orb at root height; the floor is this far below
local ORB_STUDS = 2
local BEAM_HEIGHT = 30
local BEAM_WIDTH_BASE = 1.4
local BEAM_WIDTH_TOP = 0.3

local pickup: Model? = nil
local anchor: Vector3? = nil -- where the server measures the claim from
local claimedAt: number? = nil
local sinceCheck = 0

local function clear()
	if pickup ~= nil then
		pickup:Destroy()
		pickup = nil
	end
	anchor = nil
	claimedAt = nil
end

local function roleColor(powerUpId: string): Color3
	for _, entry in PowerUps do
		if entry.def.id == powerUpId then
			local rgb = PowerUpLogic.ROLE_RGB[entry.def.role]
			if rgb ~= nil then
				return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
			end
		end
	end
	return Color3.new(1, 1, 1)
end

-- A glowing orb in the item's role colour, with a fading shaft of light
-- above it so it reads from across the hub.
local function draw(position: Vector3, powerUpId: string)
	clear()
	local color = roleColor(powerUpId)
	local model = Instance.new("Model")
	model.Name = "TutorialPickup"

	local orb = Instance.new("Part")
	orb.Name = "Orb"
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(ORB_STUDS, ORB_STUDS, ORB_STUDS)
	orb.Material = Enum.Material.Neon
	orb.Color = color
	orb.Transparency = 0.15
	orb.Anchored = true
	orb.CanCollide = false
	orb.CanQuery = false
	orb.CanTouch = false
	orb.CastShadow = false
	orb.Parent = model

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 10
	light.Brightness = 2
	light.Parent = orb

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.3))
	sparkle.LightEmission = 1
	sparkle.Size = NumberSequence.new(0.3, 0)
	sparkle.Lifetime = NumberRange.new(0.6, 1)
	sparkle.Rate = 8
	sparkle.Speed = NumberRange.new(1, 2)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Parent = orb

	-- The shaft stands on its own still part, so the orb's bob and spin
	-- don't swing it.
	local base = Instance.new("Part")
	base.Name = "BeamBase"
	base.Size = Vector3.new(0.2, 0.2, 0.2)
	base.Transparency = 1
	base.Anchored = true
	base.CanCollide = false
	base.CanQuery = false
	base.CanTouch = false
	base.CFrame = CFrame.new(position - Vector3.new(0, DROP, 0))
	base.Parent = model
	local bottom = Instance.new("Attachment")
	bottom.Parent = base
	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, BEAM_HEIGHT, 0)
	top.Parent = base
	local beam = Instance.new("Beam")
	beam.Attachment0 = bottom
	beam.Attachment1 = top
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Width0 = BEAM_WIDTH_BASE
	beam.Width1 = BEAM_WIDTH_TOP
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new(color)
	beam.Transparency = NumberSequence.new(0.35, 1)
	beam.Parent = base

	model.PrimaryPart = orb
	model.Parent = Workspace
	pickup = model
	anchor = position
end

local function onStep(dt: number)
	local model, at = pickup, anchor
	if model == nil or at == nil then
		return
	end
	local t = os.clock()
	local orb = model.PrimaryPart :: BasePart
	orb.CFrame = CFrame.new(at + Vector3.new(0, math.sin(t * BOB_SPEED) * BOB_HEIGHT, 0))
		* CFrame.Angles(0, t * SPIN_SPEED, 0)

	sinceCheck += dt
	if sinceCheck < CHECK_SECONDS then
		return
	end
	sinceCheck = 0
	if claimedAt ~= nil and t - claimedAt < RETRY_SECONDS then
		return
	end
	local character = Players.LocalPlayer.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	if root == nil then
		return
	end
	if (root.Position - at).Magnitude <= GameConfig.tutorial.practicePickupClaimRadius * CLAIM_SHARE then
		claimedAt = t
		Net.fireServer("TutorialPickupIntent", { claim = true })
	end
end

local TutorialPickupController: Loader.Controller = {
	name = "TutorialPickupController",
	dependencies = {},
}

-- Asks for this player's pickup. The server answers only while the
-- tutorial is running for them, and the same pickup if asked again.
function TutorialPickupController.request()
	Net.fireServer("TutorialPickupIntent", { claim = false })
end

-- The tutorial ended (Skip, or it moved on): stop drawing it.
TutorialPickupController.clear = clear

function TutorialPickupController:start()
	Net.onClientEvent("TutorialPickupState", function(payload: any)
		local position = if type(payload) == "table" then payload.position else nil
		local powerUpId = if type(payload) == "table" then payload.powerUpId else nil
		if typeof(position) == "Vector3" and type(powerUpId) == "string" then
			draw(position, powerUpId)
		else
			clear()
		end
	end)
	RunService.RenderStepped:Connect(onStep)
end

return TutorialPickupController
