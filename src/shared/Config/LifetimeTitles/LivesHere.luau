--!strict
-- Payoff-loop step 9's lifetime titles: StudioVisits ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local LivesHere: Validate.LifetimeTitleDef = {
	id = "lives-here",
	displayName = "Lives Here",
	colorHex = "#1f6bf2",
	stat = "StudioVisits",
	threshold = 1000,
}

return LivesHere
