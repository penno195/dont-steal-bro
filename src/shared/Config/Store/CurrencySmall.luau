--!strict
-- A consumable developer product: a pile of the free-to-earn currency.
--
-- WHY CURRENCY IS A DEVELOPER PRODUCT AND NOT A PASS: a pass is
-- permanent and its grants are re-applied on every join, so a pass that
-- granted currency would be an infinite tap. Validate.checkStoreItem
-- refuses that shape outright rather than trusting whoever writes the
-- next config file to know it.
--
-- design-decisions.md Q8's rule is satisfied structurally here: the
-- currency this buys is the SAME currency earned through normal play
-- (ProfileLogic's `currency` field), and it buys the same power-ups at
-- the same prices. Robux buys time, never exclusive power.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local CurrencySmall: Validate.StoreItemDef = {
	key = "currency-small",
	kind = "DeveloperProduct",
	assetId = 3716318892,
	enabled = true,
	displayName = "Small Coin Pouch",
	description = "75 coins. The same coins you earn from playing - these just arrive sooner.",
	robuxPrice = 79, -- three power-ups at about 26 R$ each; display only
	sortOrder = 30,
	imageAssetId = 135056611855919, -- assets/store/currency-small.png
	grants = {
		{ kind = "Currency", amount = 75 }, -- three power-ups (Q1 pricing, 2026-10-02)
	},
}

return CurrencySmall
