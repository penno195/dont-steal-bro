--!strict
-- A level-only cosmetic: reaching account level 10 gives it, and nothing
-- else does (design-decisions.md Q1, "a payoff for every round";
-- CosmeticDef.unlockLevel). Art from Meshy text-to-image, cut by
-- assets/cosmetics/make-level-art.py. The level is Claude's
-- placeholder, for the owner to confirm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VeteranNameplate: Validate.CosmeticDef = {
	id = "nameplate-veteran",
	category = "Nameplate",
	displayName = "Veteran Frame",
	description = "Reach level 10. Cosmetic only.",
	rarity = "Uncommon",
	sortOrder = 71,
	enabled = true,
	unlockLevel = 10,
	nameplateFrameAssetId = 126937987401278,
	nameplateColorHex = "#9aa7b8",
	previewIconAssetId = 78083737501585,
}

return VeteranNameplate
