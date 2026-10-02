--!strict
-- P4-2's title ladder, rung 2 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local BackToBack: Validate.TitleDef = {
	id = "back-to-back",
	displayName = "Back To Back",
	colorHex = "#a9b8a0",
	minStreak = 2,
}

return BackToBack
