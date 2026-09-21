--!strict
-- tasks-catalogue.md #9. Full fantasy/failure-retry/reskin text lives in
-- that doc; this is only the structured, game-code-facing subset. The
-- P2-5 reference task - see src/server/TaskHandlers/CodePlayback.luau
-- and src/client/TaskViews/CodePlayback.luau for the other two-thirds of
-- the split this one definition is shared between.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local CodePlayback: Validate.TaskDef = {
	id = "code-playback",
	displayName = "Code Playback",
	verb = "Sequence",
	expectedDurationSeconds = { min = 9, max = 13 },
	mobileFeasibility = 4,
}

return CodePlayback
