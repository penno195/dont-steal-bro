--!strict
-- A backwards "ROOKIE" cap: the guided practice round's finishing gift
-- (GameConfig.tutorial, design-decisions.md "the first-time tutorial").
-- Tutorial-only forever: never sold, never a drop, never on a track or a
-- leaderboard, and Validate enforces that.
-- Meshy-made model (assets/seasonpass/make-models.js), generated facing
-- forwards and turned round by wearRotation; "ROOKIE" painted on by
-- add-cap-lettering.py. Imported at centimetre scale, hence the tiny
-- wearScale; fitted on an R15 rig in Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local RookieCapHat: Validate.CosmeticDef = {
	id = "hat-rookie-cap",
	category = "Hat",
	displayName = "Rookie Cap",
	description = "Worn backwards, earned the hard way: by finishing the tutorial. Cosmetic only.",
	rarity = "Common",
	sortOrder = 20,
	enabled = true,
	wearMeshAssetId = 76766742873409,
	wearTextureAssetId = 113024070593124,
	wearScale = 0.011,
	wearOffset = { 0, -0.2, 0.3 }, -- the peak makes the mesh long, so the crown sits off its centre
	wearRotation = { 0, 180, 0 }, -- worn backwards
	previewIconAssetId = 106136180161207,
}

return RookieCapHat
