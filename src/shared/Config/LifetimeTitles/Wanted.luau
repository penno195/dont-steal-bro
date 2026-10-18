--!strict
-- Payoff-loop step 9's lifetime titles: StealWins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Wanted: Validate.LifetimeTitleDef = {
	id = "wanted",
	displayName = "Wanted",
	colorHex = "#e65252",
	stat = "StealWins",
	threshold = 50,
}

return Wanted
