--!strict
-- tasks-catalogue.md #8. Full fantasy/failure-retry/reskin text lives in
-- that doc; this is only the structured, game-code-facing subset. See
-- src/server/TaskHandlers/BreakerSequence.luau and src/client/TaskViews/
-- BreakerSequence.luau for the other two-thirds.
--
-- Reskin note - full table in tasks-catalogue.md #8:
--   School -> "Gym scoreboard breaker bank"
--   Factory -> "Assembly-line switch bank"
--   Laboratory -> "Equipment power sequencer"
-- The rolled sequence and replay cap are identical regardless of theme.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local BreakerSequence: Validate.TaskDef = {
	id = "breaker-sequence",
	displayName = "Breaker Sequence",
	verb = "Sequence",
	expectedDurationSeconds = { min = 7, max = 10 },
	mobileFeasibility = 5,
}

return BreakerSequence
