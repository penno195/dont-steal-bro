--!strict
-- Payoff-loop step 9's lifetime titles: StudioVisits ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Finalist: Validate.LifetimeTitleDef = {
	id = "finalist",
	displayName = "Finalist",
	colorHex = "#8fb3d9",
	stat = "StudioVisits",
	threshold = 10,
}

return Finalist
