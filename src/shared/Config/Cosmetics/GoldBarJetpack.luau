--!strict
-- A jetpack made of gold bars: the paid row's top item (30 wins).
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Disabled until its Meshy-made mesh and texture are uploaded and their
-- ids pasted below; wearScale/wearOffset are tuned in Studio after that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local GoldBarJetpack: Validate.CosmeticDef = {
	id = "back-gold-bar-jetpack",
	category = "BackItem",
	displayName = "Gold Bar Jetpack",
	description = "A jetpack built from stolen gold bars. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 24,
	enabled = false,
	wearMeshAssetId = 0,
	wearTextureAssetId = 0,
	wearScale = 1,
}

return GoldBarJetpack
