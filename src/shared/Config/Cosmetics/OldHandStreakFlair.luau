--!strict
-- A level-only cosmetic: reaching account level 25 gives it, and nothing
-- else does (design-decisions.md Q1, "a payoff for every round";
-- CosmeticDef.unlockLevel). Art from Meshy text-to-image, cut by
-- assets/cosmetics/make-level-art.py. The level is Claude's
-- placeholder, for the owner to confirm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local OldHandStreakFlair: Validate.CosmeticDef = {
	id = "flair-old-hand",
	category = "StreakFlair",
	displayName = "Old Hand",
	description = "Reach level 25. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 61,
	enabled = true,
	unlockLevel = 25,
	flairTextureAssetId = 140416295807965,
	flairColorHex = "#c084fc",
	previewIconAssetId = 81191134988345,
}

return OldHandStreakFlair
