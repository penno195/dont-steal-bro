--!strict
-- Payoff-loop step 9's lifetime titles: Wins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Veteran: Validate.LifetimeTitleDef = {
	id = "veteran",
	displayName = "Veteran",
	colorHex = "#d4ae4f",
	stat = "Wins",
	threshold = 50,
}

return Veteran
