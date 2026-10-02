--!strict
-- P4-2's title ladder, rung 11 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Sweaty: Validate.TitleDef = {
	id = "sweaty",
	displayName = "Sweaty",
	colorHex = "#4a8ff0",
	minStreak = 12,
}

return Sweaty
