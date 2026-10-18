--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local WinRound: Validate.DailyChallengeDef = {
	id = "win-round",
	enabled = true,
	displayName = "Win a round",
	description = "Win a ranked round: reach the Decision Studio and come out a winner, so your streak goes up.",
	metric = "Wins",
	target = 1,
	coins = 40,
	xp = 75,
}

return WinRound
