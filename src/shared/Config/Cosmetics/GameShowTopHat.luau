--!strict
-- A sequinned host's top hat: paid row, 16 wins.
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Disabled until its Meshy-made mesh and texture are uploaded and their
-- ids pasted below; wearScale/wearOffset are tuned in Studio after that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local GameShowTopHat: Validate.CosmeticDef = {
	id = "hat-game-show-top-hat",
	category = "Hat",
	displayName = "Game Show Top Hat",
	description = "A sequinned host's top hat. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 23,
	enabled = false,
	wearMeshAssetId = 0,
	wearTextureAssetId = 0,
	wearScale = 1,
}

return GameShowTopHat
