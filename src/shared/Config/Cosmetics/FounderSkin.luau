--!strict
-- A full outfit swap, on Season 1's premium track (Seasons/Season1.luau).
-- Cosmetic only - CosmeticService applies it as a Shirt/Pants pair, which
-- is the cheapest possible reskin (two Instances, no extra meshes) and
-- fits the mobile instance-count budget trivially.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local FounderSkin: Validate.CosmeticDef = {
	id = "skin-founder",
	category = "Skin",
	displayName = "Founder's Kit",
	description = "The outfit worn by the founders. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 10,
	enabled = true,
	shirtAssetId = 99470555666548,
	pantsAssetId = 129608190082628,
}

return FounderSkin
