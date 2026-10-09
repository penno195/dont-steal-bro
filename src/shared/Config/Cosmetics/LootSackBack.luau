--!strict
-- A swag bag on your back: the paid row's first item (0 wins).
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Disabled until its Meshy-made mesh and texture are uploaded and their
-- ids pasted below; wearScale/wearOffset are tuned in Studio after that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local LootSackBack: Validate.CosmeticDef = {
	id = "back-loot-sack",
	category = "BackItem",
	displayName = "Loot Sack",
	description = "A bulging swag bag slung over your shoulder. Cosmetic only.",
	rarity = "Common",
	sortOrder = 20,
	enabled = false,
	wearMeshAssetId = 0,
	wearTextureAssetId = 0,
	wearScale = 1,
}

return LootSackBack
