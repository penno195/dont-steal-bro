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
	description = "Keep the streak you just lost.",
	robuxPrice = 179, -- display only
	sortOrder = 304,
	imageAssetId = 0,
	grants = {
		{ kind = "StreakBuyBack", minStreak = 4, maxStreak = 4 },
	},
}

return StreakBuyBack4
