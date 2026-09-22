--!strict
-- A consumable developer product: the larger coin pack. Same currency,
-- same acquisition rules as CurrencySmall.luau - see its header for why
-- currency is never a game pass.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local CurrencyLarge: Validate.StoreItemDef = {
	key = "currency-large",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Large Coin Chest",
	description = "3,000 coins. The same coins you earn from playing - these just arrive sooner.",
	robuxPrice = 249, -- PLACEHOLDER: display only
	sortOrder = 31,
	grants = {
		{ kind = "Currency", amount = 3000 }, -- PLACEHOLDER: no locked economy numbers in docs/ yet
	},
}

return CurrencyLarge
