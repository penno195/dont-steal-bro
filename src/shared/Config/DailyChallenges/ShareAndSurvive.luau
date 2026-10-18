--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local ShareAndSurvive: Validate.DailyChallengeDef = {
	id = "share-and-survive",
	enabled = true,
	displayName = "Share and survive",
	metric = "SharedAndWon",
	target = 1,
	coins = 40,
	xp = 75,
}

return ShareAndSurvive
