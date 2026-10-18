--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local ReachStudio: Validate.DailyChallengeDef = {
	id = "reach-studio",
	enabled = true,
	displayName = "Reach the Studio %d times",
	description = "Finish in the top 3 to get a seat in the Decision Studio, %d times today.",
	metric = "StudioVisits",
	target = 2,
	coins = 30,
	xp = 60,
}

return ReachStudio
