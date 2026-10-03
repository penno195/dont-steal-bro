--!strict
-- A gilded frame around your name and Title. The Title inside it is still
-- earned-only; this sells the frame, never the words. Drawn behind the
-- nametag (NametagController), and hidden mid-round with it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local GildedNameplate: Validate.CosmeticDef = {
	id = "nameplate-gilded",
	category = "Nameplate",
	displayName = "Gilded Frame",
	description = "A gold frame around your name and Title. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 70,
	enabled = true,
	winDrop = true, -- design-decisions.md Q1 applied case (2026-10-02): no pass grants it, so wins can drop it
	nameplateFrameAssetId = 120283394439125,
	nameplateColorHex = "#d4af37",
}

return GildedNameplate
