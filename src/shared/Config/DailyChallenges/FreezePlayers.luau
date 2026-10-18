--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local FreezePlayers: Validate.DailyChallengeDef = {
	id = "freeze-players",
	enabled = true,
	displayName = "Freeze %d players",
	metric = "Hits",
	target = 5,
	powerUpId = "freeze",
	coins = 25,
	xp = 50,
}

return FreezePlayers
