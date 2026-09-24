--!strict
-- Museum (wave1-briefs.md §4): midday light pooling under the dome onto
-- the dinosaur skeleton, with calm, even gallery light everywhere else.
-- This is the cheapest preset. Shadows are its only cost, and they pay for
-- themselves because the dome's light pool is what makes the hero landmark
-- read from every gallery.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Museum: Validate.LightingPresetDef = {
	id = "Museum",
	lightingStyle = "Soft",
	prioritizeLightingQuality = false,
	globalShadows = true,
	ambient = "#96918A",
	outdoorAmbient = "#A8A298",
	brightness = 2,
	clockTime = 12,
	environmentDiffuseScale = 1,
	environmentSpecularScale = 0.3,
	exposureCompensation = 0,
	-- Horizon only. An indoor map gets nothing from fog.
	fogColor = "#E6E0D6",
	fogStart = 500,
	fogEnd = 2500,
	colorCorrection = nil,
	bloom = nil,
}

return Museum
