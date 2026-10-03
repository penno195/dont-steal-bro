--!strict
-- tasks-catalogue.md #3. Full fantasy/failure-retry/reskin text lives in
-- that doc; this is only the structured, game-code-facing subset. The
-- Hold reference task - see src/server/TaskHandlers/AlarmKillswitch.luau
-- and src/client/TaskViews/AlarmKillswitch.luau for the other two-thirds.
--
-- Reskin note - full table in tasks-catalogue.md #3:
--   School -> "Stuck fire-alarm pull"
--   Factory -> "Emergency stop breaker"
--   Laboratory -> "Containment klaxon breaker"
-- The rolled hold length is identical regardless of theme.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local AlarmKillswitch: Validate.TaskDef = {
	id = "alarm-killswitch",
	displayName = "Alarm Killswitch",
	verb = "Hold",
	expectedDurationSeconds = { min = 4, max = 6 },
	mobileFeasibility = 5,
}

return AlarmKillswitch
