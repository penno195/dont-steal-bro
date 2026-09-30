--!strict
-- A gilded frame around your name and Title. The Title inside it is still
-- earned-only; this sells the frame, never the words.
--
-- Disabled until it has a Roblox asset, a store product and a renderer
-- (nothing draws the "Nameplate" slot yet).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local GildedNameplate: Validate.CosmeticDef = {
	id = "nameplate-gilded",
	category = "Nameplate",
	displayName = "Gilded Frame",
	description = "A gold frame around your name and Title. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 70,
	enabled = false, -- PLACEHOLDER: no Roblox asset id, product or renderer yet
	nameplateFrameAssetId = 0,
	nameplateColorHex = "#d4af37",
}

return GildedNameplate
