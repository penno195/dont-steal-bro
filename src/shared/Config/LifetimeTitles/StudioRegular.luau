--!strict
-- Payoff-loop step 9's lifetime titles: StudioVisits ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StudioRegular: Validate.LifetimeTitleDef = {
	id = "studio-regular",
	displayName = "Studio Regular",
	colorHex = "#6fa3e0",
	stat = "StudioVisits",
	threshold = 50,
}

return StudioRegular
