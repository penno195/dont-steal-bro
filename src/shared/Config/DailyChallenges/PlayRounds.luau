--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local PlayRounds: Validate.DailyChallengeDef = {
	id = "play-rounds",
	enabled = true,
	displayName = "Play %d rounds",
	metric = "RoundsPlayed",
	target = 3,
	coins = 25,
	xp = 50,
}

return PlayRounds
