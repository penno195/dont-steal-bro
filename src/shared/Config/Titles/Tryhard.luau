--!strict
-- P4-2's title ladder, rung 12 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Tryhard: Validate.TitleDef = {
	id = "tryhard",
	displayName = "Tryhard",
	colorHex = "#7a6af0",
	minStreak = 14,
}

return Tryhard
