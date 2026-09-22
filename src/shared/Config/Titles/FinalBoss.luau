--!strict
-- P4-2's title ladder, rung 8 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local FinalBoss: Validate.TitleDef = {
	id = "final-boss",
	displayName = "Final Boss",
	colorHex = "#1fd1c3",
	minStreak = 60,
	effect = "Glow",
}

return FinalBoss
