--!strict
-- The pure half of the component library (P6-2): which state wins,
-- which colour tokens a state paints with, how big a hit area must be,
-- how a countdown ring's two halves rotate. No Roblox API and no
-- requires, so tests/ComponentLogic.spec.luau runs it headlessly under
-- Lune. Everything returns TOKEN NAMES (keys of Tokens.color), never
-- Color3 - Theme.luau is the only place a hex becomes a colour.

local ComponentLogic = {}

-- INTERACTION STATE ----------------------------------------------------

export type State = "idle" | "hovered" | "pressed" | "disabled" | "loading"

export type StateInputs = {
	disabled: boolean,
	loading: boolean,
	pressed: boolean,
	hovered: boolean,
}

-- One winner, in this order. Disabled beats loading: a control that
-- can't be used shouldn't spin as though it's working. Loading beats
-- pressed so a second tap during a request shows nothing new. Focus is
-- NOT a state here - it's an overlay ring drawn on top of whichever
-- state wins, so a focused button can still show pressed.
function ComponentLogic.resolveState(inputs: StateInputs): State
	if inputs.disabled then
		return "disabled"
	elseif inputs.loading then
		return "loading"
	elseif inputs.pressed then
		return "pressed"
	elseif inputs.hovered then
		return "hovered"
	end
	return "idle"
end

-- Whether a tap in this state should fire the action.
function ComponentLogic.acceptsInput(state: State): boolean
	return state ~= "disabled" and state ~= "loading"
end

-- VARIANT STYLES -------------------------------------------------------

export type Variant = "primary" | "secondary" | "danger" | "ghost"

export type Style = {
	fill: string, -- Tokens.color key
	fillTransparency: number,
	ink: string, -- Tokens.color key for the label/icon
	stroke: string, -- Tokens.color key
	strokeTransparency: number,
	-- Added on top of the fill as a white overlay; Roblox has no
	-- "lighten" so hover/press brighten through this instead.
	overlayTransparency: number,
}

type Base = { fill: string, ink: string, stroke: string, fillTransparency: number, strokeTransparency: number }

-- Every fill/ink pair here is checked for WCAG AA in the spec, so a
-- retuned hex that breaks legibility fails CI.
local BASE: { [Variant]: Base } = {
	primary = { fill = "primary", ink = "onPrimary", stroke = "primary", fillTransparency = 0, strokeTransparency = 1 },
	secondary = { fill = "surfaceRaised", ink = "ink", stroke = "line", fillTransparency = 0, strokeTransparency = 0 },
	danger = { fill = "danger", ink = "onDanger", stroke = "danger", fillTransparency = 0, strokeTransparency = 1 },
	-- Icon-only chrome over a panel: no fill until touched.
	ghost = { fill = "surfaceRaised", ink = "ink", stroke = "line", fillTransparency = 1, strokeTransparency = 1 },
}

-- Disabled drops the variant entirely: the same muted look whatever it
-- was, so "can I press this?" reads identically across the whole game.
-- (WCAG exempts disabled controls from contrast; inkMuted on surface is
-- 7.57:1 anyway.)
local DISABLED: Style = table.freeze({
	fill = "surface",
	fillTransparency = 0,
	ink = "inkMuted",
	stroke = "line",
	strokeTransparency = 0.3,
	overlayTransparency = 1,
})

local OVERLAY: { [State]: number } = {
	idle = 1,
	hovered = 0.88,
	pressed = 0.78,
	loading = 1,
	disabled = 1,
}

function ComponentLogic.variantStyle(variant: Variant, state: State): Style
	if state == "disabled" then
		return DISABLED
	end
	local base = BASE[variant]
	assert(base ~= nil, string.format("ComponentLogic.variantStyle: unknown variant %q", tostring(variant)))
	local fillTransparency = base.fillTransparency
	-- A ghost button gains a fill when touched, or the press is invisible.
	if variant == "ghost" and (state == "hovered" or state == "pressed") then
		fillTransparency = 0
	end
	return {
		fill = base.fill,
		fillTransparency = fillTransparency,
		ink = base.ink,
		stroke = base.stroke,
		strokeTransparency = base.strokeTransparency,
		overlayTransparency = OVERLAY[state],
	}
end

-- Multiplier on the visual (not the hit area): pressed shrinks it a
-- touch, so a thumb that covers the label still feels the press land.
-- Shared by every interactive component, whatever its variant.
function ComponentLogic.pressScale(state: State): number
	return if state == "pressed" then 0.96 else 1
end

-- Every (fill, ink) pair a variant can paint, for the contrast spec.
function ComponentLogic.inkPairs(): { { fill: string, ink: string } }
	local out = {}
	for _, base in BASE do
		table.insert(out, { fill = base.fill, ink = base.ink })
	end
	table.insert(out, { fill = DISABLED.fill, ink = DISABLED.ink })
	return out
end

