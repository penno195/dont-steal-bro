--!strict
-- Pure half of the task view framework (P6-4): presentation choice,
-- edge-margin enforcement, the drag pointer state machine, hold and
-- timing phases, sequence-grid stepping, aim vectors, the input-lock
-- counter and state feedback styles. No Roblox API and no requires, so
-- tests/TaskViewLogic.spec.luau covers it headlessly. TaskViewBase.luau
-- and InputAdapters.luau feed it live numbers. See docs/task-views.md.

export type Rect = { x: number, y: number, width: number, height: number }
export type Point = { x: number, y: number }

local TaskViewLogic = {}

-- PRESENTATION ---------------------------------------------------------

export type Presentation = "Sheet" | "Window"

-- A full-screen sheet on anything touch or anything small; a window on
-- a big mouse/gamepad screen, so the map stays visible around it. Touch
-- always gets the sheet even on a tablet: a window leaves live world
-- around it that a stray thumb would drag the camera through.
function TaskViewLogic.presentation(usable: Rect, isTouch: boolean, windowMinShortAxis: number): Presentation
	if isTouch or math.min(usable.width, usable.height) < windowMinShortAxis then
		return "Sheet"
	end
	return "Window"
end

-- EDGE MARGIN ----------------------------------------------------------

-- True if `rect` comes within `margin` of any edge of `usable` (both in
-- the same absolute space). The base walks every interactive element
-- through this in Studio and warns.
function TaskViewLogic.violatesEdge(rect: Rect, usable: Rect, margin: number): boolean
	return rect.x < usable.x + margin
		or rect.y < usable.y + margin
		or rect.x + rect.width > usable.x + usable.width - margin
		or rect.y + rect.height > usable.y + usable.height - margin
end

-- `usable` shrunk by `margin` on every side: the play area a task view
-- lays its interactive content out in. Never negative.
function TaskViewLogic.playArea(usable: Rect, margin: number): Rect
	local m = math.min(margin, usable.width / 2, usable.height / 2)
	return { x = usable.x + m, y = usable.y + m, width = usable.width - 2 * m, height = usable.height - 2 * m }
end

-- `p` pulled inside `area`. A dragged ghost follows the finger but
-- never renders past the play area.
function TaskViewLogic.clampPoint(p: Point, area: Rect): Point
	return {
		x = math.clamp(p.x, area.x, area.x + area.width),
		y = math.clamp(p.y, area.y, area.y + area.height),
	}
end

-- HIT-AREA INFLATION ---------------------------------------------------

-- A hit rect grown around `visual`: at least `minEdge` on each axis and
-- at least `extra` beyond the visual on every side, still centred on it.
-- Drop targets use a generous `extra`; a drop that lands a finger's
-- width outside the slot was aimed at the slot.
function TaskViewLogic.inflate(visual: Rect, minEdge: number, extra: number): Rect
	local w = math.max(visual.width + 2 * extra, minEdge)
	local h = math.max(visual.height + 2 * extra, minEdge)
	return {
		x = visual.x - (w - visual.width) / 2,
		y = visual.y - (h - visual.height) / 2,
		width = w,
		height = h,
	}
end

function TaskViewLogic.contains(rect: Rect, p: Point): boolean
	return p.x >= rect.x and p.x <= rect.x + rect.width and p.y >= rect.y and p.y <= rect.y + rect.height
end

-- The target whose (inflated) rect contains `p`; where inflated rects
-- overlap, the one whose centre is nearest wins, so inflation never
-- makes a neighbour steal a drop that was dead-centre on its own slot.
function TaskViewLogic.pickTarget(targets: { [string]: Rect }, p: Point): string?
	local best: string? = nil
	local bestDist = math.huge
	for id, rect in targets do
		if TaskViewLogic.contains(rect, p) then
			local dx = rect.x + rect.width / 2 - p.x
			local dy = rect.y + rect.height / 2 - p.y
			local d = dx * dx + dy * dy
			-- Ties broken by id so the answer never depends on table order.
			if d < bestDist or (d == bestDist and best ~= nil and id < best) then
				best, bestDist = id, d
			end
		end
	end
	return best
end

