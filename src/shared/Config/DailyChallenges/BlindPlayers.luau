--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local BlindPlayers: Validate.DailyChallengeDef = {
	id = "blind-players",
	enabled = true,
	displayName = "Blind %d players",
	metric = "Hits",
	target = 3,
	powerUpId = "blind",
	coins = 25,
	xp = 50,
}

return BlindPlayers
