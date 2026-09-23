--!strict
-- Pure colour maths for the theme (P6-1): WCAG contrast, colour-vision
-- deficiency simulation, and a perceptual distance. No Roblox API at
-- all - colours are hex strings and plain RGB triples - so
-- tests/Theme.spec.luau can prove the Steal/Share pair survives every
-- simulation headlessly, instead of someone eyeballing a swatch once.
--
-- WHY SIMULATE RATHER THAN JUST AVOID RED/GREEN:
-- "Don't use red and green" is a rule of thumb, not a test. Plenty of
-- non-red/green pairs still collapse for someone (blue/purple under
-- protanopia, blue/green under tritanopia). Running the actual pair
-- through a published simulation model and measuring the distance that
-- is left over turns "we think it's fine" into an assertion CI keeps
-- checking every time someone retunes a hex value.
--
-- MODEL: Machado, Oliveira & Fernandes (2009), "A Physiologically-based
-- Model for Simulation of Color Vision Deficiency", severity 1.0 - i.e.
-- full dichromacy (protanopia, deuteranopia, tritanopia), the worst case
-- of each type. The matrices apply to LINEAR RGB, not gamma-encoded
-- sRGB; applying them to raw hex values is a common bug that makes
-- every simulated colour too dark. Achromatopsia (no colour at all) is
-- modelled as the colour's own relative luminance, which is also the
-- honest worst case for a greyscale screenshot or a dimmed phone.
--
-- DISTANCE: Euclidean distance in OKLab (Ottosson, 2020). OKLab is
-- close enough to perceptually uniform that a single threshold means
-- roughly the same thing everywhere in the gamut, it's a few lines of
-- arithmetic, and it has no tuning constants the way CIEDE2000 does.
-- For scale: ~0.02 is a just-noticeable difference; the theme's pair
-- floor (Tokens.contrast.decisionPairMinDistance) is set far above that
-- because the Decision Studio choice must read at a glance under stress,
-- not merely be distinguishable when you look for it.

export type RGB = { r: number, g: number, b: number }
export type Deficiency = "protanopia" | "deuteranopia" | "tritanopia" | "achromatopsia"

local ColorVision = {}

ColorVision.DEFICIENCIES = table.freeze({
	"protanopia",
	"deuteranopia",
	"tritanopia",
	"achromatopsia",
} :: { Deficiency })

-- Row-major 3x3, linear RGB in -> linear RGB out.
local MACHADO: { [Deficiency]: { number } } = {
	protanopia = {
		0.152286,
		1.052583,
		-0.204868,
		0.114503,
		0.786281,
		0.099216,
		-0.003882,
		-0.048116,
		1.051998,
	},
	deuteranopia = {
		0.367322,
		0.860646,
		-0.227968,
		0.280085,
		0.672501,
		0.047413,
		-0.011820,
		0.042940,
		0.968881,
	},
	tritanopia = {
		1.255528,
		-0.076749,
		-0.178779,
		-0.078411,
		0.930809,
		0.147602,
		0.004733,
		0.691367,
		0.303900,
	},
}

-- "#RRGGBB" or "RRGGBB" -> gamma-encoded sRGB in 0..1.
function ColorVision.fromHex(hex: string): RGB
	local digits = string.gsub(hex, "^#", "")
	assert(string.match(digits, "^%x%x%x%x%x%x$") ~= nil, string.format("ColorVision.fromHex: %q is not #RRGGBB", hex))
	return {
		r = (tonumber(string.sub(digits, 1, 2), 16) :: number) / 255,
		g = (tonumber(string.sub(digits, 3, 4), 16) :: number) / 255,
		b = (tonumber(string.sub(digits, 5, 6), 16) :: number) / 255,
	}
end

function ColorVision.toHex(c: RGB): string
	local function byte(v: number): number
		return math.floor(math.clamp(v, 0, 1) * 255 + 0.5)
	end
	return string.format("#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b))
end

local function toLinear(v: number): number
	return if v <= 0.04045 then v / 12.92 else ((v + 0.055) / 1.055) ^ 2.4
end

local function toGamma(v: number): number
	local c = math.clamp(v, 0, 1)
	return if c <= 0.0031308 then c * 12.92 else 1.055 * c ^ (1 / 2.4) - 0.055
end

-- WCAG 2.x relative luminance, 0 (black) .. 1 (white).
function ColorVision.luminance(c: RGB): number
	return 0.2126 * toLinear(c.r) + 0.7152 * toLinear(c.g) + 0.0722 * toLinear(c.b)
end

-- WCAG 2.x contrast ratio, 1 .. 21. Order of arguments doesn't matter.
function ColorVision.contrast(a: RGB, b: RGB): number
	local la, lb = ColorVision.luminance(a), ColorVision.luminance(b)
	local hi, lo = math.max(la, lb), math.min(la, lb)
	return (hi + 0.05) / (lo + 0.05)
end

-- How `c` appears to someone with the given deficiency, back in
-- gamma-encoded sRGB so the result can be shown on a swatch.
function ColorVision.simulate(c: RGB, deficiency: Deficiency): RGB
	if deficiency == "achromatopsia" then
		local grey = toGamma(ColorVision.luminance(c))
		return { r = grey, g = grey, b = grey }
	end

	local m = MACHADO[deficiency]
	local r, g, b = toLinear(c.r), toLinear(c.g), toLinear(c.b)
	return {
		r = toGamma(m[1] * r + m[2] * g + m[3] * b),
		g = toGamma(m[4] * r + m[5] * g + m[6] * b),
		b = toGamma(m[7] * r + m[8] * g + m[9] * b),
	}
end

-- Gamma-encoded sRGB -> OKLab (L, a, b).
local function toOklab(c: RGB): (number, number, number)
	local r, g, b = toLinear(c.r), toLinear(c.g), toLinear(c.b)
	local l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
	local m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
	local s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
	l, m, s = l ^ (1 / 3), m ^ (1 / 3), s ^ (1 / 3)
	return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

-- Perceptual distance in OKLab. 0 = identical; ~0.02 = just noticeable.
function ColorVision.distance(a: RGB, b: RGB): number
	local L1, a1, b1 = toOklab(a)
	local L2, a2, b2 = toOklab(b)
	return math.sqrt((L1 - L2) ^ 2 + (a1 - a2) ^ 2 + (b1 - b2) ^ 2)
end

-- The distance between two colours as seen with the given deficiency -
-- the number the Steal/Share test actually asserts on.
function ColorVision.simulatedDistance(a: RGB, b: RGB, deficiency: Deficiency): number
	return ColorVision.distance(ColorVision.simulate(a, deficiency), ColorVision.simulate(b, deficiency))
end

return ColorVision
