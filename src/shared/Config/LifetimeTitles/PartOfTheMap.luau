--!strict
-- Payoff-loop step 9's lifetime titles: Wins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local PartOfTheMap: Validate.LifetimeTitleDef = {
	id = "part-of-the-map",
	displayName = "Part Of The Map",
	colorHex = "#ff8c00",
	stat = "Wins",
	threshold = 1000,
}

return PartOfTheMap
