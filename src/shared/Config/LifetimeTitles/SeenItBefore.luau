--!strict
-- Payoff-loop step 9's lifetime titles: Wins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SeenItBefore: Validate.LifetimeTitleDef = {
	id = "seen-it-before",
	displayName = "Seen It Before",
	colorHex = "#c9b37a",
	stat = "Wins",
	threshold = 10,
}

return SeenItBefore
