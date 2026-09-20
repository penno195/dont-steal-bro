--!strict
-- tasks-catalogue.md #1. Full fantasy/failure-retry/reskin text lives in
-- that doc; this is only the structured, game-code-facing subset.

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
