--!strict
-- Payoff-loop step 9's lifetime titles: StealWins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local RepeatOffender: Validate.LifetimeTitleDef = {
	id = "repeat-offender",
	displayName = "Repeat Offender",
	colorHex = "#e07474",
	stat = "StealWins",
	threshold = 10,
}

return RepeatOffender
