--!strict
-- Pure layout maths (P6-1): the global UI scale, the usable rect, touch
-- target padding, and the thumb-zone guide. No Roblox API - rects are
-- plain tables - so tests/Theme.spec.luau covers every clamp and
-- boundary headlessly. UIScaleController feeds it live numbers from
-- the camera and GuiService.

export type Rect = { x: number, y: number, width: number, height: number }
export type Orientation = "Landscape" | "Portrait"
export type ScaleConfig = { referenceShortAxis: number, min: number, max: number }

export type ZoneKind =
	"Primary" -- main action (use power-up, confirm): comfortable, clear of Roblox controls
	| "Secondary" -- reachable with a stretch: less frequent actions
	| "Info" -- read-only HUD: countdown, placement, task list
	| "ReservedMove" -- Roblox's thumbstick lives here on touch
	| "ReservedJump" -- Roblox's jump button lives here on touch

export type Zone = { kind: ZoneKind, rect: Rect }

local Layout = {}

-- THE SCALE MATHS.
--
--   scale = clamp(shortAxis / referenceShortAxis, min, max)
--
-- where shortAxis is the SHORTER side of the usable (safe-area) rect.
--
-- Why the short axis: it's the one that runs out first, in either
-- orientation. A landscape phone is ~390 tall and ~800 wide; scaling by
-- width would size the UI for 800 and overflow vertically. Using the
-- short side also means rotating the phone doesn't change the scale,
-- so UI doesn't jump in size when the device turns.
--
-- Why the USABLE rect, not the raw viewport: on a notched phone the
-- notch and top bar take 40-60 points off one axis. Scaling to the raw
-- viewport would size the UI for space that doesn't exist.
--
-- Why a clamp: below `min`, text drops under legibility and touch
-- targets under 44 points no matter how the layout is padded - better
-- to let a layout crop at the edges on a truly tiny screen. Above
-- `max`, phone-authored UI becomes absurdly large on a monitor. See
-- Tokens.scale for the chosen numbers and where each one kicks in.
function Layout.computeScale(width: number, height: number, config: ScaleConfig): number
	local shortAxis = math.min(width, height)
	if shortAxis <= 0 then
		-- Viewport not measured yet (the camera reports 1x1 or 0x0 for a
		-- frame on some clients). Use the reference, not the min: the
		-- real value lands a frame later and a jump from 1.0 is smaller.
		return math.clamp(1, config.min, config.max)
	end
	return math.clamp(shortAxis / config.referenceShortAxis, config.min, config.max)
end

-- The usable rect: the viewport minus insets on each side. Pure form
-- of what UIScaleController reads from GuiService:GetInsetArea.
function Layout.insetRect(
	viewportWidth: number,
	viewportHeight: number,
	left: number,
	top: number,
	right: number,
	bottom: number
): Rect
	return {
		x = left,
		y = top,
		width = math.max(0, viewportWidth - left - right),
		height = math.max(0, viewportHeight - top - bottom),
	}
end

function Layout.orientationOf(width: number, height: number): Orientation
	-- A square screen counts as landscape: that's Roblox's default
	-- orientation and the controls lay out for it.
	return if height > width then "Portrait" else "Landscape"
end

-- How big to author a hit area, in reference pixels, so that after the
-- UIScale it still renders at >= minPoints. At scale 1 that's 44; at
-- the 0.75 floor it's 59. Components pad the hit area (not the visual)
-- up to this - the visual can stay small.
function Layout.minTouchRef(scale: number, minPoints: number): number
	assert(scale > 0, "Layout.minTouchRef: scale must be positive")
	return math.ceil(minPoints / scale)
end

