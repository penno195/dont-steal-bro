--!strict
-- Your thrown power-ups fly as a rubber duck and land in a splash. Still
-- tinted by the power-up's role and still the usual size, so a victim
-- reads it exactly as they would the default orb.
--
-- Drawn by ThrowController. Disabled until it has its mesh asset id.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local RubberDuckProjectile: Validate.CosmeticDef = {
	id = "projectile-rubber-duck",
	category = "Projectile",
	displayName = "Rubber Duck",
	description = "Your throws fly as a rubber duck. Same colour, same size, same effect - cosmetic only.",
	rarity = "Uncommon",
	sortOrder = 50,
	enabled = false, -- PLACEHOLDER: needs projectileMeshAssetId (assets/cosmetics/README.md)
	winDrop = true, -- design-decisions.md Q1 applied case (2026-10-02): no pass grants it, so wins can drop it
	projectileMeshAssetId = 0,
	explosionTextureAssetId = 114742972878274,
}

return RubberDuckProjectile
