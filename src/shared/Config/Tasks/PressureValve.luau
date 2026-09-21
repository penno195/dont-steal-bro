--!strict
-- tasks-catalogue.md #1. Full fantasy/failure-retry/reskin text lives in
-- that doc; this is only the structured, game-code-facing subset. The
-- P2-6 Tap reference task - see src/server/TaskHandlers/PressureValve.
-- luau and src/client/TaskViews/PressureValve.luau for the other
-- two-thirds.
--
-- Reskin note (P2-6's own requirement) - full 11-theme table in
-- tasks-catalogue.md #1:
--   School -> "Jammed fire alarm hammer"
--   Factory -> "Steam relief valve"
--   Space Station -> "O2 scrubber vent"
-- The rolled tap target (18-24) and minimum tap interval are identical
-- regardless of theme - reskins only ever change the art around the same
-- gauge, never the validation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local PressureValve: Validate.TaskDef = {
	id = "pressure-valve",
	displayName = "Pressure Valve",
	verb = "Tap",
	expectedDurationSeconds = { min = 6, max = 8 },
	mobileFeasibility = 5,
}

return PressureValve
