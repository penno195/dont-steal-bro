--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local ReachStudio: Validate.DailyChallengeDef = {
	id = "reach-studio",
	enabled = true,
	displayName = "Reach the Studio %d times",
	metric = "StudioVisits",
	target = 2,
	coins = 30,
	xp = 60,
}

return ReachStudio
