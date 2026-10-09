--!strict
-- A burglar's beanie: paid row, 4 wins.
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Meshy-made model (assets/seasonpass/make-models.js), imported at
-- centimetre scale, hence the tiny wearScale; fitted on an R15 rig in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local BurglarBeanieHat: Validate.CosmeticDef = {
	id = "hat-burglar-beanie",
	category = "Hat",
	displayName = "Burglar Beanie",
	description = "A black knitted beanie for quiet work. Cosmetic only.",
	rarity = "Common",
	sortOrder = 21,
	enabled = true,
	wearMeshAssetId = 121418288372766,
	wearTextureAssetId = 81092269451597,
	wearScale = 0.0072,
	wearOffset = { 0, 0.15, 0 },
	previewIconAssetId = 131521031001599,
}

return BurglarBeanieHat
