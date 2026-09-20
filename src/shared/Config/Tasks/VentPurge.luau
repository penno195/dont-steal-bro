--!strict
-- tasks-catalogue.md #2. Full fantasy/failure-retry/reskin text lives in
-- that doc; this is only the structured, game-code-facing subset.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VentPurge: Validate.TaskDef = {
	id = "vent-purge",
	displayName = "Vent Purge",
	verb = "Tap",
	expectedDurationSeconds = { min = 5, max = 7 },
	mobileFeasibility = 5,
}

return VentPurge
