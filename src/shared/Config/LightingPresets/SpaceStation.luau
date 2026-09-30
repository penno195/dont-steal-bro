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
	-- Raised 2026-09-29 (playtest: "hard to see in") from #6A7890 /
	-- #5A6A84 and exposure 0.3. The station's floors and walls are dark
	-- navy, and ambient can only lift a surface in proportion to its own
	-- colour, so it takes a lot: tried live in Studio, a half step
	-- (#8C9AB2, 0.5) barely showed. Exposure is at the validator's cap.
	ambient = "#D2DCEC",
	outdoorAmbient = "#BCC8DC",
	brightness = 1,
	clockTime = 0,
	environmentDiffuseScale = 0.4,
	environmentSpecularScale = 0.6,
	exposureCompensation = 1,
	-- Deep-space tint, far enough out that nothing inside the ~250-stud
	-- footprint fogs.
	fogColor = "#0B1420",
	fogStart = 300,
	fogEnd = 1200,
	colorCorrection = {
		brightness = 0.05,
		contrast = 0.1,
		saturation = 0.05,
		tintColor = "#EAF6FF",
	},
	-- Toned down 2026-09-29 from intensity 0.35 / size 20 / threshold
	-- 1.3: the 140 neon strips glow on their own, and with the brighter
	-- exposure above the old bloom haloed them into the view. A higher
	-- threshold means only the brightest neon catches it.
	bloom = {
		intensity = 0.1,
		size = 12,
		threshold = 2,
	},
}

return SpaceStation