-- THUMB ZONES, as fractions of the usable rect (x, y, width, height;
-- origin top-left). Written for a right-handed grip, the majority case;
-- a left-handed mirror is a settings option later, not a second table.
--
-- LANDSCAPE (Roblox's default on phones, both thumbs on the screen):
--   - Roblox owns the bottom-left (thumbstick, or the dynamic stick's
--     whole left half) and the bottom-right corner (jump button).
--   - The right thumb rests just LEFT OF and ABOVE the jump button -
--     that arc is the only spot a primary action can live without
--     either blocking jump or needing a grip change. architecture.md
--     §5.4: "primary actions bottom-right, clear of the jump button".
--   - Top-centre is for reading, not touching: it's in view while you
--     look at the road, and nothing there needs a tap mid-race.
--
-- PORTRAIT (CLAUDE.md Ground Rule 3: one thumb, phone upright):
--   - One thumb pivots from the bottom-right corner, so the easy arc is
--     the lower-middle of the screen; the top third is a reach.
--   - Roblox still puts its controls along the bottom edge.
--
-- These are APPROXIMATIONS of Roblox's control placement, which changes
-- with screen size and client version. The harness draws the real
-- TouchGui buttons over these zones on device so any drift is visible
-- in the screenshot rather than assumed away.
local ZONES: { [Orientation]: { Zone } } = {
	Landscape = {
		{ kind = "ReservedMove", rect = { x = 0, y = 0.4, width = 0.42, height = 0.6 } },
		{ kind = "ReservedJump", rect = { x = 0.8, y = 0.58, width = 0.2, height = 0.42 } },
		{ kind = "Primary", rect = { x = 0.62, y = 0.58, width = 0.18, height = 0.42 } },
		{ kind = "Primary", rect = { x = 0.8, y = 0.32, width = 0.2, height = 0.26 } },
		{ kind = "Secondary", rect = { x = 0.42, y = 0.7, width = 0.2, height = 0.3 } },
		{ kind = "Info", rect = { x = 0.2, y = 0, width = 0.6, height = 0.2 } },
	},
	Portrait = {
		{ kind = "ReservedMove", rect = { x = 0, y = 0.72, width = 0.5, height = 0.28 } },
		{ kind = "ReservedJump", rect = { x = 0.7, y = 0.8, width = 0.3, height = 0.2 } },
		{ kind = "Primary", rect = { x = 0.5, y = 0.56, width = 0.5, height = 0.24 } },
		{ kind = "Secondary", rect = { x = 0.1, y = 0.42, width = 0.8, height = 0.14 } },
		{ kind = "Info", rect = { x = 0, y = 0, width = 1, height = 0.16 } },
	},
}

-- Deep-frozen so a caller can't nudge the shared guide at runtime.
for _, zones in ZONES do
	for _, zone in zones do
		table.freeze(zone.rect)
		table.freeze(zone)
	end
	table.freeze(zones)
end
Layout.THUMB_ZONES = table.freeze(ZONES)

-- The zones for this orientation, resolved into absolute pixels within
-- `usable` (so a HUD can position straight from them).
function Layout.resolveZones(usable: Rect): { Zone }
	local out = {}
	for _, zone in ZONES[Layout.orientationOf(usable.width, usable.height)] do
		local r = zone.rect
		table.insert(out, {
			kind = zone.kind,
			rect = {
				x = usable.x + r.x * usable.width,
				y = usable.y + r.y * usable.height,
				width = r.width * usable.width,
				height = r.height * usable.height,
			},
		})
	end
	return out
end

-- Rects that merely share an edge don't overlap. The epsilon absorbs
-- float error in the fractions: 0.62 + 0.18 is a hair over 0.8, which
-- would otherwise make two touching zones "overlap".
local EDGE_EPSILON = 1e-6

local function overlaps(a: Rect, b: Rect): boolean
	return a.x < b.x + b.width - EDGE_EPSILON
		and b.x < a.x + a.width - EDGE_EPSILON
		and a.y < b.y + b.height - EDGE_EPSILON
		and b.y < a.y + a.height - EDGE_EPSILON
end

-- True if `rect` (absolute, same space as `usable`) would sit on top of
-- one of Roblox's own touch controls. A debug assertion for screens: a
-- button that fails this can't be pressed without also jumping.
function Layout.hitsReserved(rect: Rect, usable: Rect): boolean
	for _, zone in Layout.resolveZones(usable) do
		if (zone.kind == "ReservedMove" or zone.kind == "ReservedJump") and overlaps(rect, zone.rect) then
			return true
		end
	end
	return false
end

return Layout
