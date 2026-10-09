--!strict
-- A swag bag on your back: the paid row's first item (0 wins).
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Meshy-made model (assets/seasonpass/make-models.js), imported at
-- centimetre scale, hence the tiny wearScale; fitted on an R15 rig in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local LootSackBack: Validate.CosmeticDef = {
	id = "back-loot-sack",
	category = "BackItem",
	displayName = "Loot Sack",
	description = "A bulging swag bag slung over your shoulder. Cosmetic only.",
	rarity = "Common",
	sortOrder = 20,
	enabled = true,
	wearMeshAssetId = 112676661018842,
	wearTextureAssetId = 131147733929237,
	wearScale = 0.011,
	wearOffset = { 0, 0, 0.75 },
	wearRotation = { 0, 180, 0 }, -- the model's front faces away from the back
	previewIconAssetId = 115821742918760,
}

return LootSackBack
