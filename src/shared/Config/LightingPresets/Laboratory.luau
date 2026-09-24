--!strict
-- Laboratory (wave1-briefs.md §5): a sunken facility at night, cool
-- ambient, lit by its own fittings and the glowing containment core.
-- Shadows are off. The map is underground, so the sun contributes nothing
-- and a shadow pass would be pure cost.
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
	ambient = "#50607A",
	outdoorAmbient = "#46556E",
	brightness = 1,
	clockTime = 0,
	environmentDiffuseScale = 0.3,
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
