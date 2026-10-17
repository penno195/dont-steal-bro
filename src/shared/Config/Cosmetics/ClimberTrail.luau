--!strict
-- A level-only cosmetic: reaching account level 5 gives it, and nothing
-- else does (design-decisions.md Q1, "a payoff for every round";
-- CosmeticDef.unlockLevel). PLACEHOLDER: disabled until its asset is
-- made, so nothing grants it yet. The level and look are Claude's
-- placeholders, for the owner to confirm.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local ClimberTrail: Validate.CosmeticDef = {
	id = "trail-climber",
	category = "Trail",
	displayName = "Climber's Trail",
	description = "Reach level 5. Cosmetic only.",
	rarity = "Common",
	sortOrder = 12,
	enabled = false,
	unlockLevel = 5,
	trailTextureAssetId = 0,
	trailColorHex = "#5fd1ff",
	trailLifetime = 0.5,
}

return ClimberTrail
