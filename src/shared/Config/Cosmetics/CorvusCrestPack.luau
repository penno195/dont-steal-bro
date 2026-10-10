--!strict
-- A black-and-gold hard-shell pack with the Corvus crest: the community
-- reward (GameConfig.community), free to members of the Studio Corvus
-- group and handed out nowhere else, so Validate refuses selling it,
-- dropping it, paying it as a prize or putting it on a track.
-- Meshy-made model (assets/seasonpass/make-models.js), imported at
-- centimetre scale, hence the tiny wearScale; fitted on an R15 rig in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local CorvusCrestPack: Validate.CosmeticDef = {
	id = "back-corvus-crest-pack",
	category = "BackItem",
	displayName = "Corvus Crest Pack",
	description = "Gold-trimmed and crested. Only for members of the Studio Corvus community. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 25,
	enabled = true,
	wearMeshAssetId = 70420142763325,
	wearTextureAssetId = 122006621028960,
	wearScale = 0.0115,
	wearOffset = { 0, 0, 0.75 },
	wearRotation = { 0, 180, 0 }, -- the model's front faces away from the back
	previewIconAssetId = 135583353017773,
}

return CorvusCrestPack
