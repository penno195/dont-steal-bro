--!strict
-- P4-2's title ladder, rung 6 of 10. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local CertifiedProblem: Validate.TitleDef = {
	id = "certified-problem",
	displayName = "Certified Problem",
	colorHex = "#e0465e",
	minStreak = 25,
}

return CertifiedProblem
