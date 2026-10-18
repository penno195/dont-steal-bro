--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local LandHits: Validate.DailyChallengeDef = {
	id = "land-hits",
	enabled = true,
	displayName = "Land %d power-ups on rivals",
	metric = "Hits",
	target = 5,
	coins = 25,
	xp = 50,
}

return LandHits
