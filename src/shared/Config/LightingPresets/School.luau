--!strict
-- School is the onboarding map (wave1-briefs.md §2), so readability wins
-- every trade-off. The school is fully roofed, with a glass atrium over
-- the courtyard: a high early-afternoon sun drops through the atrium, and
-- a bright, slightly warm ambient stands in for the classroom strip
-- lights (Neon panels, no Light instances), so nothing under the roof is
-- ever dim. No post effects at all.
-- Shadows stay on: they are what makes the roof read as indoors and puts
-- the atrium beams' light pool on the courtyard floor.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local School: Validate.LightingPresetDef = {
	id = "School",
	lightingStyle = "Soft",
	prioritizeLightingQuality = false,
	globalShadows = true,
	ambient = "#AAA8A4",
	outdoorAmbient = "#A0A0AA",
	brightness = 2.5,
	clockTime = 13,
	environmentDiffuseScale = 1,
	environmentSpecularScale = 0.5,
	exposureCompensation = 0,
	-- Far horizon haze only. Nothing inside the ~260-stud footprint fogs.
	fogColor = "#C8D8E8",
	fogStart = 400,
	fogEnd = 2000,
	colorCorrection = nil,
	bloom = nil,
}

return School
