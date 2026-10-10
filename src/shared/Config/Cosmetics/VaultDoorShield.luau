--!strict
-- A bank vault door worn on the back: a limited edition, sold only by
-- Store/VaultDoorShield.luau (149 R$, until 2026-12-01 UTC), then never
-- again; owners keep it. Not a drop, prize or track item.
-- Meshy-made model (assets/seasonpass/make-models.js), imported at
-- centimetre scale, hence the tiny wearScale; fitted on an R15 rig in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VaultDoorShield: Validate.CosmeticDef = {
	id = "back-vault-door-shield",
	category = "BackItem",
	displayName = "Vault Door Shield",
	description = "A whole bank vault door, worn on your back. Limited edition. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 27,
	enabled = true,
	wearMeshAssetId = 80535033484530,
	wearTextureAssetId = 100679235571954,
	wearScale = 0.011,
	wearOffset = { 0, 0, 0.75 },
	wearRotation = { 0, 180, 0 },
	previewIconAssetId = 129578283518802,
}

return VaultDoorShield
