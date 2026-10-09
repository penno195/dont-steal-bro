--!strict
-- Design tokens (P6-1): the raw numbers and hex values every screen is
-- built from. Pure data, no Roblox types - Theme.luau turns these into
-- Color3/UDim/Font for UI code, and tests/Theme.spec.luau checks the
-- colour claims below headlessly. UI code should require Theme, not
-- this file; only tests and Theme itself read Tokens directly.
--
-- UNITS: every size here is in REFERENCE PIXELS - pixels on a phone
-- whose usable short axis is `scale.referenceShortAxis` (360, a small
-- Android phone held in either orientation). UIScaleController
-- multiplies them for the real screen through a UIScale, so a 16 here
-- is 16 on the reference phone, ~21 on a large phone and 32 on a
-- desktop monitor (capped). Screen REGIONS are placed with Scale (see
-- Layout.THUMB_ZONES); the things inside a region are sized from these
-- tokens. See docs/ui-foundation.md "Scale vs Offset" for why this split
-- and not Scale all the way down.

local Tokens = {}

-- Global UIScale. Layout.computeScale explains the maths.
Tokens.scale = table.freeze({
	-- Usable short axis (after safe-area insets) the UI is authored at.
	-- Mobile-first: the smallest screen we ship on is the reference, so
	-- phones sit at ~1.0 and bigger screens only ever scale UP.
	referenceShortAxis = 360,
	-- 0.75 lets a 270-point short axis (an old small phone, landscape,
	-- after the top bar) still fit a layout authored at 360 without
	-- clipping. Below that the UI would overflow no matter what.
	min = 0.75,
	-- 2.0 is reached at a 720-point short axis (tablets, 720p+ desktop).
	-- Beyond it, phone-authored UI turns into billboards; bigger
	-- screens keep the same size and gain breathing room instead.
	max = 2.0,
})

-- Touch. 44 points is Apple's HIG minimum and close to Material's 48dp;
-- Roblox's ViewportSize on mobile is already in points, not device
-- pixels, so this is compared against RENDERED size (token * scale).
Tokens.touch = table.freeze({
	minTargetPoints = 44,
	-- Visual height of a primary button at scale 1. Taller than the
	-- minimum so the hit area never has to grow past the visual at
	-- scale >= 1; below 1, Layout.minTouchRef says how far to pad it.
	primaryHeight = 56,
	iconButton = 44,
})

-- 4-point grid. Named by size, not by use, so "the gap in a card" can
-- be retuned by picking a different step without renaming anything.
Tokens.spacing = table.freeze({
	none = 0,
	xxs = 2,
	xs = 4,
	sm = 8,
	md = 12,
	lg = 16,
	xl = 24,
	xxl = 32,
	xxxl = 48,
})

-- Corner radii in reference pixels. `pill` is not a number: Theme maps
-- it to UDim.new(0.5, 0) so it stays fully round at any height.
Tokens.radius = table.freeze({
	none = 0,
	sm = 4,
	md = 8,
	lg = 16,
})

