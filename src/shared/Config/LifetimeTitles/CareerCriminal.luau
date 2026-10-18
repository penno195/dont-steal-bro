--!strict
-- Payoff-loop step 9's lifetime titles: StealWins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local CareerCriminal: Validate.LifetimeTitleDef = {
	id = "career-criminal",
	displayName = "Career Criminal",
	colorHex = "#ec3030",
	stat = "StealWins",
	threshold = 150,
}

return CareerCriminal
