--!strict
-- Buying back a lost streak of 2. See StreakBuyBack1.luau for how
-- the tiers work (design-decisions.md Q7, "buying back a streak").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StreakBuyBack2: Validate.StoreItemDef = {
	key = "streak-buy-back-2",
	kind = "DeveloperProduct",
	assetId = 3717322285,
	enabled = true,
	displayName = "Save your streak",
	description = "Lost your streak of 2? Buy it back and carry on from 2.",
	robuxPrice = 119, -- display only
	sortOrder = 302,
	imageAssetId = 116859985062075, -- assets/store/streak-buy-back-2.png
	grants = {
		{ kind = "StreakBuyBack", minStreak = 2, maxStreak = 2 },
	},
}

return StreakBuyBack2
