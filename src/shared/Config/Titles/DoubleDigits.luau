--!strict
-- P4-2's title ladder, rung 4 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local DoubleDigits: Validate.TitleDef = {
	id = "double-digits",
	displayName = "Double Digits",
	colorHex = "#3aa7f0",
	minStreak = 10,
}

return DoubleDigits
