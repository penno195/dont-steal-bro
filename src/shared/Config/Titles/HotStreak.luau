--!strict
-- P4-2's title ladder, rung 3 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local HotStreak: Validate.TitleDef = {
	id = "hot-streak",
	displayName = "Hot Streak",
	colorHex = "#f0913a",
	minStreak = 5,
}

return HotStreak
