--!strict
-- Buying back a lost streak of 8 or more. See StreakBuyBack1.luau for how
-- the tiers work (design-decisions.md Q7, "buying back a streak").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StreakBuyBack8Plus: Validate.StoreItemDef = {
	key = "streak-buy-back-8-plus",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Save your streak",
	description = "Keep the streak you just lost.",
	robuxPrice = 299, -- display only
	sortOrder = 308,
	imageAssetId = 0,
	grants = {
		{ kind = "StreakBuyBack", minStreak = 8, maxStreak = nil },
	},
}

return StreakBuyBack8Plus