-- DRAG -----------------------------------------------------------------
--
-- One pointer owns a drag at a time. A second finger landing mid-drag
-- (a palm, the other thumb resting) is ignored rather than stealing or
-- cancelling the drag. The drag ends one of three ways:
--   Drop    - the owning pointer lifted inside the play area
--   Cancel  - it lifted (or was last seen) inside the edge margin, i.e.
--             the finger ran off the glass; Roblox then reports the
--             lift at a clamped edge position, which is not a real aim
--   Cancel  - the owning pointer went quiet for `staleSeconds`
--             (InputEnded lost), or the caller cancelled (view closing)
-- A lift before the pointer travelled `slop` is a Tap, not a drop.

export type DragConfig = { slop: number, staleSeconds: number }

export type Drag = {
	pointer: any?, -- whatever identifies a pointer (an InputObject in game)
	origin: Point,
	at: Point,
	moved: boolean,
	lastSeen: number,
	nearEdge: boolean,
}

export type DragOutcome =
	{ kind: "Ignored" }
	| { kind: "Started" }
	| { kind: "Moved", at: Point }
	| { kind: "Tap", at: Point }
	| { kind: "Drop", at: Point }
	| { kind: "Cancel" }

function TaskViewLogic.newDrag(): Drag
	return {
		pointer = nil,
		origin = { x = 0, y = 0 },
		at = { x = 0, y = 0 },
		moved = false,
		lastSeen = 0,
		nearEdge = false,
	}
end

local IGNORED: DragOutcome = { kind = "Ignored" }
local CANCEL: DragOutcome = { kind = "Cancel" }

local function reset(d: Drag)
	d.pointer = nil
	d.moved = false
	d.nearEdge = false
end

function TaskViewLogic.dragBegin(d: Drag, pointer: any, p: Point, now: number, area: Rect): DragOutcome
	if d.pointer ~= nil or not TaskViewLogic.contains(area, p) then
		return IGNORED
	end
	d.pointer = pointer
	d.origin = p
	d.at = p
	d.moved = false
	d.lastSeen = now
	d.nearEdge = false
	return { kind = "Started" }
end

function TaskViewLogic.dragMove(
	d: Drag,
	pointer: any,
	p: Point,
	now: number,
	area: Rect,
	config: DragConfig
): DragOutcome
	if d.pointer == nil or pointer ~= d.pointer then
		return IGNORED
	end
	d.lastSeen = now
	d.nearEdge = not TaskViewLogic.contains(area, p)
	if not d.moved then
		local dx, dy = p.x - d.origin.x, p.y - d.origin.y
		d.moved = dx * dx + dy * dy >= config.slop * config.slop
	end
	d.at = TaskViewLogic.clampPoint(p, area)
	return { kind = "Moved", at = d.at }
end

function TaskViewLogic.dragEnd(d: Drag, pointer: any, p: Point, area: Rect): DragOutcome
	if d.pointer == nil or pointer ~= d.pointer then
		return IGNORED
	end
	local moved, wasNearEdge = d.moved, d.nearEdge
	reset(d)
	if not moved then
		return { kind = "Tap", at = p }
	end
	if wasNearEdge or not TaskViewLogic.contains(area, p) then
		return CANCEL
	end
	return { kind = "Drop", at = p }
end

-- Called every frame by the adapter; cancels a drag whose pointer went
-- quiet. Returns Ignored while the drag is healthy.
function TaskViewLogic.dragTick(d: Drag, now: number, config: DragConfig): DragOutcome
	if d.pointer ~= nil and now - d.lastSeen > config.staleSeconds then
		reset(d)
		return CANCEL
	end
	return IGNORED
end

-- Unconditional cancel: view closing, touch cancelled by the OS.
function TaskViewLogic.dragCancel(d: Drag): DragOutcome
	if d.pointer == nil then
		return IGNORED
	end
	reset(d)
	return CANCEL
end

-- HOLD AND TIMING ------------------------------------------------------

-- 0..1 fill of a hold that has lasted `held` of `required` seconds.
-- Display only: the server times the hold from its own clock.
function TaskViewLogic.holdFraction(held: number, required: number): number
	if required <= 0 then
		return 1
	end
	return math.clamp(held / required, 0, 1)
end

-- Where a Timing task's sweeping cursor is, 0..1, `elapsed` seconds in:
-- a ping-pong so the cursor never teleports from one end to the other
-- (a jump reads as a skipped frame on a slow phone).
function TaskViewLogic.sweep(elapsed: number, period: number): number
	if period <= 0 then
		return 0
	end
	local t = (elapsed % period) / period
	return if t < 0.5 then t * 2 else 2 - t * 2
