--!strict
-- A gold crown packed with stolen diamonds: a limited edition, sold only
-- by Store/DiamondHeistCrown.luau (149 R$, until 2026-12-01 UTC), then
-- never again; owners keep it. Not a drop, prize or track item.
-- Meshy-made model (assets/seasonpass/make-models.js), imported at
-- centimetre scale, hence the tiny wearScale; fitted on an R15 rig in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local DiamondHeistCrown: Validate.CosmeticDef = {
	id = "hat-diamond-heist-crown",
	category = "Hat",
	displayName = "Diamond Heist Crown",
	description = "A gold crown packed with stolen diamonds. Limited edition. Cosmetic only.",
	rarity = "Rare",
	sortOrder = 26,
	enabled = true,
	wearMeshAssetId = 131259672821092,
	wearTextureAssetId = 135718904385281,
	wearScale = 0.008,
	wearOffset = { 0, 0.45, 0 }, -- its base just under the head top, so it sits on the hair (2026-10-10)
	previewIconAssetId = 108786929402766,
}

return DiamondHeistCrown
