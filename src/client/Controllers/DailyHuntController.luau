--!strict
-- The daily hunt's pickup (design-decisions.md Q1, "the daily hunt"):
-- drawn on this client only, at the position DailyHuntService sends its
-- owner (DailyHuntState). Nobody else's client is ever told where it is.
--
-- CLAIMING: walking into it. The client asks once it's well inside
-- GameConfig.dailyHunt.claimRadius (CLAIM_SHARE of it, so a laggy
-- position still lands inside the server's check) and the server
-- decides. What it paid arrives as DailyHuntResult, shown as a toast;
-- the coins or stock themselves arrive through StoreState.
--
-- WHEN: whenever the server sends a position, which it only does on a
-- hub server. A nil position (claimed, or a new day with no spots)
-- removes the pickup.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local C = require(script.Parent.Parent.UI.Components)

local CLAIM_SHARE = 0.6 -- of claimRadius, where the client asks
local CHECK_SECONDS = 0.2 -- how often it measures the distance
local RETRY_SECONDS = 3 -- an unanswered claim may be asked again after this
local BOB_HEIGHT = 0.4
local BOB_SPEED = 2
local SPIN_SPEED = 1.2 -- radians a second
local LIFT = 2.5 -- studs above the spot's centre
local COLOUR = Color3.fromRGB(255, 200, 60)

local pickup: Model? = nil
local anchor: Vector3? = nil
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

-- A small spinning gem with a light: a find, not a beacon, so no
-- billboard and no beam - it has to be looked for.
local function draw(position: Vector3)
	clear()
	local model = Instance.new("Model")
	model.Name = "DailyHuntPickup"

	local gem = Instance.new("Part")
	gem.Name = "Gem"
	gem.Shape = Enum.PartType.Ball
	gem.Size = Vector3.new(1.4, 1.4, 1.4)
	gem.Material = Enum.Material.Neon
	gem.Color = COLOUR
	gem.Anchored = true
	gem.CanCollide = false
	gem.CanQuery = false
	gem.CanTouch = false
	gem.CastShadow = false
	gem.Parent = model

	local light = Instance.new("PointLight")
	light.Color = COLOUR
	light.Range = 8
	light.Brightness = 1.5
	light.Parent = gem

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Color = ColorSequence.new(COLOUR)
	sparkle.LightEmission = 1
	sparkle.Size = NumberSequence.new(0.25, 0)
	sparkle.Lifetime = NumberRange.new(0.6, 1)
	sparkle.Rate = 6
	sparkle.Speed = NumberRange.new(1, 2)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Parent = gem

	model.PrimaryPart = gem
	model.Parent = Workspace
	pickup = model
	anchor = position + Vector3.new(0, LIFT, 0)
end

local function powerUpName(id: string?): string
	for _, entry in PowerUps do
		if entry.def.id == id then
			return entry.def.displayName
		end
	end
	return "power-up"
end

local function onStep(dt: number)
	local model, at = pickup, anchor
	if model == nil or at == nil then
		return
	end
	local t = os.clock()
	model:PivotTo(
		CFrame.new(at + Vector3.new(0, math.sin(t * BOB_SPEED) * BOB_HEIGHT, 0)) * CFrame.Angles(0, t * SPIN_SPEED, 0)
	)

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
	-- Measured from the spot itself, as the server does, not the lifted gem.
	if (root.Position - (at - Vector3.new(0, LIFT, 0))).Magnitude <= GameConfig.dailyHunt.claimRadius * CLAIM_SHARE then
		claimedAt = t
		Net.fireServer("DailyHuntClaim", {})
	end
end

local DailyHuntController: Loader.Controller = {
	name = "DailyHuntController",
	dependencies = { "AudioController" },
}

function DailyHuntController:start()
	Net.onClientEvent("DailyHuntState", function(payload: any)
		local position = if type(payload) == "table" then payload.position else nil
		if typeof(position) == "Vector3" then
			draw(position)
		else
			clear()
		end
	end)

	Net.onClientEvent("DailyHuntResult", function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		clear()
		local text = if payload.kind == "PowerUpStock"
			then string.format("Daily find: a %s!", powerUpName(payload.powerUpId))
			else string.format("Daily find: +%d coins!", tonumber(payload.amount) or 0)
		C.Toast.show(text, "success")
		Loader.get("AudioController").play("PowerUpPickup")
	end)

	RunService.RenderStepped:Connect(onStep)
end

return DailyHuntController
