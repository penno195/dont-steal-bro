--!strict
-- Pure half of the race HUD (P6-3): standings, the qualification-line
-- gap, effect timers, the screen-edge treatment per effect category,
-- and the objective arrow's bearing. No Roblox API and no requires, so
-- tests/HudLogic.spec.luau covers it headlessly. Screens/RaceHUD.luau
-- and Controllers/RaceHUDController.luau feed it live numbers.

export type ProgressEntry = { playerId: number, tasksCompleted: number }

export type Standing = {
	place: number, -- 1-based, shared by everyone on the same count
	tied: boolean, -- someone else is on exactly this count
	field: number, -- racers still in the race
	-- Tasks between you and the qualification line. Positive: your lead
	-- over the best non-qualifier. Negative: how far behind the last
	-- qualifying slot you are. 0: on the line. nil when the field is no
	-- bigger than the qualifier count (everyone still in qualifies).
	gap: number?,
	qualifying: boolean,
}

export type Effect = { id: string, category: string, kind: string?, expiresAt: number }

export type EdgeSide = "Top" | "Bottom" | "Left" | "Right"

-- One screen-edge treatment. Categories differ by WHICH edges light up
-- and whether they pulse, not only by colour, so a colour-blind player
-- can still tell "can't move at all" from "slowed" from "blinded".
export type Edge = {
	category: string,
	color: string, -- Tokens.color key
	sides: { EdgeSide },
	pulse: boolean,
	depth: number, -- band depth as a fraction of the screen's short axis
}

local HudLogic = {}

-- STANDINGS ------------------------------------------------------------

-- Placement from task counts alone. The server breaks ties by finish
-- time and distance to the next station (Qualification.luau), which a
-- client can't see for rivals, so a tie is SHOWN as a tie ("=3rd")
-- rather than guessed. Returns nil if `selfId` isn't in the race.
function HudLogic.standing(progress: { ProgressEntry }, selfId: number, qualifierCount: number): Standing?
	local mine: number? = nil
	local counts: { number } = {}
	for _, entry in progress do
		table.insert(counts, entry.tasksCompleted)
		if entry.playerId == selfId then
			mine = entry.tasksCompleted
		end
	end
	if mine == nil then
		return nil
	end
	local own = mine :: number

	table.sort(counts, function(a, b)
		return a > b
	end)

	local ahead, level = 0, 0
	for _, count in counts do
		if count > own then
			ahead += 1
		elseif count == own then
			level += 1
		end
	end

	local place = ahead + 1
	local gap: number? = nil
	if #counts > qualifierCount then
		if place <= qualifierCount then
			gap = own - counts[qualifierCount + 1]
		else
			gap = own - counts[qualifierCount]
		end
	end

	return {
		place = place,
		tied = level > 1,
		field = #counts,
		gap = gap,
		qualifying = place <= qualifierCount,
	}
end

local SUFFIX = { "st", "nd", "rd" }

-- "1st", "=3rd", "12th". Teens always take "th".
function HudLogic.placeLabel(place: number, tied: boolean): string
	local teen = place % 100 >= 11 and place % 100 <= 13
	local suffix = if teen then "th" else (SUFFIX[place % 10] or "th")
	return (if tied then "=" else "") .. tostring(place) .. suffix
end

-- "+2", "-1", "0", or "" with no line to show. Uses a real minus sign
-- (U+2212) so it's as wide as the plus and doesn't read as a dash.
function HudLogic.gapLabel(gap: number?): string
	if gap == nil then
		return ""
	elseif gap > 0 then
		return "+" .. tostring(gap)
	elseif gap < 0 then
		return "\u{2212}" .. tostring(-gap)
	end
	return "0"
end

-- The line gap's own urgency, for colour AND icon: safe, on the line,
-- or out.
export type LineState = "safe" | "edge" | "out" | "none"

function HudLogic.lineState(standing: Standing?): LineState
	if standing == nil or standing.gap == nil then
		return "none"
	elseif not standing.qualifying then
		return "out"
	elseif (standing.gap :: number) <= 0 then
		return "edge"
	end
	return "safe"
end

-- Colour-blind mode's word for each line state (P6-8), shown in place
-- of the icon. Short enough to sit beside the gap in the placement pill.
-- Takes a plain string because a Vide derive widens the LineState
-- literals to string.
local LINE_WORD: { [string]: string } = { safe = "IN", edge = "EDGE", out = "OUT", none = "" }

function HudLogic.lineWord(state: string): string
	return LINE_WORD[state] or ""
end

-- TASKS ----------------------------------------------------------------

-- Takes any rows with a `completed` field (the HUD's task rows carry a
-- title too, which a `{ completed: boolean }` parameter type rejects).
function HudLogic.countDone(assignments: { any }): number
	local done = 0
	for _, assignment in assignments do
		if assignment.completed then
			done += 1
		end
	end
	return done
