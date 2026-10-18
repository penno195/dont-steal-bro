--!strict
-- Payoff-loop step 9's lifetime titles: StealWins ladder. See init.luau.
-- PLACEHOLDER name and threshold.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StickyFingers: Validate.LifetimeTitleDef = {
	id = "sticky-fingers",
	displayName = "Sticky Fingers",
	colorHex = "#d99a9a",
	stat = "StealWins",
	threshold = 1,
}

return StickyFingers
