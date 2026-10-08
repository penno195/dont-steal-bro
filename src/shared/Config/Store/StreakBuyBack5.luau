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
	description = "Keep the streak you just lost.",
	robuxPrice = 209, -- display only
	sortOrder = 305,
	imageAssetId = 0,
	grants = {
		{ kind = "StreakBuyBack", minStreak = 5, maxStreak = 5 },
	},
}

return StreakBuyBack5
