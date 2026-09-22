--!strict
-- P4-2's title ladder, rung 1 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local GotOne: Validate.TitleDef = {
	id = "got-one",
	displayName = "Got One",
	colorHex = "#9aa5b1",
	minStreak = 1,
}

return GotOne