end

-- TIME -----------------------------------------------------------------

-- Whole seconds left, rounded up so "1" shows until the very end and
-- never goes below 0.
function HudLogic.wholeSecondsLeft(expiresAt: number, now: number): number
	return math.max(0, math.ceil(expiresAt - now - 1e-9))
end

-- Rounds `value` down to a multiple of `step`. Used to quantize the
-- clock and the arrow, so Vide sources only change when something the
-- player could actually see has changed.
function HudLogic.quantize(value: number, step: number): number
	assert(step > 0, "HudLogic.quantize: step must be positive")
	return math.floor(value / step + 1e-9) * step
end

-- EFFECTS --------------------------------------------------------------

-- Effects still running at `now`, soonest-ending first (the one about
-- to wear off is the one worth glancing at). Ties by id so the order is
-- stable between updates and icons don't swap places.
function HudLogic.activeEffects(effects: { Effect }, now: number): { Effect }
	local out = {}
	for _, effect in effects do
		if effect.expiresAt > now then
			table.insert(out, effect)
		end
	end
	table.sort(out, function(a, b)
		if a.expiresAt ~= b.expiresAt then
			return a.expiresAt < b.expiresAt
		end
		return a.id < b.id
	end)
	return out
end

-- Per category. Hard control takes every edge and pulses (you can't
-- move - the loudest thing on screen); movement takes the sides (the
-- direction you're being held back in); vision takes top and bottom,
-- letterboxing a view that's already being darkened. Anything new gets
-- a quiet all-round band until it's given its own row here.
local EDGES: { [string]: Edge } = {
	HardControl = {
		category = "HardControl",
		color = "danger",
		sides = { "Top", "Bottom", "Left", "Right" },
		pulse = true,
		depth = 0.1,
	},
	Movement = { category = "Movement", color = "warning", sides = { "Left", "Right" }, pulse = false, depth = 0.12 },
	Vision = { category = "Vision", color = "brand", sides = { "Top", "Bottom" }, pulse = false, depth = 0.12 },
}
local FALLBACK_EDGE: Edge =
	{ category = "", color = "inkMuted", sides = { "Top", "Bottom", "Left", "Right" }, pulse = false, depth = 0.06 }

for _, edge in EDGES do
	table.freeze(edge.sides)
	table.freeze(edge)
end
HudLogic.EDGES = table.freeze(EDGES)

function HudLogic.edgeFor(category: string): Edge
	local edge = EDGES[category]
	if edge ~= nil then
		return edge
	end
	return table.freeze({
		category = category,
		color = FALLBACK_EDGE.color,
		sides = FALLBACK_EDGE.sides,
		pulse = FALLBACK_EDGE.pulse,
		depth = FALLBACK_EDGE.depth,
	})
end

-- The categories to draw edges for: debuffs only (your own Sprint Boost
-- is not something you're "suffering"), one per category, in a fixed
-- order. An effect with no `kind` counts as a debuff - an unknown
-- effect is safer shown than hidden.
function HudLogic.sufferingCategories(effects: { Effect }, now: number): { string }
	local seen: { [string]: boolean } = {}
	local out = {}
	for _, effect in effects do
		if effect.expiresAt > now and effect.kind ~= "Buff" and not seen[effect.category] then
			seen[effect.category] = true
			table.insert(out, effect.category)
		end
	end
	table.sort(out)
	return out
end

-- OBJECTIVE ------------------------------------------------------------

export type Point = { id: string, x: number, z: number }

-- The nearest point on the ground plane, or nil with none. Height is
-- ignored on purpose: the arrow is a compass, and a station one floor
-- up is still "that way".
function HudLogic.nearest(points: { Point }, x: number, z: number): (Point?, number)
	local best: Point? = nil
	local bestDistance = math.huge
	for _, point in points do
		local distance = math.sqrt((point.x - x) ^ 2 + (point.z - z) ^ 2)
		if distance < bestDistance or distance == bestDistance and best ~= nil and point.id < best.id then
			best = point
			bestDistance = distance
		end
	end
	return best, bestDistance
end

-- Degrees clockwise from straight ahead (screen-up) to the target, from
-- the camera's look direction and the offset to the target, both on the
-- ground plane. The camera's right vector on that plane is (-lookZ,
-- lookX): for Roblox's default look of -Z, that's +X. GuiObject.Rotation
-- is also clockwise, so the result feeds it directly. Range (-180, 180].
function HudLogic.bearing(lookX: number, lookZ: number, toX: number, toZ: number): number
	local forward = toX * lookX + toZ * lookZ
	local right = toX * -lookZ + toZ * lookX
	if forward == 0 and right == 0 then
		return 0
	end
	local degrees = math.deg(math.atan2(right, forward))
	return if degrees <= -180 then 180 else degrees
end

return table.freeze(HudLogic)
