--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local LandHits: Validate.DailyChallengeDef = {
	id = "land-hits",
	enabled = true,
	displayName = "Land %d power-ups on rivals",
	description = "Hit rivals with your power-ups %d times in ranked rounds. Any power-up counts, as long as it lands on a rival.",
	metric = "Hits",
	target = 5,
	coins = 25,
	xp = 50,
}

return LandHits
