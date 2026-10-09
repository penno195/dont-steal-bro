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
	robuxPrice = 249, -- ten power-ups at about 25 R$ each; display only
	sortOrder = 31,
	imageAssetId = 96446701704970, -- assets/store/currency-large.png
	grants = {
		{ kind = "Currency", amount = 250 }, -- ten power-ups (Q1 pricing, 2026-10-02)
	},
}

return CurrencyLarge
