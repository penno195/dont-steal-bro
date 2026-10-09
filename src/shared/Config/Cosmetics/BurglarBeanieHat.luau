--!strict
-- A burglar's beanie: paid row, 4 wins.
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Disabled until its Meshy-made mesh and texture are uploaded and their
-- ids pasted below; wearScale/wearOffset are tuned in Studio after that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local BurglarBeanieHat: Validate.CosmeticDef = {
	id = "hat-burglar-beanie",
	category = "Hat",
	displayName = "Burglar Beanie",
	description = "A black knitted beanie for quiet work. Cosmetic only.",
	rarity = "Common",
	sortOrder = 21,
	enabled = false,
	wearMeshAssetId = 0,
	wearTextureAssetId = 0,
	wearScale = 1,
}

return BurglarBeanieHat
