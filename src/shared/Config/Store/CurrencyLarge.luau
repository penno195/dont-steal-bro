--!strict
-- A consumable developer product: the larger coin pack. Same currency,
-- same acquisition rules as CurrencySmall.luau - see its header for why
-- currency is never a game pass.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local CurrencyLarge: Validate.StoreItemDef = {
	key = "currency-large",
	kind = "DeveloperProduct",
	assetId = 3716319109,
	enabled = true,
	displayName = "Large Coin Chest",
	description = "250 coins. The same coins you earn from playing - these just arrive sooner.",
	robuxPrice = 99, -- about 34% off the Small Coin Pouch's rate, rounded to 99 for looks (2026-10-17); display only
	wasPrice = 150, -- 250 coins at the Small Coin Pouch rate: the ~30% saving, struck through
	sortOrder = 31,
	imageAssetId = 80999045340262, -- assets/store/currency-large.png (art pass 2026-10-10)
	grants = {
		{ kind = "Currency", amount = 250 }, -- ten Commons (Q1 pricing, 2026-10-17)
	},
}

return CurrencyLarge