-- Type scale. Each style's `size` is the MaxTextSize of the
-- UITextSizeConstraint paired with TextScaled (architecture.md §5.6),
-- and `min` its MinTextSize - the floor below which the label would
-- stop being readable on the reference phone. A roughly 1.25 ratio
-- (major third), rounded to whole pixels.
-- `family`: "body" is Builder Sans (Roblox's UI face, four weights);
-- "display" is Luckiest Guy, the game-show headline face from the UI art
-- pass (docs/ui-art-pass/mockup.html, direction A). It has one weight,
-- so `weight` is ignored for it, and Base.text gives it a dark outline
-- (`Tokens.outline`) so it reads over any map. Both ship with the
-- client: no font asset to load on a slow phone.
Tokens.type = table.freeze({
	caption = table.freeze({ size = 12, min = 10, weight = "Medium", family = "body" }),
	body = table.freeze({ size = 16, min = 12, weight = "Regular", family = "body" }),
	label = table.freeze({ size = 18, min = 14, weight = "Bold", family = "body" }),
	-- Button and tab labels: the display face at label size.
	button = table.freeze({ size = 20, min = 14, weight = "Regular", family = "display" }),
	title = table.freeze({ size = 24, min = 18, weight = "Regular", family = "display" }),
	headline = table.freeze({ size = 32, min = 22, weight = "Regular", family = "display" }),
	display = table.freeze({ size = 48, min = 28, weight = "Regular", family = "display" }),
})

-- The outline every display-face label carries (a Contextual UIStroke
-- on the TextLabel), in reference pixels. Dark purple, not black: it
-- sits on the purple surfaces without a hard seam.
Tokens.outline = table.freeze({
	color = "outline",
	thickness = 2,
})

-- Colour. Dark UI on purpose: it sits over a bright 3D map, and a dark
-- surface keeps white text legible whatever the map behind it looks
-- like. Since the UI art pass (direction A, "Game Show") the darks are
-- a deep stage purple, panels are rimmed in gold, and gold is the
-- primary action. Every text/surface pairing below is checked for WCAG
-- AA (4.5:1) in tests/Theme.spec.luau, so retuning a hex here can't
-- quietly break legibility.
Tokens.color = table.freeze({
	background = "#120728",
	surface = "#21114A",
	surfaceRaised = "#321C66",
	line = "#5A3FA0",
	-- The gold rim on panels, modals and pills.
	rim = "#FFD23F",
	outline = "#1B0B33",
	ink = "#FFFFFF",
	inkMuted = "#C9BDF0",
	inkOnLight = "#1B0B33",
	-- Accent: "this one is you", highlights, the tab indicator. Hot pink
	-- so it never reads as the gold primary action.
	brand = "#FF4FA3",
	-- Button fills (P6-2). Each is the BOTTOM stop of its gradient
	-- (`Tokens.fill`), the flat colour used where there's no gradient.
	-- Gold and danger-red both take dark ink: white on either fails AA.
	primary = "#FFB703",
	onPrimary = "#2A1100",
	onDanger = "#1B0B33",
	danger = "#F03E3E",
	warning = "#FF9F1C",
	success = "#3CCB7F",
	focus = "#FFFFFF",
	-- The objective compass: a station a floor up or down. Blue against
	-- orange is the pair every colour-vision type keeps apart, and the
	-- chevron's direction says it too.
	above = "#5AC8FA",
	below = "#FF8A3D",
	scrim = "#000000",

	-- THE DECISION PAIR. Red for Steal, green for Share (the owner's
	-- call, 2026-09-26; it was amber/blue). A red/green pair of similar
	-- vividness drops to ~0.05 OKLab apart under deuteranopia, so this
	-- one is split by LIGHTNESS instead: a deep red against a light
	-- green. Run through ColorVision's Machado-2009 simulations it keeps
	-- >= 0.24 under protanopia, deuteranopia, tritanopia AND full
	-- achromatopsia, and a 3.2:1 luminance ratio, so it survives a
	-- greyscale screenshot. tests/Theme.spec.luau keeps a vivid
	-- red/green control to prove the check would catch the naive pair.
	--
	-- Colour is still never the only cue: `Tokens.decision` below pairs
	-- each with its own icon and word, and the Studio puts Steal on the
	-- left and Share on the right.
	steal = "#C62828",
	onSteal = "#FFFFFF",
	share = "#4ADE80",
	onShare = "#12151C", -- dark ink: the light green is too light for white text
})

-- Gradient fills (UI art pass). Roblox has no box-shadow, so a raised
-- surface is three layers: a `lip` Frame offset `Tokens.lip` px below,
-- the surface on top with a vertical UIGradient from `top` to `bottom`,
-- and a `rim` UIStroke. A press drops the surface onto its lip. `ink`
-- is a Tokens.color key; the spec checks it against BOTH stops.
Tokens.fill = table.freeze({
	primary = table.freeze({ top = "#FFE066", bottom = "#FFB703", lip = "#B86B00", rim = "#FFF3B0", ink = "onPrimary" }),
	secondary = table.freeze({ top = "#6C47F5", bottom = "#4F2BD6", lip = "#2E1490", rim = "#B9A6FF", ink = "ink" }),
	danger = table.freeze({ top = "#FF6B6B", bottom = "#F03E3E", lip = "#8A1111", rim = "#FFB3B3", ink = "onDanger" }),
	-- Flat (top == bottom): every disabled control, and the ghost
	-- variant's fill once touched.
	muted = table.freeze({ top = "#21114A", bottom = "#21114A", lip = "#0B0420", rim = "#5A3FA0", ink = "inkMuted" }),
	ghost = table.freeze({ top = "#321C66", bottom = "#321C66", lip = "#321C66", rim = "#5A3FA0", ink = "ink" }),
	panel = table.freeze({ top = "#2B1858", bottom = "#170B33", lip = "#0B0420", rim = "#FFD23F", ink = "ink" }),
	steal = table.freeze({ top = "#D63A3A", bottom = "#C62828", lip = "#5E0D0D", rim = "#FFB3B3", ink = "onSteal" }),
	share = table.freeze({ top = "#8AF0AD", bottom = "#4ADE80", lip = "#146B36", rim = "#E2FFE9", ink = "onShare" }),
	-- The season pass screen's two rows (the owner's reference): gold for
	-- the paid row, blue for the free row.
	seasonPaid = table.freeze({
		top = "#FFC94A",
		bottom = "#F08A1C",
		lip = "#7A3A00",
		rim = "#FFE58A",
		ink = "onPrimary",
	}),
	seasonFree = table.freeze({ top = "#2A6AE0", bottom = "#173C9E", lip = "#0A1E5C", rim = "#8CC8FF", ink = "ink" }),
})

