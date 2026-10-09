--!strict
-- P4-2's title ladder, rung 9 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local MainCharacter: Validate.TitleDef = {
	id = "main-character",
	displayName = "Main Character",
	colorHex = "#5ac4f0",
	minStreak = 9,
}

return MainCharacter
