--!strict
-- A backwards "ROOKIE" cap: the guided practice round's finishing gift
-- (GameConfig.tutorial, design-decisions.md "the first-time tutorial").
-- Tutorial-only forever: never sold, never a drop, never on a track or a
-- leaderboard, and Validate enforces that. Disabled until its model is
-- made and fitted; set the asset ids and enabled = true together.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local RookieCapHat: Validate.CosmeticDef = {
	id = "hat-rookie-cap",
	category = "Hat",
	displayName = "Rookie Cap",
	description = "Worn backwards, earned the hard way: by finishing the tutorial. Cosmetic only.",
	rarity = "Common",
	sortOrder = 20,
	enabled = false,
	wearMeshAssetId = 0,
	wearTextureAssetId = 0,
	wearScale = 1,
	previewIconAssetId = 0,
}

return RookieCapHat
