--!strict
-- The pure half of per-map lighting (P7-5). It turns a lighting preset
-- into a flat list of property writes. LightingService
-- (Services/LightingService.luau) makes the Roblox calls; this module
-- decides what they are, so the one guarantee that matters can be tested
-- headlessly (tests/LightingLogic.spec.luau): no state leaks between
-- rounds.
--
-- There are two ways state could leak, and both are ruled out by shape,
-- not by care:
--   1. Every plan writes EXACTLY `LIGHTING_PROPERTIES`, the same list the
--      service snapshots at boot and restores on Cleanup. A preset can't
--      set a property the restore doesn't know about. And because every
--      preset writes every property, a map never inherits a value left
--      over from the previous one.
--   2. Post effects are never edited in place. The service creates its
--      own ColorCorrectionEffect/BloomEffect for the preset and destroys
--      them on restore, so a nil `bloom` means "no BloomEffect exists",
--      not "leave whatever bloom was there alone".
--
-- Self-contained on purpose, like TeleportLogic: no requires, so Lune can
-- load it. `Preset` is a structural mirror of Validate.LightingPresetDef.
-- LightingService passes the real def in, so luau-lsp catches any drift
-- between the two at that call site.

local LightingLogic = {}

-- "color" values are "#RRGGBB" strings (the service calls Color3.fromHex).
-- "enum" values are item names of Enum.LightingStyle.
export type ValueKind = "number" | "boolean" | "color" | "enum"

export type Assignment = {
	property: string,
	kind: ValueKind,
	value: number | boolean | string,
}

export type Plan = {
	lighting: { Assignment },
	colorCorrection: { Assignment }?,
	bloom: { Assignment }?,
}

export type Preset = {
	id: string,
	lightingStyle: string,
	prioritizeLightingQuality: boolean,
	globalShadows: boolean,
	ambient: string,
	outdoorAmbient: string,
	brightness: number,
	clockTime: number,
	environmentDiffuseScale: number,
	environmentSpecularScale: number,
	exposureCompensation: number,
	fogColor: string,
	fogStart: number,
	fogEnd: number,
	colorCorrection: { brightness: number, contrast: number, saturation: number, tintColor: string }?,
	bloom: { intensity: number, size: number, threshold: number }?,
}

-- The Lighting properties a preset owns, in apply order. LightingService
-- snapshots exactly these at boot. Adding a property to presets means
-- adding it here too, and the spec fails until both agree.
LightingLogic.LIGHTING_PROPERTIES = {
	"LightingStyle",
	"PrioritizeLightingQuality",
	"GlobalShadows",
	"Ambient",
	"OutdoorAmbient",
	"Brightness",
	"ClockTime",
	"EnvironmentDiffuseScale",
	"EnvironmentSpecularScale",
	"ExposureCompensation",
	"FogColor",
	"FogStart",
	"FogEnd",
}

function LightingLogic.plan(preset: Preset): Plan
	local plan: Plan = {
		lighting = {
			{ property = "LightingStyle", kind = "enum", value = preset.lightingStyle },
			{ property = "PrioritizeLightingQuality", kind = "boolean", value = preset.prioritizeLightingQuality },
			{ property = "GlobalShadows", kind = "boolean", value = preset.globalShadows },
			{ property = "Ambient", kind = "color", value = preset.ambient },
			{ property = "OutdoorAmbient", kind = "color", value = preset.outdoorAmbient },
			{ property = "Brightness", kind = "number", value = preset.brightness },
			{ property = "ClockTime", kind = "number", value = preset.clockTime },
			{ property = "EnvironmentDiffuseScale", kind = "number", value = preset.environmentDiffuseScale },
			{ property = "EnvironmentSpecularScale", kind = "number", value = preset.environmentSpecularScale },
			{ property = "ExposureCompensation", kind = "number", value = preset.exposureCompensation },
			{ property = "FogColor", kind = "color", value = preset.fogColor },
			{ property = "FogStart", kind = "number", value = preset.fogStart },
			{ property = "FogEnd", kind = "number", value = preset.fogEnd },
		},
	}

	local grade = preset.colorCorrection
	if grade ~= nil then
		local assignments: { Assignment } = {
			{ property = "Brightness", kind = "number", value = grade.brightness },
			{ property = "Contrast", kind = "number", value = grade.contrast },
			{ property = "Saturation", kind = "number", value = grade.saturation },
			{ property = "TintColor", kind = "color", value = grade.tintColor },
		}
		plan.colorCorrection = assignments
	end

	local bloom = preset.bloom
	if bloom ~= nil then
		local assignments: { Assignment } = {
			{ property = "Intensity", kind = "number", value = bloom.intensity },
			{ property = "Size", kind = "number", value = bloom.size },
			{ property = "Threshold", kind = "number", value = bloom.threshold },
		}
		plan.bloom = assignments
	end

	return plan
end

-- Looks a map's preset up by id. It returns nil rather than erroring, and
-- the service keeps the place's default lighting in that case. Enabled
-- maps can't reach this with a bad id, because Validate.run fails boot
-- first. This only catches a disabled map loaded by StudioTestService.
function LightingLogic.find(presets: { { def: Preset } }, presetId: string): Preset?
	for _, entry in presets do
		if entry.def.id == presetId then
			return entry.def
		end
	end
	return nil
end

return LightingLogic
