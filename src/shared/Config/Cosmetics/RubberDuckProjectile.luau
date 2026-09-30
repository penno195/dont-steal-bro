--!strict
-- Your thrown power-ups fly as a rubber duck and land in a splash. Still
-- tinted by the power-up's role and still the usual size, so a victim
-- reads it exactly as they would the default orb.
--
-- Disabled until it has Roblox assets, a store product and a renderer
-- (ThrowController doesn't read the "Projectile" slot yet).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local RubberDuckProjectile: Validate.CosmeticDef = {
	id = "projectile-rubber-duck",
	category = "Projectile",
	displayName = "Rubber Duck",
	description = "Your throws fly as a rubber duck. Same colour, same size, same effect - cosmetic only.",
	rarity = "Uncommon",
	sortOrder = 50,
	enabled = false, -- PLACEHOLDER: no Roblox asset ids, product or renderer yet
	projectileMeshAssetId = 0,
	explosionTextureAssetId = 0,
}

return RubberDuckProjectile
