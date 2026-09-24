--!strict
-- map-kit-spec.md §2. `id` must equal the built model's Name in
-- ServerStorage.Maps - ConfigValidator and the P7-1 validator both match
-- on it. Asset ids, lighting preset and station count are PLACEHOLDERS
-- until the map is built (P7-4) and lit (P7-5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local School: Validate.MapDef = {
	id = "School",
	displayName = "School",
	description = "Detention for anyone caught stealing. So, everyone.",
	thumbnailAssetId = "rbxassetid://0", -- PLACEHOLDER
	lightingPreset = "School", -- PLACEHOLDER: key into P7-5's preset table
	musicTrackId = "rbxassetid://0", -- PLACEHOLDER
	-- Full registered set for now; prune after playtesting.
	enabledTaskIds = {
		"code-playback",
		"fuse-rewire",
		"pressure-valve",
		"vent-purge",
	},
	npcDifficultyModifier = 1.0,
	waveNumber = 1,
	enabled = false, -- wave 1: set true once built in ServerStorage.Maps
	taskStationCount = 12, -- PLACEHOLDER: spec floor; update to the real built count
}

return School
