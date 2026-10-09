--!strict
-- tasks-catalogue.md #13. Full fantasy/failure-retry/reskin text lives in
-- that doc; this is only the structured, game-code-facing subset. The
-- gentlest Timing task - see src/server/TaskHandlers/AirlockCycle.luau,
-- src/client/TaskViews/AirlockCycle.luau and src/shared/TimingLogic.luau
-- (the sweep maths it shares with Reactor Sync).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local AirlockCycle: Validate.TaskDef = {
	id = "airlock-cycle",
	displayName = "Airlock Cycle",
	verb = "Timing",
	expectedDurationSeconds = { min = 5, max = 7 },
	mobileFeasibility = 5,
}

return AirlockCycle
