--!strict
-- map-kit-spec.md §2. `id` must equal the built model's Name in
-- ServerStorage.Maps - ConfigValidator and the P7-1 validator both match
-- on it. Asset ids are still PLACEHOLDERS (P7-4).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Laboratory: Validate.MapDef = {
	id = "Laboratory",
	displayName = "Laboratory",
	description = "Science says trust no one. Peer-reviewed.",
	thumbnailAssetId = "rbxassetid://0", -- PLACEHOLDER
	lightingPreset = "Laboratory", -- Config/LightingPresets/Laboratory.luau (P7-5)
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
	taskStationCount = 16, -- built count (Match.rbxl, 2026-10-03)
	-- P7-6. This is the only preset with bloom, and Neon blooms, so the
	-- pads would glow as a dozen halos around the containment core (the
	-- landmark players navigate by). The pad is off. The shaft is warm so
	-- it can't be mistaken for the core's cool glow. Starting values:
	-- confirm them in the readability playtest.
	stationMarker = {
		beam = true,
		pad = false,
		beamHeight = 12,
		tint = "#FFB86B",
	},
}

return Laboratory
