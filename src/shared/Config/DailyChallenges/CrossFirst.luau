--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local CrossFirst: Validate.DailyChallengeDef = {
	id = "cross-first",
	enabled = true,
	displayName = "Cross the line first",
	metric = "FirstPlaces",
	target = 1,
	coins = 30,
	xp = 60,
}

return CrossFirst
