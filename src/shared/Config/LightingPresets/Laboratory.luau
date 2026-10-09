--!strict
-- Laboratory (wave1-briefs.md §5): a sunken facility, cool ambient, with
-- the glowing containment core as its landmark.
-- Shadows are off, which a shadow pass would only cost here. With
-- shadows off the sun lights straight through the roof, so the sun is
-- the Lab's main light. That is why clockTime is midday: the old
-- clockTime 0 meant moonlight, and the map read near-black in Play
-- (owner's iPhone playtest, 2026-10-09).
-- This is the one preset with bloom. The core is the hero landmark, and a
-- high threshold means only Neon surfaces bloom, so the glow is what
-- players navigate by and station props are never washed out.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Laboratory: Validate.LightingPresetDef = {
	id = "Laboratory",
	lightingStyle = "Realistic",
	prioritizeLightingQuality = false,
	globalShadows = false,
	-- Brightening ambient (2026-10-03) barely helped; the clock was the
	-- real fix. Checked in Studio Play: 14:00 with exposure 0.2 keeps the
	-- dark carpet readable without washing out the shaft (0.4 did).
	ambient = "#8A9AB4",
	outdoorAmbient = "#7686A2",
	brightness = 1.5,
	clockTime = 14,
	environmentDiffuseScale = 0.5,
	environmentSpecularScale = 0.6,
	exposureCompensation = 0.2,
	-- Gives depth when looking down the shaft. It starts past the longest
	-- sightline, which here is the 60-stud shaft plus a ring walkway.
	fogColor = "#1A2A33",
	fogStart = 140,
	fogEnd = 500,
	colorCorrection = {
		brightness = 0.05,
		contrast = 0.15,
		saturation = 0,
		tintColor = "#E0F4FF",
	},
	bloom = {
		intensity = 0.4,
		size = 24,
		threshold = 1.2,
	},
}

return Laboratory
