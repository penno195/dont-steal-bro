--!strict
-- Buying back a lost streak of 6. See StreakBuyBack1.luau for how
-- the tiers work (design-decisions.md Q7, "buying back a streak").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StreakBuyBack6: Validate.StoreItemDef = {
	key = "streak-buy-back-6",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Save your streak",
	description = "Keep the streak you just lost.",
	robuxPrice = 239, -- display only
	sortOrder = 306,
	imageAssetId = 0,
	grants = {
		{ kind = "StreakBuyBack", minStreak = 6, maxStreak = 6 },
	},
}

return StreakBuyBack6
