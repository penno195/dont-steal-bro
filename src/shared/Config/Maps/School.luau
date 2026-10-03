--!strict
-- map-kit-spec.md §2. `id` must equal the built model's Name in
-- ServerStorage.Maps - ConfigValidator and the P7-1 validator both match
-- on it. Asset ids are still PLACEHOLDERS (P7-4).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local School: Validate.MapDef = {
	id = "School",
	displayName = "School",
	description = "Detention for anyone caught stealing. So, everyone.",
	thumbnailAssetId = "rbxassetid://0", -- PLACEHOLDER
	lightingPreset = "School", -- Config/LightingPresets/School.luau (P7-5)
	musicTrackId = "rbxassetid://0", -- PLACEHOLDER
	-- Full registered set for now; prune after playtesting.
	enabledTaskIds = {
		"code-playback",
		"fuse-rewire",
		"pressure-valve",
		"vent-purge",
		"alarm-killswitch",
		"breaker-sequence",
		"reactor-sync",
		"airlock-cycle",
	},
	npcDifficultyModifier = 1.0,
	waveNumber = 1,
	enabled = true, -- wave 1; built in the Match place's ServerStorage.Maps
	taskStationCount = 16, -- built count (School-Studio.rbxl, validated 2026-10-03)
}

return School
