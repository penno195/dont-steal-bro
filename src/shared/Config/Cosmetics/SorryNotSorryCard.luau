--!strict
-- The card a victim sees for a moment when your sabotage lands on them:
-- the picture on their "X used Y on you" toast (RaceHUDController).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SorryNotSorryCard: Validate.CosmeticDef = {
	id = "card-sorry-not-sorry",
	category = "CallingCard",
	displayName = "Sorry Not Sorry",
	description = "Leave your mark on everyone you sabotage. Cosmetic only.",
	rarity = "Common",
	sortOrder = 80,
	enabled = true,
	winDrop = true, -- design-decisions.md Q1 applied case (2026-10-02): no pass grants it, so wins can drop it
	cardImageAssetId = 132867595357083,
}

return SorryNotSorryCard
