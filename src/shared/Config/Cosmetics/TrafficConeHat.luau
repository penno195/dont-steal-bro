--!strict
-- A traffic cone on your head: the free row's only model (10 wins).
-- Season 1 track item (Seasons/Season1.luau), so track-only forever.
-- Disabled until its Meshy-made mesh and texture are uploaded and their
-- ids pasted below; wearScale/wearOffset are tuned in Studio after that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local TrafficConeHat: Validate.CosmeticDef = {
	id = "hat-traffic-cone",
	category = "Hat",
	displayName = "Traffic Cone",
	description = "A traffic cone, worn with pride. Cosmetic only.",
	rarity = "Uncommon",
	sortOrder = 22,
	enabled = false,
	wearMeshAssetId = 0,
	wearTextureAssetId = 0,
	wearScale = 1,
}

return TrafficConeHat
