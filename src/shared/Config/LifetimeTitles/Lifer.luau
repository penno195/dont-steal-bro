--!strict
-- Payoff-loop step 9's lifetime titles: Wins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Lifer: Validate.LifetimeTitleDef = {
	id = "lifer",
	displayName = "Lifer",
	colorHex = "#deaa2e",
	stat = "Wins",
	threshold = 100,
}

return Lifer
