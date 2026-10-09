--!strict
-- A traffic cone on your head: the free row's only model (10 wins).
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Meshy-made model (assets/seasonpass/make-models.js), imported at
-- centimetre scale, hence the tiny wearScale; fitted on an R15 rig in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local TrafficConeHat: Validate.CosmeticDef = {
	id = "hat-traffic-cone",
	category = "Hat",
	displayName = "Traffic Cone",
	description = "A traffic cone, worn with pride. Cosmetic only.",
	rarity = "Uncommon",
	sortOrder = 22,
	enabled = true,
	wearMeshAssetId = 71094037180826,
	wearTextureAssetId = 130224171322010,
	wearScale = 0.0078,
	wearOffset = { 0, 0.55, 0 },
	previewIconAssetId = 90448238759704,
}

return TrafficConeHat