end

-- SEQUENCE GRID NAVIGATION ---------------------------------------------

-- Moves a gamepad/keyboard cursor over a `count`-cell grid of `columns`
-- (row-major, 1-based). Stops at the edges rather than wrapping: a
-- wrapped jump from the last key to the first is how a player on a
-- gamepad enters the wrong digit without noticing.
function TaskViewLogic.stepGrid(index: number, columns: number, count: number, dx: number, dy: number): number
	if count <= 0 then
		return 0
	end
	local col = (index - 1) % columns
	local row = (index - 1) // columns
	local rows = math.ceil(count / columns)
	col = math.clamp(col + dx, 0, columns - 1)
	row = math.clamp(row + dy, 0, rows - 1)
	local nextIndex = row * columns + col + 1
	-- A short last row: moving down into a gap stays put.
	if nextIndex > count then
		return index
	end
	return nextIndex
end

-- AIM ------------------------------------------------------------------

-- A unit aim direction and its strength 0..1 from a pointer at `p`
-- relative to an origin `o`, with `radius` as full deflection, or from a
-- thumbstick (pass o = 0,0 and radius = 1). Inside `deadzone` (a
-- fraction of radius) it returns nil: no aim, rather than a jittery one.
function TaskViewLogic.aim(o: Point, p: Point, radius: number, deadzone: number): (Point?, number)
	local dx, dy = p.x - o.x, p.y - o.y
	local len = math.sqrt(dx * dx + dy * dy)
	if radius <= 0 or len <= deadzone * radius then
		return nil, 0
	end
	local strength = math.clamp((len - deadzone * radius) / (radius - deadzone * radius), 0, 1)
	return { x = dx / len, y = dy / len }, strength
end

-- INPUT LOCK -----------------------------------------------------------
--
-- Several owners can want the controls frozen at once (an open task
-- view, later a cutscene). Each takes a token; the camera and controls
-- come back only when the LAST token is released, and they come back
-- to what they were before the FIRST one. Releasing a token twice, or
-- one never taken, is a no-op - close paths overlap (abort, success,
-- death, round end) and every one of them releases.

export type LockSet = { tokens: { [any]: true }, count: number }

function TaskViewLogic.newLockSet(): LockSet
	return { tokens = {}, count = 0 }
end

-- True when this acquire is the first (the caller should save state
-- and freeze).
function TaskViewLogic.acquire(set: LockSet, token: any): boolean
	if set.tokens[token] then
		return false
	end
	set.tokens[token] = true
	set.count += 1
	return set.count == 1
end

-- True when this release was the last (the caller should restore).
function TaskViewLogic.release(set: LockSet, token: any): boolean
	if not set.tokens[token] then
		return false
	end
	set.tokens[token] = nil
	set.count -= 1
	return set.count == 0
end

-- FEEDBACK -------------------------------------------------------------
--
-- Every state a task element can signal, with its colour token, icon
-- key and outline weight. Colour is never the only cue: each state has
-- its own icon and "Bad" the heaviest outline, so the states survive
-- deuteranopia and a greyscale screen.
-- No state is signalled by sound alone either - sounds are optional
-- garnish played alongside a visual cue from this table.

export type Feedback = "Neutral" | "Active" | "Good" | "Bad"
export type FeedbackStyle = { color: string, icon: string?, strokeThickness: number }

local FEEDBACK: { [Feedback]: FeedbackStyle } = {
	Neutral = table.freeze({ color = "surfaceRaised", icon = nil, strokeThickness = 0 }),
	Active = table.freeze({ color = "primary", icon = "pending", strokeThickness = 2 }),
	Good = table.freeze({ color = "success", icon = "check", strokeThickness = 2 }),
	Bad = table.freeze({ color = "danger", icon = "close", strokeThickness = 4 }),
}

function TaskViewLogic.feedback(state: Feedback): FeedbackStyle
	return FEEDBACK[state]
end

-- TIMER ----------------------------------------------------------------

-- "0:07" style. Whole seconds, floored, so it ticks exactly once a
-- second and the label only rewrites on change.
function TaskViewLogic.clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

return table.freeze(TaskViewLogic)
