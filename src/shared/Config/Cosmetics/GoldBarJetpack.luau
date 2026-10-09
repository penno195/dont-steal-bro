--!strict
-- A jetpack made of gold bars: the paid row's top item (30 wins).
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Meshy-made model (assets/seasonpass/make-models.js), imported at
-- centimetre scale, hence the tiny wearScale; fitted on an R15 rig in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local GoldBarJetpack: Validate.CosmeticDef = {
	id = "back-gold-bar-jetpack",
	category = "BackItem",
	displayName = "Gold Bar Jetpack",
	description = "A jetpack built from stolen gold bars. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 24,
	enabled = true,
	wearMeshAssetId = 96237860330723,
	wearTextureAssetId = 81943353741587,
	wearScale = 0.0115,
	wearOffset = { 0, 0, 0.75 },
	wearRotation = { 0, 180, 0 }, -- the model's front faces away from the back
	previewIconAssetId = 74118338451108,
}

return GoldBarJetpack
