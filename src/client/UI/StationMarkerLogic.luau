--!strict
-- The pure half of the station markers (P7-6): which state a station is
-- in for you, what each state looks like, and a map's resolved marker
-- style. No Roblox API and no requires. Transparency comes back as plain
-- {time, value} pairs that the controller turns into a NumberSequence,
-- so tests/StationMarkerLogic.spec.luau runs all of it under Lune.
--
-- The four states have to be told apart without colour
-- (accessibility.md), so each one differs in SHAPE or MOTION, and every
-- state uses the same tint:
--
--   Ready  continuous shaft, breathing pad      "come here"
--   Rival  broken (dashed) shaft, still pad, 👤  "someone's on it"
--   Mine   no shaft, solid still pad            you're standing in it
--   Done   no shaft, faint pad, ✓               stops calling you
--
-- A station that isn't on your route gets nothing at all. The only
-- shafts in the scene are the ones you need, which does more for
-- readability than any effect could.

local StationMarkerLogic = {}

export type State = "Hidden" | "Ready" | "Rival" | "Mine" | "Done"

export type Inputs = {
	assigned: boolean, -- on your route
	completed: boolean, -- done by you
	mine: boolean, -- your attempt is open here
	others: number, -- rivals (human or NPC) with an attempt open here
}

export type BeamPattern = "Solid" | "Dashed" | "Off"

export type Look = {
	beam: BeamPattern,
	padTransparency: number,
	pulse: boolean, -- the pad breathes
	glyph: string?, -- an Icons key, shown close up only
}

export type Style = {
	beam: boolean,
	pad: boolean,
	beamHeight: number,
	tint: string,
}

export type Keypoint = { time: number, value: number }

-- What a map gets with no `stationMarker` in its MapDef, plus the
-- theme's brand colour as the tint.
StationMarkerLogic.DEFAULT_BEAM_HEIGHT = 12

-- The glyph only shows within this many studs, so it can't pile up into
-- a HUD across the map. From further away the shaft does the talking.
StationMarkerLogic.GLYPH_MAX_DISTANCE = 45

local LOOKS: { [State]: Look } = {
	Ready = table.freeze({ beam = "Solid" :: BeamPattern, padTransparency = 0.45, pulse = true }),
	Rival = table.freeze({ beam = "Dashed" :: BeamPattern, padTransparency = 0.45, pulse = false, glyph = "rival" }),
	Mine = table.freeze({ beam = "Off" :: BeamPattern, padTransparency = 0.3, pulse = false }),
	Done = table.freeze({ beam = "Off" :: BeamPattern, padTransparency = 0.85, pulse = false, glyph = "check" }),
}

-- Shaft opacity at the base and at the top. It fades to nothing so there
-- is no hard end, which is what makes it read as light rather than as a
-- pole or a UI pillar.
local BEAM_BASE = 0.3
local BEAM_TOP = 1
local DASHES = 4
-- Width of a dash's hard edge. NumberSequence keypoints need strictly
-- increasing times, so an edge is two keypoints this far apart.
local EDGE = 0.002

function StationMarkerLogic.state(inputs: Inputs): State
	if not inputs.assigned then
		return "Hidden"
	end
	if inputs.completed then
		return "Done"
	end
	if inputs.mine then
		return "Mine"
	end
	if inputs.others > 0 then
		return "Rival"
	end
	return "Ready"
end

-- nil for Hidden: nothing is drawn.
function StationMarkerLogic.look(state: State): Look?
	return LOOKS[state]
end

-- A map's MapDef.stationMarker (or nil) resolved against the defaults.
-- `brandTint` is Tokens.color.brand, passed in to keep this require-free.
function StationMarkerLogic.style(
	def: {
		beam: boolean,
		pad: boolean,
		beamHeight: number,
		tint: string?,
	}?,
	brandTint: string
): Style
	if def == nil then
		return table.freeze({
			beam = true,
			pad = true,
			beamHeight = StationMarkerLogic.DEFAULT_BEAM_HEIGHT,
			tint = brandTint,
		})
	end
	return table.freeze({
		beam = def.beam,
		pad = def.pad,
		beamHeight = def.beamHeight,
		tint = def.tint or brandTint,
	})
end

local function fade(time: number): number
	return BEAM_BASE + (BEAM_TOP - BEAM_BASE) * time
end

-- Transparency along the shaft, bottom (0) to top (1). Empty for Off.
-- Dashed takes 2 + 2 * (DASHES * 2 - 1) = 16 keypoints, under the
-- engine's limit of 20.
function StationMarkerLogic.beamTransparency(pattern: BeamPattern): { Keypoint }
	if pattern == "Off" then
		return {}
	end
	if pattern == "Solid" then
		return {
			{ time = 0, value = BEAM_BASE },
			{ time = 1, value = BEAM_TOP },
		}
	end

	-- Alternating lit and gap bands, starting lit at the base.
	local bands = DASHES * 2
	local points: { Keypoint } = { { time = 0, value = fade(0) } }
	for band = 1, bands - 1 do
		local edge = band / bands
		local wasLit = band % 2 == 1
		local before = if wasLit then fade(edge) else 1
		local after = if wasLit then 1 else fade(edge)
		table.insert(points, { time = edge - EDGE / 2, value = before })
		table.insert(points, { time = edge + EDGE / 2, value = after })
	end
	-- The last band is a gap (bands is even), so the top is clear.
	table.insert(points, { time = 1, value = 1 })
	return points
end

return StationMarkerLogic
