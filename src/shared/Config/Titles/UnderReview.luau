--!strict
-- P4-2's title ladder, rung 8 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local UnderReview: Validate.TitleDef = {
	id = "under-review",
	displayName = "Under Review",
	colorHex = "#d9d24a",
	minStreak = 8,
}

return UnderReview
