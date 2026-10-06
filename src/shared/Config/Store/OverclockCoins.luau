--!strict
-- A coin offer (rewards-roadmap.md step 6): one Overclock for earned coins.
-- Coins buy specific power-ups at fixed prices, never anything random
-- (design-decisions.md Q1). This is what makes Q8's "Robux buys time"
-- literal: the same stock a Robux product sells, bought with coins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local OverclockCoins: Validate.StoreItemDef = {
	key = "overclock-coins",
	kind = "CoinOffer",
	assetId = 0, -- a CoinOffer has no Roblox asset
	enabled = true,
	displayName = "Overclock",
	description = "One Overclock for your loadout, bought with coins you've earned.",
	robuxPrice = 0,
	coinPrice = 25, -- one rung-0 win of any outcome (design-decisions.md Q1, 2026-10-02 pricing)
	sortOrder = 103,
	imageAssetId = 116191616982030, -- assets/store/overclock-coins.png
	grants = {
		{ kind = "PowerUpStock", powerUpId = "overclock", amount = 1 },
	},
}

return OverclockCoins
