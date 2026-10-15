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
-- It looks exactly like a race pickup (Shared/PickupLook: force-field
-- shell, lights, the item's icon inside), and it goes in the
-- PowerUpPickups folder when the hub has one so PickupController spins
-- and breathes it like the rest. Unlike the hunt's find, this one is
-- meant to be found at once: a shaft of light rises from it, the same
-- as a race station's marker.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local PickupLook = require(ReplicatedStorage.Shared.PickupLook)

local CLAIM_SHARE = 0.6 -- of practicePickupClaimRadius, where the client asks
local CHECK_SECONDS = 0.2 -- how often it measures the distance
local RETRY_SECONDS = 3 -- an unanswered claim may be asked again after this
local BEAM_START = 2.4 -- above the orb centre: the shell's top, so the shaft never crosses the icon
local BEAM_HEIGHT = 30
local BEAM_WIDTH_BASE = 1.4
local BEAM_WIDTH_TOP = 0.3

local pickup: BasePart? = nil -- the orb (PickupLook)
local shaft: BasePart? = nil -- the light beam's still base
local anchor: Vector3? = nil -- where the server measures the claim from
local claimedAt: number? = nil
local sinceCheck = 0

local function clear()
	if pickup ~= nil then
		pickup:Destroy()
		pickup = nil
	end
	if shaft ~= nil then
		shaft:Destroy()
		shaft = nil
	end
	anchor = nil
	claimedAt = nil
end

local function roleColor(powerUpId: string): Color3
	for _, entry in PowerUps do
		if entry.def.id == powerUpId then
			return PickupLook.roleColor(entry.def.role)
		end
	end
	return Color3.new(1, 1, 1)
end

-- The race pickup's look, in the item's role colour, with a fading
-- shaft of light above it so it reads from across the hub.
local function draw(position: Vector3, powerUpId: string)
	clear()
	local color = roleColor(powerUpId)
	local models = ReplicatedStorage:FindFirstChild("TutorialPickupModels")
	local orb = PickupLook.build(CFrame.new(position))
	orb.Name = "TutorialPickup"
	orb.CanTouch = false
	orb.CanQuery = false
	PickupLook.show(orb, color, if models ~= nil then models:FindFirstChild(powerUpId) else nil)

	-- The shaft rises from the shell's top on its own still part, so it
	-- never washes over the icon and the orb's spin doesn't swing it.
	local base = Instance.new("Part")
	base.Name = "TutorialPickupBeam"
	base.Size = Vector3.new(0.2, 0.2, 0.2)
	base.Transparency = 1
	base.Anchored = true
	base.CanCollide = false
	base.CanQuery = false
	base.CanTouch = false
	base.CFrame = CFrame.new(position + Vector3.new(0, BEAM_START, 0))
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
	base.Parent = Workspace

	orb.Parent = Workspace:FindFirstChild("PowerUpPickups") or Workspace
	pickup = orb
	shaft = base
	anchor = position
end

local function onStep(dt: number)
	local at = anchor
	if pickup == nil or at == nil then
		return
	end
	local t = os.clock()

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
