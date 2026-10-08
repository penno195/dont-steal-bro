--!strict
-- Buying back a lost streak of 3. See StreakBuyBack1.luau for how
-- the tiers work (design-decisions.md Q7, "buying back a streak").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StreakBuyBack3: Validate.StoreItemDef = {
	key = "streak-buy-back-3",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Save your streak",
	description = "Keep the streak you just lost.",
	robuxPrice = 149, -- display only
	sortOrder = 303,
	imageAssetId = 0,
	grants = {
		{ kind = "StreakBuyBack", minStreak = 3, maxStreak = 3 },
	},
}

return StreakBuyBack3
