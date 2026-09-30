--!strict
-- Spins and bobs each power-up pickup's model inside its orb, and
-- slowly breathes the force-field `Haze` shell around it. The server
-- clones the model in as `Visual` (PowerUpService.attachVisual) and
-- never moves either again, so client-side PivotTo/Size changes stick
-- and cost no replication. Purely cosmetic: the orb itself, which is
-- what gets touched and claimed, never moves or resizes.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)

local SPIN_RADIANS_PER_SECOND = math.rad(90)
local BOB_STUDS = 0.25
local BOB_RADIANS_PER_SECOND = 2.5
local BREATHE_FRACTION = 0.05 -- haze diameter swings +/- this much
local BREATHE_RADIANS_PER_SECOND = 1.6

local PickupController: Loader.Controller = {
	name = "PickupController",
}

function PickupController:start()
	RunService.RenderStepped:Connect(function()
		local folder = Workspace:FindFirstChild("PowerUpPickups")
		if folder == nil then
			return
		end
		local t = os.clock()
		local spin = CFrame.Angles(0, t * SPIN_RADIANS_PER_SECOND, 0)
		local bob = Vector3.new(0, math.sin(t * BOB_RADIANS_PER_SECOND) * BOB_STUDS, 0)
		local breathe = 1 + math.sin(t * BREATHE_RADIANS_PER_SECOND) * BREATHE_FRACTION
		for _, orb in folder:GetChildren() do
			if not orb:IsA("BasePart") then
				continue
			end
			local visual = orb:FindFirstChild("Visual")
			if visual ~= nil and visual:IsA("Model") then
				visual:PivotTo((orb.CFrame + bob) * spin)
			end
			local haze = orb:FindFirstChild("Haze")
			local base = if haze ~= nil then haze:GetAttribute("BaseDiameter") else nil
			if haze ~= nil and haze:IsA("BasePart") and typeof(base) == "number" then
				local d = base * breathe
				haze.Size = Vector3.new(d, d, d)
			end
		end
	end)
end

return PickupController
