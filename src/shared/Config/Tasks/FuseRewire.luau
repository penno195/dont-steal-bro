--!strict
-- tasks-catalogue.md #7. Full fantasy/failure-retry/reskin text lives in
-- that doc; this is only the structured, game-code-facing subset. The
-- P2-6 Drag reference task - see src/server/TaskHandlers/FuseRewire.luau
-- and src/client/TaskViews/FuseRewire.luau for the other two-thirds.
--
-- Reskin note (P2-6's own requirement) - full 11-theme table in
-- tasks-catalogue.md #7:
--   School -> "Boiler room fuse box"
--   Factory -> "Main distribution panel"
--   Space Station -> "Power distribution node"
-- The mapping is server-rolled per attempt regardless of theme - reskins
-- only ever change the art around the same four fuse/slot ids, never the
-- validation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local FuseRewire: Validate.TaskDef = {
	id = "fuse-rewire",
	displayName = "Fuse Rewire",
	verb = "Drag",
	expectedDurationSeconds = { min = 8, max = 10 },
	mobileFeasibility = 4,
}

return FuseRewire
