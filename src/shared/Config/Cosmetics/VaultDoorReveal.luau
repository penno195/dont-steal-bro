--!strict
-- A vault door swinging open on your podium the instant your Steal/Share
-- is shown. Tinted by the outcome, never by this item - see
-- Validate.CosmeticDef's header for why a reveal has no colour field.
--
-- Drawn by RevealCosmeticController as the card turns. Disabled until it
-- has a Roblox asset and a store product.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VaultDoorReveal: Validate.CosmeticDef = {
	id = "reveal-vault-door",
	category = "Reveal",
	displayName = "Vault Door",
	description = "Your choice is revealed from behind a vault door. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 40,
	enabled = false, -- PLACEHOLDER: no Roblox asset id or product yet
	winDrop = true, -- design-decisions.md Q1 applied case (2026-10-02): no pass grants it, so wins can drop it
	revealTextureAssetId = 0,
}

return VaultDoorReveal
