--!strict
-- A level-only cosmetic: reaching account level 5 gives it, and nothing
-- else does (design-decisions.md Q1, "a payoff for every round";
-- CosmeticDef.unlockLevel). Art from Meshy text-to-image, cut by
-- assets/cosmetics/make-level-art.py. The level is the owner's
-- (2026-10-18).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local ClimberTrail: Validate.CosmeticDef = {
	id = "trail-climber",
	category = "Trail",
	displayName = "Climber's Trail",
	description = "Reach level 5. Cosmetic only.",
	rarity = "Common",
	sortOrder = 12,
	enabled = true,
	unlockLevel = 5,
	trailTextureAssetId = 104931890644166,
	trailColorHex = "#5fd1ff",
	trailLifetime = 0.5,
	previewIconAssetId = 94489609603529,
}

return ClimberTrail
