--!strict
-- Payoff-loop step 9's lifetime titles: StudioVisits ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local HasAKeycard: Validate.LifetimeTitleDef = {
	id = "has-a-keycard",
	displayName = "Has A Keycard",
	colorHex = "#347fec",
	stat = "StudioVisits",
	threshold = 400,
}

return HasAKeycard
