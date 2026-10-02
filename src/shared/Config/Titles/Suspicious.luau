--!strict
-- P4-2's title ladder, rung 6 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Suspicious: Validate.TitleDef = {
	id = "suspicious",
	displayName = "Suspicious",
	colorHex = "#e8b04a",
	minStreak = 6,
}

return Suspicious
