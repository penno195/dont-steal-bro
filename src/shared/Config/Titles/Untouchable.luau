--!strict
-- P4-2's title ladder, rung 7 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Untouchable: Validate.TitleDef = {
	id = "untouchable",
	displayName = "Untouchable",
	colorHex = "#f5c518",
	minStreak = 40,
}

return Untouchable
