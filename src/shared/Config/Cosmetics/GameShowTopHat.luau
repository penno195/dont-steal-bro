--!strict
-- A sequinned host's top hat: paid row, 16 wins.
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Meshy-made model (assets/seasonpass/make-models.js), imported at
-- centimetre scale, hence the tiny wearScale; fitted on an R15 rig in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local GameShowTopHat: Validate.CosmeticDef = {
	id = "hat-game-show-top-hat",
	category = "Hat",
	displayName = "Game Show Top Hat",
	description = "A sequinned host's top hat. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 23,
	enabled = true,
	wearMeshAssetId = 87286641233103,
	wearTextureAssetId = 103663975096552,
	wearScale = 0.0085,
	wearOffset = { 0, 0.5, 0 },
	previewIconAssetId = 98933975606188,
}

return GameShowTopHat
