--!strict
-- Factory (wave1-briefs.md §3): a low, warm late-afternoon sun through the
-- skylights and dusty haze, so it reads as heavy industry.
-- Shadows are on. The skylight shafts falling across the production line
-- are what separate the catwalk level from the floor.
-- There is no bloom, even though the furnace glows. This is the densest
-- map, and Neon plus an orange PointLight sells the furnace without a
-- full-screen pass.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Factory: Validate.LightingPresetDef = {
	id = "Factory",
	lightingStyle = "Realistic",
	prioritizeLightingQuality = false,
	globalShadows = true,
	ambient = "#6E6458",
	outdoorAmbient = "#8A7A66",
	brightness = 2,
	clockTime = 16.5,
	environmentDiffuseScale = 0.6,
	environmentSpecularScale = 0.4,
	exposureCompensation = 0,
	-- Starts past the longest designed sightline, so it hazes the far end of
	-- the floor and the loading yard but never an overtake.
	fogColor = "#8A7560",
	fogStart = 150,
	fogEnd = 700,
	colorCorrection = {
		brightness = 0,
		contrast = 0.1,
		saturation = -0.05,
		tintColor = "#FFF0DC",
	},
	bloom = nil,
}

return Factory
