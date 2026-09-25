--!strict
-- SpaceStation (wave 3): a sealed two-deck interior under a ceiling, lit
-- by its own panels rather than a sun. Night outside (clockTime 0) keeps
-- the windows full of stars, so interior light comes from ambient: a
-- cool blue-grey high enough that no station sits in shade, per the
-- map-building handoff's lighting rule.
-- A light bloom brings out the cyan hex-panel strips from the source
-- kit. It replaces the Bloom/ColorGrading the kit shipped directly under
-- Lighting, which the handoff forbids (presets own post effects).
-- Shadows off: under a ceiling the sun can't reach, they only cost.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SpaceStation: Validate.LightingPresetDef = {
	id = "SpaceStation",
	lightingStyle = "Soft",
	prioritizeLightingQuality = false,
	globalShadows = false,
	ambient = "#6A7890",
	outdoorAmbient = "#5A6A84",
	brightness = 1,
	clockTime = 0,
	environmentDiffuseScale = 0.4,
	environmentSpecularScale = 0.6,
	exposureCompensation = 0.3,
	-- Deep-space tint, far enough out that nothing inside the ~250-stud
	-- footprint fogs.
	fogColor = "#0B1420",
	fogStart = 300,
	fogEnd = 1200,
	colorCorrection = {
		brightness = 0.03,
		contrast = 0.1,
		saturation = 0.05,
		tintColor = "#EAF6FF",
	},
	bloom = {
		intensity = 0.35,
		size = 20,
		threshold = 1.3,
	},
}

return SpaceStation
