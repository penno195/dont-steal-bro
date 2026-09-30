--!strict
-- A vault door swinging open on your podium the instant your Steal/Share
-- is shown. Tinted by the outcome, never by this item - see
-- Validate.CosmeticDef's header for why a reveal has no colour field.
--
-- Disabled until it has a Roblox asset, a store product and a renderer
-- (no service draws the "Reveal" category yet).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VaultDoorReveal: Validate.CosmeticDef = {
	id = "reveal-vault-door",
	category = "Reveal",
	displayName = "Vault Door",
	description = "Your choice is revealed from behind a vault door. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 40,
	enabled = false, -- PLACEHOLDER: no Roblox asset id, product or renderer yet
	revealTextureAssetId = 0,
}

return VaultDoorReveal
