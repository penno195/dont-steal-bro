--!strict
-- map-kit-spec.md §2. `id` must equal the built model's Name in
-- ServerStorage.Maps - ConfigValidator and the P7-1 validator both match
-- on it. Asset ids, lighting preset and station count are PLACEHOLDERS
-- until the map is built (P7-4) and lit (P7-5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SpaceStation: Validate.MapDef = {
	id = "SpaceStation",
	displayName = "Space Station",
	description = "In space, no one can hear you steal.",
	thumbnailAssetId = "rbxassetid://0", -- PLACEHOLDER
	lightingPreset = "SpaceStation",
	musicTrackId = "rbxassetid://0", -- PLACEHOLDER
	-- vent-purge is left out: it has a TaskDef but no handler or view yet,
	-- so a station offering it would open nothing.
	enabledTaskIds = {
		"code-playback",
		"fuse-rewire",
		"pressure-valve",
	},
	npcDifficultyModifier = 1.0,
	waveNumber = 3,
	enabled = false,
	taskStationCount = 16, -- the built map (2026-09-25 gray-box)
}

return SpaceStation
