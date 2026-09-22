--!strict
-- A permanent cosmetic game pass: a character skin plus a matching
-- trail. Nothing here touches the race - that is the whole point of a
-- pass in this game (see docs/store-receipts.md §"What a pass may
-- grant"), and Validate.checkStoreItem refuses a pass that grants
-- currency or power-up stock rather than leaving it to review.
--
-- `cosmeticId`s are cross-checked against P4-6's Cosmetics registry
-- (src/shared/Config/Cosmetics/FounderSkin.luau,
-- src/shared/Config/Cosmetics/FounderTrail.luau). This file only records
-- that a player owns them; CosmeticService owns what they look like.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local FounderPass: Validate.StoreItemDef = {
	key = "founder-pass",
	kind = "GamePass",
	assetId = 0, -- not created in the Creator Dashboard yet - see init.luau
	enabled = false,
	displayName = "Founder Pass",
	description = "A founder's skin and matching trail. Cosmetic only - it changes nothing about how a race is run.",
	robuxPrice = 199, -- PLACEHOLDER: display only, never read for a grant
	sortOrder = 10,
	grants = {
		{ kind = "Cosmetic", cosmeticId = "skin-founder" },
		{ kind = "Cosmetic", cosmeticId = "trail-founder" },
	},
}

return FounderPass
