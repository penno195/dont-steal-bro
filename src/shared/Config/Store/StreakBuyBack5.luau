--!strict
-- Buying back a lost streak of 5. See StreakBuyBack1.luau for how
-- the tiers work (design-decisions.md Q7, "buying back a streak").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StreakBuyBack5: Validate.StoreItemDef = {
	key = "streak-buy-back-5",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Save your streak",
	description = "Lost your streak of 5? Buy it back and carry on from 5.",
	robuxPrice = 209, -- display only
	sortOrder = 305,
	imageAssetId = 84597107283934, -- assets/store/streak-buy-back-5.png
	grants = {
		{ kind = "StreakBuyBack", minStreak = 5, maxStreak = 5 },
	},
}

return StreakBuyBack5
