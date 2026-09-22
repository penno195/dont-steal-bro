--!strict
-- P4-2's title ladder, rung 2 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local ThreeDeep: Validate.TitleDef = {
	id = "three-deep",
	displayName = "Three Deep",
	colorHex = "#6fbf73",
	minStreak = 3,
}

return ThreeDeep
