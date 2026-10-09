--!strict
-- P4-2's title ladder, rung 4 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local NotAFluke: Validate.TitleDef = {
	id = "not-a-fluke",
	displayName = "Not A Fluke",
	colorHex = "#8fd18a",
	minStreak = 4,
}

return NotAFluke
