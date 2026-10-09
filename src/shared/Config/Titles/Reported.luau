--!strict
-- P4-2's title ladder, rung 7 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Reported: Validate.TitleDef = {
	id = "reported",
	displayName = "Reported",
	colorHex = "#e8734a",
	minStreak = 7,
}

return Reported
