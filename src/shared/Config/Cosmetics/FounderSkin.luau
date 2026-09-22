--!strict
-- A full outfit swap: the "Skin" half of FounderPass.luau's grant.
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
	enabled = false, -- PLACEHOLDER: no Roblox asset id yet, see below
	shirtAssetId = 0,
	pantsAssetId = 0,
}

return FounderSkin
