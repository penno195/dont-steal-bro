--!strict
-- A backwards "ROOKIE" cap: the guided practice round's finishing gift
-- (GameConfig.tutorial, design-decisions.md "the first-time tutorial").
-- Tutorial-only forever: never sold, never a drop, never on a track or a
-- leaderboard, and Validate enforces that.
-- Meshy-made model (assets/seasonpass/make-models.js), generated facing
-- forwards and turned round by wearRotation. Disabled until the mesh is
-- imported and fitted; set wearMeshAssetId and enabled = true together.

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
	wearTextureAssetId = 98585095390229,
	wearScale = 0.0115, -- narrower than the beanie (the peak takes the length), so bigger
	wearRotation = { 0, 180, 0 }, -- worn backwards
	previewIconAssetId = 137890664825264,
}

return RookieCapHat
