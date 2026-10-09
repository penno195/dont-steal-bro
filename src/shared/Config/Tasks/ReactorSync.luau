--!strict
-- tasks-catalogue.md #11. Full fantasy/failure-retry/reskin text lives in
-- that doc; this is only the structured, game-code-facing subset. The
-- Timing reference task - see src/server/TaskHandlers/ReactorSync.luau,
-- src/client/TaskViews/ReactorSync.luau and src/shared/TimingLogic.luau.
--
-- Reskin note - full table in tasks-catalogue.md #11:
--   School -> "Science-fair generator sync"
--   Factory -> "Turbine phase sync"
--   Laboratory -> "Particle collider sync"
-- The sweep, band and lives are identical regardless of theme.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local ReactorSync: Validate.TaskDef = {
	id = "reactor-sync",
	displayName = "Reactor Sync",
	verb = "Timing",
	expectedDurationSeconds = { min = 6, max = 9 },
	mobileFeasibility = 5,
}

return ReactorSync
