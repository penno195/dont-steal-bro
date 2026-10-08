--!strict
-- Buying back a lost streak of 4. See StreakBuyBack1.luau for how
-- the tiers work (design-decisions.md Q7, "buying back a streak").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StreakBuyBack4: Validate.StoreItemDef = {
	key = "streak-buy-back-4",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Save your streak",
	description = "Lost your streak of 4? Buy it back and carry on from 4.",
	robuxPrice = 179, -- display only
	sortOrder = 304,
	imageAssetId = 91785709712681, -- assets/store/streak-buy-back-4.png
	grants = {
		{ kind = "StreakBuyBack", minStreak = 4, maxStreak = 4 },
	},
}

return StreakBuyBack4
