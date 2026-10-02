--!strict
-- P4-2's title ladder, rung 15 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local TwentyDeep: Validate.TitleDef = {
	id = "twenty-deep",
	displayName = "Twenty Deep",
	colorHex = "#b85ad6",
	minStreak = 20,
}

return TwentyDeep
