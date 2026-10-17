--!strict
-- A level-only cosmetic: reaching account level 10 gives it, and nothing
-- else does (design-decisions.md Q1, "a payoff for every round";
-- CosmeticDef.unlockLevel). PLACEHOLDER: disabled until its asset is
-- made, so nothing grants it yet. The level and look are Claude's
-- placeholders, for the owner to confirm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VeteranNameplate: Validate.CosmeticDef = {
	id = "nameplate-veteran",
	category = "Nameplate",
	displayName = "Veteran Frame",
	description = "Reach level 10. Cosmetic only.",
	rarity = "Uncommon",
	sortOrder = 71,
	enabled = false,
	unlockLevel = 10,
	nameplateFrameAssetId = 0,
	nameplateColorHex = "#9aa7b8",
}

return VeteranNameplate
