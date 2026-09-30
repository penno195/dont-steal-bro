--!strict
-- Your win-streak counter burns instead of glowing. The number is always
-- the real streak; this only changes how it's dressed.
--
-- Dresses the streak counter over your head in the Hub
-- (StreakTagController) - Hub only, never on a match server (Q7).
--
-- Disabled until it has a Roblox asset and a store product.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local WildfireStreakFlair: Validate.CosmeticDef = {
	id = "flair-wildfire",
	category = "StreakFlair",
	displayName = "Wildfire",
	description = "Your streak counter burns. Cosmetic only.",
	rarity = "Uncommon",
	sortOrder = 60,
	enabled = false, -- PLACEHOLDER: no Roblox asset id or product yet
	flairTextureAssetId = 0,
	flairColorHex = "#ff7a1a",
}

return WildfireStreakFlair
