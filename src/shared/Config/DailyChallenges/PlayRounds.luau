--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local PlayRounds: Validate.DailyChallengeDef = {
	id = "play-rounds",
	enabled = true,
	displayName = "Play %d rounds",
	description = "Play %d ranked rounds all the way to the end. Practice rounds don't count.",
	metric = "RoundsPlayed",
	target = 3,
	coins = 25,
	xp = 50,
}

return PlayRounds
