--!strict
-- A small particle flourish shown at a finalist's feet during the
-- Decision Studio (design-decisions.md's podium circle) - see
-- CosmeticService for why it only appears in that one round state.
--
-- No Store product grants this - it is a win drop (winDrop = true).
-- A disabled entry waiting on a Roblox asset id; nothing about that
-- blocks P4-6, since Validate only requires a granted cosmetic to be
-- enabled when the product or season granting it is.

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
	winDrop = true, -- design-decisions.md Q1 applied case (2026-10-02): no pass grants it, so wins can drop it
	podiumTextureAssetId = 0,
	podiumColorHex = "#66e0ff",
}

return ChampionPodiumFlare
