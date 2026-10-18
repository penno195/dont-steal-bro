--!strict
-- Payoff-loop step 9's lifetime titles: StudioVisits ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local KnowsTheWay: Validate.LifetimeTitleDef = {
	id = "knows-the-way",
	displayName = "Knows The Way",
	colorHex = "#4f92e6",
	stat = "StudioVisits",
	threshold = 150,
}

return KnowsTheWay
