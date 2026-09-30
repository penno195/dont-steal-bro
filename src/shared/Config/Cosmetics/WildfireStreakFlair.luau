--!strict
-- Your win-streak counter burns instead of glowing. The number is always
-- the real streak; this only changes how it's dressed.
--
-- Disabled until it has a Roblox asset, a store product and a renderer
-- (nothing draws the "StreakFlair" slot yet).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local WildfireStreakFlair: Validate.CosmeticDef = {
	id = "flair-wildfire",
	category = "StreakFlair",
	displayName = "Wildfire",
	description = "Your streak counter burns. Cosmetic only.",
	rarity = "Uncommon",
	sortOrder = 60,
	enabled = false, -- PLACEHOLDER: no Roblox asset id, product or renderer yet
	flairTextureAssetId = 0,
	flairColorHex = "#ff7a1a",
}

return WildfireStreakFlair
