--!strict
-- map-kit-spec.md §2. `id` must equal the built model's Name in
-- ServerStorage.Maps - ConfigValidator and the P7-1 validator both match
-- on it. The map is built and lit; the thumbnail and music asset ids
-- are still PLACEHOLDERS, and it stays disabled until they're real.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SpaceStation: Validate.MapDef = {
	id = "SpaceStation",
	displayName = "Space Station",
	description = "In space, no one can hear you steal.",
	thumbnailAssetId = "rbxassetid://0", -- PLACEHOLDER
	lightingPreset = "SpaceStation",
	musicTrackId = "rbxassetid://0", -- PLACEHOLDER
	enabledTaskIds = {
		"code-playback",
		"fuse-rewire",
		"pressure-valve",
		"vent-purge",
	},
	npcDifficultyModifier = 1.0,
	waveNumber = 3,
	enabled = false,
	taskStationCount = 16, -- the built map (2026-09-25 gray-box)
}

return SpaceStation
