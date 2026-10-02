--!strict
-- A coin offer (rewards-roadmap.md step 6): one Slow Field for earned coins.
-- Coins buy specific power-ups at fixed prices, never anything random
-- (design-decisions.md Q1). This is what makes Q8's "Robux buys time"
-- literal: the same stock a Robux product sells, bought with coins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SlowFieldCoins: Validate.StoreItemDef = {
	key = "slow-field-coins",
	kind = "CoinOffer",
	assetId = 0, -- a CoinOffer has no Roblox asset
	enabled = true,
	displayName = "Slow Field",
	description = "One Slow Field for your loadout, bought with coins you've earned.",
	robuxPrice = 0,
	coinPrice = 150, -- PLACEHOLDER: about two to six wins (rewards-roadmap.md step 7)
	sortOrder = 107,
	grants = {
		{ kind = "PowerUpStock", powerUpId = "slow-field", amount = 1 },
	},
}

return SlowFieldCoins
