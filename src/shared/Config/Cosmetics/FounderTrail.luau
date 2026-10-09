--!strict
-- A movement trail, on Season 1's premium track (Seasons/Season1.luau).
-- Cosmetic only - purely visual, never touches movement stats.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local FounderTrail: Validate.CosmeticDef = {
	id = "trail-founder",
	category = "Trail",
	displayName = "Founder's Trail",
	description = "A gold trail marking one of the founders. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 11,
	enabled = true,
	trailTextureAssetId = 128027629483773,
	trailColorHex = "#d4af37",
	trailLifetime = 0.6,
	previewIconAssetId = 134562449888774,
}

return FounderTrail
