--!strict
-- Your win-streak counter burns instead of glowing. The number is always
-- the real streak; this only changes how it's dressed.
--
-- Dresses the streak counter over your head in the Hub
-- (StreakTagController) - Hub only, never on a match server (Q7).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local WildfireStreakFlair: Validate.CosmeticDef = {
	id = "flair-wildfire",
	category = "StreakFlair",
	displayName = "Wildfire",
	description = "Your streak counter burns. Cosmetic only.",
	rarity = "Uncommon",
	sortOrder = 60,
	enabled = true,
	winDrop = true, -- design-decisions.md Q1 applied case (2026-10-02): no pass grants it, so wins can drop it
	flairTextureAssetId = 96171864864984,
	flairColorHex = "#ff7a1a",
}

return WildfireStreakFlair
