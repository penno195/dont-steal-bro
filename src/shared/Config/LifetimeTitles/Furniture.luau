--!strict
-- Payoff-loop step 9's lifetime titles: Wins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Furniture: Validate.LifetimeTitleDef = {
	id = "furniture",
	displayName = "Furniture",
	colorHex = "#f29a0c",
	stat = "Wins",
	threshold = 500,
}

return Furniture
