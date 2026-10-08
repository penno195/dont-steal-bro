--!strict
-- Buying back a lost streak of 7. See StreakBuyBack1.luau for how
-- the tiers work (design-decisions.md Q7, "buying back a streak").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StreakBuyBack7: Validate.StoreItemDef = {
	key = "streak-buy-back-7",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Save your streak",
	description = "Keep the streak you just lost.",
	robuxPrice = 269, -- display only
	sortOrder = 307,
	imageAssetId = 0,
	grants = {
		{ kind = "StreakBuyBack", minStreak = 7, maxStreak = 7 },
	},
}

return StreakBuyBack7
