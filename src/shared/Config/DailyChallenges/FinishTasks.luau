--!strict
-- A daily challenge (payoff-loop step 8). See init.luau for the set.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local FinishTasks: Validate.DailyChallengeDef = {
	id = "finish-tasks",
	enabled = true,
	displayName = "Finish %d tasks",
	metric = "TasksDone",
	target = 15,
	coins = 25,
	xp = 50,
}

return FinishTasks
