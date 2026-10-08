--!strict
-- Buying back a lost streak of 1 (design-decisions.md Q7, "buying
-- back a streak"). One developer product per price tier, because a
-- product's price is fixed on Roblox. Never in the Hub grid: offered
-- only to a player who just lost a streak, on their end screen and in
-- the Hub until their next race starts. StoreService picks the tier
-- from the saved offer, and the grant restores the streak only if the
-- offer is still there and in this tier (StoreLogic.applyGrants).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StreakBuyBack1: Validate.StoreItemDef = {
	key = "streak-buy-back-1",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Save your streak",
	description = "Keep the streak you just lost.",
	robuxPrice = 99, -- display only
	sortOrder = 301,
	imageAssetId = 0,
	grants = {
		{ kind = "StreakBuyBack", minStreak = 1, maxStreak = 1 },
	},
}

return StreakBuyBack1
