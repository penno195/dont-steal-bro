--!strict
-- School is the onboarding map (wave1-briefs.md §2), so readability wins
-- every trade-off. It gets a bright early-afternoon sun into the
-- courtyard, high neutral ambient so the classrooms are never dim, and no
-- post effects at all.
-- Shadows stay on because the courtyard is outdoors, and without them the
-- clock tower and the upper walkway lose all depth.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local School: Validate.LightingPresetDef = {
	id = "School",
	lightingStyle = "Soft",
	prioritizeLightingQuality = false,
	globalShadows = true,
	ambient = "#8C8C96",
	outdoorAmbient = "#A0A0AA",
	brightness = 2.5,
	clockTime = 14,
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