-- TOUCH TARGETS --------------------------------------------------------

-- The hit area for a visual of `visual` reference pixels, given the
-- minimum from Layout.minTouchRef(scale, 44). The hit area grows; the
-- visual never does. Returns the size and the inset that centres the
-- visual inside it.
function ComponentLogic.hitArea(visual: number, minRef: number): (number, number)
	local size = math.max(visual, minRef)
	return size, (size - visual) / 2
end

-- MOTION ---------------------------------------------------------------

-- Seconds for a named motion token, or 0 when reduced motion is on.
-- Zero rather than "shorter": vestibular triggers are the movement
-- itself, and a fast slide is still a slide.
function ComponentLogic.duration(seconds: number, reduced: boolean): number
	return if reduced then 0 else seconds
end

-- PROGRESS AND COUNTDOWN ----------------------------------------------

function ComponentLogic.fraction(value: number, max: number): number
	if max <= 0 or value ~= value then
		return 0
	end
	return math.clamp(value / max, 0, 1)
end

-- A ring arc is drawn as two half-rings, each clipped to its half of
-- the circle and masked by a hard-edged UIGradient. For an arc that
-- sweeps clockwise from 12 o'clock through `fraction` of the circle,
-- the gradient's Rotation on each half equals the arc's end angle,
-- clamped to that half's range:
--   right half (0-180 deg):   rotation = min(angle, 180)
--   left half  (180-360 deg): rotation = max(angle, 180)
-- (With the gradient opaque on its first half, rotation `a` leaves the
-- half-plane centred on `a - 90` opaque, which is exactly the arc
-- [a - 180, a]; the clamp keeps each half from showing the other's
-- sweep.) Returns (rightRotation, leftRotation).
function ComponentLogic.ringRotations(fraction: number): (number, number)
	local angle = 360 * math.clamp(fraction, 0, 1)
	return math.min(angle, 180), math.max(angle, 180)
end

export type Urgency = "calm" | "warning" | "critical"

-- Colour steps for a countdown. Seconds, not a fraction: "5 seconds
-- left" means the same thing in a 30s task and a 90s round.
function ComponentLogic.urgency(secondsLeft: number, warnAt: number, criticalAt: number): Urgency
	if secondsLeft <= criticalAt then
		return "critical"
	elseif secondsLeft <= warnAt then
		return "warning"
	end
	return "calm"
end

-- What the ring's centre says: whole seconds rounded UP, so "0" only
-- appears when time is actually out, never with 0.4s still to play.
function ComponentLogic.countdownLabel(secondsLeft: number): string
	return tostring(math.max(0, math.ceil(secondsLeft - 1e-9)))
end

-- CURRENCY -------------------------------------------------------------

-- A pill is narrow; past 4 digits it abbreviates. Truncates rather than
-- rounds so a player on 9,999 never sees "10K" and thinks they can
-- afford a 10,000 item.
function ComponentLogic.formatAmount(amount: number): string
	local n = math.floor(math.abs(amount))
	local sign = if amount < 0 then "-" else ""
	if n < 10000 then
		local s = tostring(n)
		if n >= 1000 then
			s = string.sub(s, 1, -4) .. "," .. string.sub(s, -3)
		end
		return sign .. s
	end
	local units: { { divisor: number, suffix: string } } =
		{ { divisor = 1e9, suffix = "B" }, { divisor = 1e6, suffix = "M" }, { divisor = 1e3, suffix = "K" } }
	for _, unit in units do
		local divisor, suffix = unit.divisor, unit.suffix
		if n >= divisor then
			local tenths = math.floor(n / divisor * 10) / 10
			local text = if tenths >= 100 or tenths == math.floor(tenths)
				then tostring(math.floor(tenths))
				else string.format("%.1f", tenths)
			return sign .. text .. suffix
		end
	end
	return sign .. tostring(n)
end

-- TABS -----------------------------------------------------------------

-- Next tab for a shoulder-button / arrow press, wrapping at the ends.
function ComponentLogic.stepTab(current: number, count: number, direction: number): number
	if count <= 0 then
		return 0
	end
	return ((current - 1 + direction) % count) + 1
end

-- TOASTS ---------------------------------------------------------------

-- On screen long enough to read: a 2s floor plus ~60ms a character
-- (roughly 200 wpm), capped so a long message doesn't sit over the race.
function ComponentLogic.toastSeconds(text: string): number
	return math.clamp(2 + #text * 0.06, 2, 6)
end

-- Stacking: at most `max` toasts. A new one pushes out the oldest -
-- during a race the latest event is the one that matters.
function ComponentLogic.pushToast<T>(queue: { T }, item: T, max: number): ({ T }, T?)
	local out = table.clone(queue)
	table.insert(out, item)
	local dropped: T? = nil
	if #out > max then
		dropped = table.remove(out, 1)
	end
	return out, dropped
end

return table.freeze(ComponentLogic)
