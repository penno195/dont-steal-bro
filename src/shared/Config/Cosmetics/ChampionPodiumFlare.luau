--!strict
-- A small particle flourish shown at a finalist's feet during the
-- Decision Studio (design-decisions.md's podium circle) - see
-- CosmeticService for why it only appears in that one round state.
--
-- No Store product grants this yet - same "written before the product
-- exists" stance FounderPass.luau and VictoryEmotePass.luau took the
-- other way around (a store entry forward-referencing a cosmetic id).
-- Here it's a real, validated, disabled entry waiting on both a Roblox
-- asset id and a product to sell it. Nothing about that blocks P4-6:
-- Validate.checkStoreItem only requires a Cosmetic grant's id to exist
-- and be enabled when a product actually grants it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local ChampionPodiumFlare: Validate.CosmeticDef = {
	id = "podium-champion-flare",
	category = "Podium",
	displayName = "Champion's Flare",
	description = "A quiet spark at your feet while the Studio decides. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 30,
	enabled = false, -- PLACEHOLDER: no Roblox asset id and no store product yet
	podiumTextureAssetId = 0,
	podiumColorHex = "#66e0ff",
}

return ChampionPodiumFlare
