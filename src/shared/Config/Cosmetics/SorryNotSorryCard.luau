--!strict
-- The card a victim sees for a moment when your sabotage lands on them:
-- the picture on their "X used Y on you" toast (RaceHUDController).
--
-- Disabled until it has a Roblox asset and a store product.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SorryNotSorryCard: Validate.CosmeticDef = {
	id = "card-sorry-not-sorry",
	category = "CallingCard",
	displayName = "Sorry Not Sorry",
	description = "Leave your mark on everyone you sabotage. Cosmetic only.",
	rarity = "Common",
	sortOrder = 80,
	enabled = false, -- PLACEHOLDER: no Roblox asset id or product yet
	cardImageAssetId = 0,
}

return SorryNotSorryCard
