--!strict
-- Payoff-loop step 9's lifetime titles: StealWins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local BroStole: Validate.LifetimeTitleDef = {
	id = "bro-stole",
	displayName = "Bro Stole",
	colorHex = "#f21212",
	stat = "StealWins",
	threshold = 400,
}

return BroStole
