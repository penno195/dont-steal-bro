--!strict
-- P4-2's title ladder, rung 10 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local TouchGrass: Validate.TitleDef = {
	id = "touch-grass",
	displayName = "Touch Grass",
	colorHex = "#7cf03a",
	minStreak = 120,
	effect = "Rainbow",
}

return TouchGrass
