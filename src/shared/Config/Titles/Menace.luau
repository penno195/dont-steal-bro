--!strict
-- P4-2's title ladder, rung 5 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Menace: Validate.TitleDef = {
	id = "menace",
	displayName = "Menace",
	colorHex = "#c65ad6",
	minStreak = 15,
}

return Menace
