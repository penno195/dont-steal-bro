--!strict
-- P4-2's title ladder, rung 21 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local TouchGrass: Validate.TitleDef = {
	id = "touch-grass",
	displayName = "Touch Grass",
	colorHex = "#7cf03a",
	minStreak = 50,
	effect = "Rainbow",
}

return TouchGrass
