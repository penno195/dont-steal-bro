--!strict
-- Limited edition: the Diamond Heist Crown, 149 R$, on hub plinth 1
-- until 2026-12-01 00:00 UTC, then never sold again; owners keep it
-- (user decision, 2026-10-10, design-decisions.md Q1 "limited
-- cosmetics").
-- Its developer product's icon is assets/store/limited-diamond-heist-crown.png.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local DiamondHeistCrown: Validate.StoreItemDef = {
	key = "limited-diamond-heist-crown",
	kind = "DeveloperProduct",
	assetId = 3717708907,
	enabled = true,
	displayName = "Diamond Heist Crown",
	description = "Limited edition: on sale until 1 December, then never again. A gold crown packed with stolen diamonds. Cosmetic only.",
	robuxPrice = 149, -- display only; Roblox charges the product's dashboard price
	onSaleUntil = "2026-12-01 00:00",
	featuredSlot = 1, -- beside the Season Pass
	sortOrder = 60,
	imageAssetId = 131933119287902, -- assets/store/limited-diamond-heist-crown.png
	grants = { { kind = "Cosmetic", cosmeticId = "hat-diamond-heist-crown" } },
	plinthModel = { meshAssetId = 131259672821092, textureAssetId = 135718904385281, scale = 0.022 },
}

return DiamondHeistCrown
