--!strict
-- P4-2's title ladder, rung 9 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local ActualVillain: Validate.TitleDef = {
	id = "actual-villain",
	displayName = "Actual Villain",
	colorHex = "#ff4f9a",
	minStreak = 85,
	effect = "Pulse",
}

return ActualVillain
