--!strict
-- P4-2's title ladder, rung 17 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local AllegedlyLegit: Validate.TitleDef = {
	id = "allegedly-legit",
	displayName = "Allegedly Legit",
	colorHex = "#f07a5a",
	minStreak = 30,
}

return AllegedlyLegit
