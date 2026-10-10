--!strict
-- Limited edition: the Vault Door Shield, 149 R$, on hub plinth 3
-- until 2026-12-01 00:00 UTC, then never sold again; owners keep it
-- (user decision, 2026-10-10, design-decisions.md Q1 "limited
-- cosmetics").
-- Its developer product's icon is assets/store/limited-vault-door-shield.png.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VaultDoorShield: Validate.StoreItemDef = {
	key = "limited-vault-door-shield",
	kind = "DeveloperProduct",
	assetId = 3717709071,
	enabled = true,
	displayName = "Vault Door Shield",
	description = "Limited edition: on sale until 1 December, then never again. A whole bank vault door, worn on your back. Cosmetic only.",
	robuxPrice = 149, -- display only; Roblox charges the product's dashboard price
	onSaleUntil = "2026-12-01 00:00",
	featuredSlot = 3, -- beside the Season Pass
	sortOrder = 61,
	imageAssetId = 92515170309027, -- assets/store/limited-vault-door-shield.png
	grants = { { kind = "Cosmetic", cosmeticId = "back-vault-door-shield" } },
	plinthModel = { meshAssetId = 80535033484530, textureAssetId = 100679235571954, scale = 0.022 },
}

return VaultDoorShield