-- Lip depth in reference pixels: how far a button sinks when pressed.
Tokens.lip = table.freeze({
	button = 5,
	panel = 5,
	small = 3,
})

-- Minimum colour distances the spec enforces. Kept here so a designer
-- retuning a hex sees the bar it has to clear.
Tokens.contrast = table.freeze({
	textMin = 4.5, -- WCAG AA, body text
	nonTextMin = 3.0, -- WCAG 1.4.11, UI shapes against the background
	decisionPairMinDistance = 0.2, -- OKLab, under every simulation
	decisionPairMinLuminanceRatio = 3.0, -- greyscale-legible on its own
})

-- Non-colour cues for the decision pair, so a player who can't tell the
-- colours apart - or is looking at a dim screen in sunlight - still
-- can't mix them up. The silhouette differs (angular diamond vs round
-- pill), the icon differs, and the label is always shown.
--   `shape`: "Diamond" = square rotated 45 degrees with sharp corners;
--            "Pill"    = fully rounded (Tokens.radius pill).
--   `icon`:  a key into the icon atlas, which doesn't exist yet (P6-2
--            owns art); P6-1's harness draws the shapes as stand-ins.
Tokens.decision = table.freeze({
	-- One shape for both since 2026-09-26 (the owner's call): the pair
	-- reads as two equal options, and icon, word and side carry the rest.
	steal = table.freeze({ color = "steal", on = "onSteal", shape = "Pill", icon = "grab-hand", label = "STEAL" }),
	share = table.freeze({ color = "share", on = "onShare", shape = "Pill", icon = "open-hands", label = "SHARE" }),
})

-- Elevation. Roblox has no box-shadow, so "higher" means three things
-- that do exist: a lighter surface, a stroke, and a ScreenGui
-- DisplayOrder band (Theme.displayOrder) so a toast is always over a
-- modal, which is always over the HUD. Levels, low to high.
Tokens.elevation = table.freeze({
	table.freeze({ surface = "background", strokeTransparency = 1 }), -- 1: flat, page
	-- 2 and 3 draw the gold rim fully opaque (UI art pass); Panel makes
	-- 3's rim thicker rather than more opaque.
	table.freeze({ surface = "surface", strokeTransparency = 0 }), -- 2: card, HUD panel
	table.freeze({ surface = "surfaceRaised", strokeTransparency = 0 }), -- 3: modal, popover
})

-- ScreenGui DisplayOrder bands. Gaps of 10 leave room to slot a layer
-- in between without renumbering.
Tokens.displayOrder = table.freeze({
	hud = 10,
	panel = 20,
	modal = 30,
	toast = 40,
	debug = 100,
})

-- Task views (P6-4, docs/task-views.md). Reference pixels unless noted.
Tokens.taskView = table.freeze({
	-- No interactive element closer than this to the usable rect's edge:
	-- a thumb resting on a phone's bezel curve registers there, and a
	-- drag that reaches it is about to leave the screen.
	edgeMargin = 24,
	-- A usable rect whose short axis is under this, or any touch device,
	-- gets the full-screen sheet; bigger screens get a window.
	windowMinShortAxis = 600,
	windowSize = table.freeze({ width = 520, height = 560 }),
	-- Pointer travel below this is a tap, not a drag (finger jitter).
	dragSlop = 8,
	-- A held pointer with no event for this long is treated as lost:
	-- a finger that slid off the glass sometimes never sends InputEnded.
	dragStaleSeconds = 1.5,
	-- Stick deflection under this is noise from a worn thumbstick.
	stickDeadzone = 0.2,
	-- The base aborts when the character is this far from the station.
	-- The server's own check is 12 studs; the extra 2 keeps a player
	-- shuffling on the boundary from being thrown out mid-attempt.
	leaveRangeStuds = 14,
})

-- Motion, in seconds. P6-2's components collapse these to 0 when
-- reduced motion is on.
Tokens.motion = table.freeze({
	fast = 0.12,
	base = 0.2,
	slow = 0.35,
})

return table.freeze(Tokens)
