--!strict
-- Payoff-loop step 9's lifetime titles: Wins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local NoLife: Validate.LifetimeTitleDef = {
	id = "no-life",
	displayName = "No Life",
	colorHex = "#e8a317",
	stat = "Wins",
	threshold = 250,
}

return NoLife
