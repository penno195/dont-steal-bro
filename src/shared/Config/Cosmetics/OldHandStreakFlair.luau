--!strict
-- A level-only cosmetic: reaching account level 25 gives it, and nothing
-- else does (design-decisions.md Q1, "a payoff for every round";
-- CosmeticDef.unlockLevel). PLACEHOLDER: disabled until its asset is
-- made, so nothing grants it yet. The level and look are Claude's
-- placeholders, for the owner to confirm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local OldHandStreakFlair: Validate.CosmeticDef = {
	id = "flair-old-hand",
	category = "StreakFlair",
	displayName = "Old Hand",
	description = "Reach level 25. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 61,
	enabled = false,
	unlockLevel = 25,
	flairTextureAssetId = 0,
	flairColorHex = "#c084fc",
}

return OldHandStreakFlair
