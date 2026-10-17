--!strict
-- A coin offer (rewards-roadmap.md step 6): one Push/Trip for earned coins.
-- Coins buy specific power-ups at fixed prices, never anything random
-- (design-decisions.md Q1). This is what makes Q8's "Robux buys time"
-- literal: the same stock a Robux product sells, bought with coins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local PushTripCoins: Validate.StoreItemDef = {
	key = "push-trip-coins",
	kind = "CoinOffer",
	assetId = 0, -- a CoinOffer has no Roblox asset
	enabled = true,
	displayName = "Push/Trip",
	description = "One Push/Trip for your loadout, bought with coins you've earned.",
	robuxPrice = 0,
	coinPrice = 25, -- Common: 25 / 50 / 100 by rarity (design-decisions.md Q1, 2026-10-17 repricing)
	sortOrder = 105,
	imageAssetId = 134997602836955, -- assets/store/push-trip-coins.png
	grants = {
		{ kind = "PowerUpStock", powerUpId = "push-trip", amount = 1 },
	},
}

return PushTripCoins
