--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- One input adapter per interaction verb (P6-4, docs/task-views.md).
-- A task view picks the adapter for its TaskDef.verb and gets touch,
-- mouse, keyboard and gamepad handling from it; a view never reads
-- UserInputService itself.
--
--   Tap       one big target; A / Enter when focused
--   Hold      press-and-hold with a fill; A or Space held anywhere
--   Drag      drag an item onto a target, OR pick it then pick the
--             target (the gamepad path, and a no-drag path for touch)
--   Sequence  a grid of keys; D-pad moves, A presses, number keys type
--   Timing    a sweeping cursor and one big "now" target; A / Space
--   Aim       a virtual stick; either thumbstick on a gamepad
--
-- Every adapter must be called inside a Vide scope (TaskViewBase calls
-- a view's build() inside one), and ties its connections to that scope,
-- so closing the view by ANY path disconnects everything.
--
-- The adapters REPORT; they never decide. onTap/onDrop/onRelease hand a
-- raw intent to the view, which submits it; the server judges it.
-- Every visual cue they draw is display-only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Components.Base)
local Env = require(script.Parent.Components.Env)
local TaskViewLogic = require(script.Parent.TaskViewLogic)
local Theme = require(script.Parent.Theme)
local Tokens = require(script.Parent.Tokens)

local cleanup = vide.cleanup
local create = vide.create
local source = vide.source

local T = Tokens.taskView
local DRAG_CONFIG: TaskViewLogic.DragConfig = { slop = T.dragSlop, staleSeconds = T.dragStaleSeconds }

type Source<T> = Base.Source<T>
type Visual = (state: Source<Base.State>, focused: Source<boolean>) -> { Instance }

local InputAdapters = {}

-- SHARED ---------------------------------------------------------------

local function connect(signal: RBXScriptSignal, fn: (...any) -> ())
	local c = signal:Connect(fn)
	cleanup(function()
		c:Disconnect()
	end)
end

local function isPointerPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
end

-- One identity per physical pointer: each touch keeps its own
-- InputObject for its whole life; the mouse's press and its movement
-- arrive on DIFFERENT InputObjects, so the mouse is one fixed key.
local MOUSE = table.freeze({})
local function pointerOf(input: InputObject): any
	return if input.UserInputType == Enum.UserInputType.Touch then input else MOUSE
end

-- Input positions and AbsolutePosition share one space (the viewport
-- below the top-bar inset), which is what every hit test here compares.
-- The one place to fix if a device ever disagrees.
local function pointOf(input: InputObject): TaskViewLogic.Point
	return { x = input.Position.X, y = input.Position.Y }
end

local function rectOf(g: GuiObject): TaskViewLogic.Rect
	local p, s = g.AbsolutePosition, g.AbsoluteSize
	return { x = p.X, y = p.Y, width = s.X, height = s.Y }
end

-- Min edge for hit tests in real screen pixels (AbsoluteSize is post-
-- UIScale, so the 44-point minimum applies unscaled here).
local function minEdgePixels(): number
	return Theme.touch.minTargetPoints
end

-- A key press that should count while the view is open, but not while
-- the player is typing in chat.
local function keyPressed(input: InputObject, processed: boolean, keys: { Enum.KeyCode }): boolean
	if processed and input.KeyCode ~= Enum.KeyCode.ButtonA then
		return false
	end
	return table.find(keys, input.KeyCode) ~= nil
end

local PRESS_KEYS = { Enum.KeyCode.ButtonA, Enum.KeyCode.Space }

-- TAP ------------------------------------------------------------------

export type TapProps = {
	size: Vector2,
	visual: Visual,
	onTap: () -> (),
	disabled: (boolean | Source<boolean>)?,
	position: UDim2?,
	anchorPoint: Vector2?,
	order: number?,
	name: string?,
}

-- Base.interactive already pads to the touch minimum and handles
-- A/Enter on the focused button; Tap is it under the verb's name so a
-- task author reaches for "the Tap adapter" and not a raw TextButton.
function InputAdapters.Tap(props: TapProps): TextButton
	return Base.interactive({
		name = props.name or "Tap",
		size = props.size,
		disabled = props.disabled,
		onActivate = props.onTap,
		order = props.order,
		position = props.position,
		anchorPoint = props.anchorPoint,
		radius = Theme.radius.lg,
		visual = props.visual,
	})
end

-- HOLD -----------------------------------------------------------------

export type HoldProps = {
	size: Vector2,
	-- `fraction` is display-only: 0..1 of requiredSeconds held so far.
	visual: (fraction: Source<number>, holding: Source<boolean>) -> { Instance },
	requiredSeconds: number,
	onPress: () -> (),
	-- Seconds held by the client's clock; the server keeps its own.
	onRelease: (heldSeconds: number) -> (),
	position: UDim2?,
	anchorPoint: Vector2?,
}

function InputAdapters.Hold(props: HoldProps): TextButton
	local fraction = source(0)
	local holding = source(false)
	local owner: any? = nil
	local startedAt = 0

	local function press(who: any)
		if owner ~= nil then
			return -- a second finger or key while held is noise
		end
		owner = who
		startedAt = os.clock()
		holding(true)
		props.onPress()
	end
	local function release(who: any)
		if owner == nil or who ~= owner then
			return
		end
		owner = nil
		holding(false)
		local held = os.clock() - startedAt
		fraction(0)
		props.onRelease(held)
	end

	connect(RunService.RenderStepped, function()
		if owner ~= nil then
			fraction(TaskViewLogic.holdFraction(os.clock() - startedAt, props.requiredSeconds))
		end
	end)
	connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if keyPressed(input, processed, PRESS_KEYS) then
			press(input.KeyCode)
		end
	end)
	connect(UserInputService.InputEnded, function(input: InputObject)
		if isPointerPress(input) then
			release(pointerOf(input))
		elseif table.find(PRESS_KEYS, input.KeyCode) then
			release(input.KeyCode)
		end
	end)
	-- Alt-tab or a system overlay mid-hold: InputEnded may never come.
	connect(UserInputService.WindowFocusReleased, function()
		if owner ~= nil then
			release(owner)
		end
	end)
	cleanup(function()
		owner = nil
	end)

	local button = Base.interactive({
		name = "Hold",
		size = props.size,
		onActivate = function() end, -- driven by InputBegan/Ended, not Activated
		position = props.position,
		anchorPoint = props.anchorPoint,
		radius = Theme.radius.pill,
		visual = function()
			return props.visual(fraction, holding)
		end,
	})
	-- Presses must land on the hit area; releases are caught globally
	-- above, so a thumb that slides off the button still releases.
	connect(button.InputBegan, function(input: InputObject)
		if isPointerPress(input) then
			press(pointerOf(input))
		end
	end)
	return button
end

-- DRAG -----------------------------------------------------------------

export type DragProps = {
	-- Draggable items and drop targets. Both must be GuiButtons so the
	-- pick-then-place path (gamepad, keyboard, and touch players who
	-- would rather tap twice) works through Activated.
	items: { [string]: GuiButton },
	targets: { [string]: GuiButton },
	-- The play area (TaskViewBase's content frame). A drag that leaves
	-- it is cancelled, not dropped.
	area: GuiObject,
	-- Extra hit margin around each target, in screen pixels.
	targetExtra: number?,
	onDrop: (itemId: string, targetId: string) -> (),
}

export type DragState = {
	-- The item being dragged or picked, for the view to highlight.
	held: Source<string?>,
	-- Where the dragged ghost is, in the area's local space; nil when
	-- the item is picked (not dragged) or nothing is held.
	ghost: Source<UDim2?>,
}

function InputAdapters.Drag(props: DragProps): DragState
	local drag = TaskViewLogic.newDrag()
	local held: Source<string?> & ((string?) -> string?) = source(nil) :: any
	local ghost: Source<UDim2?> & ((UDim2?) -> UDim2?) = source(nil) :: any
	local extra = props.targetExtra or Theme.spacing.lg

	local function targetRects(): { [string]: TaskViewLogic.Rect }
		local out = {}
		for id, g in props.targets do
			out[id] = TaskViewLogic.inflate(rectOf(g), minEdgePixels(), extra)
		end
		return out
	end

	local function toLocal(p: TaskViewLogic.Point): UDim2
		local a = props.area.AbsolutePosition
		return UDim2.fromOffset(p.x - a.X, p.y - a.Y)
	end

	local function drop(itemId: string, targetId: string?)
		held(nil)
		ghost(nil)
		if targetId ~= nil then
			props.onDrop(itemId, targetId)
		end
	end

	local function outcome(itemId: string?, o: TaskViewLogic.DragOutcome)
		if itemId == nil then
			return
		end
		if o.kind == "Moved" then
			ghost(toLocal(o.at))
		elseif o.kind == "Drop" then
			drop(itemId, TaskViewLogic.pickTarget(targetRects(), o.at))
		elseif o.kind == "Tap" then
			-- A tap on an item leaves it picked; the next target tap places.
			ghost(nil)
		elseif o.kind == "Cancel" then
			held(nil)
			ghost(nil)
		end
	end

	for id, item in props.items do
		connect(item.InputBegan, function(input: InputObject)
			if not isPointerPress(input) then
				return
			end
			local o = TaskViewLogic.dragBegin(drag, pointerOf(input), pointOf(input), os.clock(), rectOf(props.area))
			if o.kind == "Started" then
				held(id)
			end
		end)
		-- Gamepad / keyboard pick. (A touch tap also fires Activated,
		-- after the drag machine has already reported "Tap": harmless,
		-- it picks the same item.)
		connect(item.Activated, function()
			if drag.pointer == nil then
				held(if held() == id then nil else id)
			end
		end)
	end

	for id, target in props.targets do
		connect(target.Activated, function()
			local itemId = held()
			if itemId ~= nil and drag.pointer == nil then
				drop(itemId, id)
			end
		end)
	end

	connect(UserInputService.InputChanged, function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseMovement then
			outcome(
				held(),
				TaskViewLogic.dragMove(
					drag,
					pointerOf(input),
					pointOf(input),
					os.clock(),
					rectOf(props.area),
					DRAG_CONFIG
				)
			)
		end
	end)
	connect(UserInputService.InputEnded, function(input: InputObject)
		if not isPointerPress(input) then
			return
		end
		-- The OS took the touch (notification shade, a call): Cancel,
		-- never a drop at wherever the finger was last reported.
		local o = if input.UserInputState == Enum.UserInputState.Cancel
			then TaskViewLogic.dragCancel(drag)
			else TaskViewLogic.dragEnd(drag, pointerOf(input), pointOf(input), rectOf(props.area))
		outcome(held(), o)
	end)
	connect(RunService.Heartbeat, function()
		outcome(held(), TaskViewLogic.dragTick(drag, os.clock(), DRAG_CONFIG))
	end)
	connect(UserInputService.WindowFocusReleased, function()
		outcome(held(), TaskViewLogic.dragCancel(drag))
	end)
	cleanup(function()
		TaskViewLogic.dragCancel(drag)
	end)

	return { held = held, ghost = ghost }
end

-- SEQUENCE -------------------------------------------------------------

export type SequenceKey = {
	id: string,
	label: string,
	-- Keyboard shortcut, e.g. Enum.KeyCode.One for a "1" key.
	keyCode: Enum.KeyCode?,
}

export type SequenceProps = {
	keys: { SequenceKey },
	columns: number,
	keySize: Vector2,
	onPress: (id: string) -> (),
	disabled: Source<boolean>?,
	-- The key visual; `pressed` flashes for Theme.motion.fast after a press
	-- so a player gets confirmation without needing to hear a click.
	visual: (key: SequenceKey, state: Source<Base.State>, focused: Source<boolean>) -> { Instance },
}

-- Returns the grid frame. Gamepad navigation is explicit
-- (NextSelection*) via TaskViewLogic.stepGrid, so the D-pad stops at the
-- grid's edges instead of Roblox's nearest-neighbour search jumping off
-- the pad onto the close button mid-code.
function InputAdapters.Sequence(props: SequenceProps): Frame
	local disabled = props.disabled or function()
		return false
	end
	local gap = Theme.spacing.md
	local buttons: { TextButton } = {}

	for i, key in props.keys do
		local col = (i - 1) % props.columns
		local row = (i - 1) // props.columns
		buttons[i] = Base.interactive({
			name = "Key_" .. key.id,
			size = props.keySize,
			disabled = disabled,
			onActivate = function()
				props.onPress(key.id)
			end,
			order = i,
			position = UDim2.fromOffset(col * (props.keySize.X + gap), row * (props.keySize.Y + gap)),
			radius = Theme.radius.md,
			visual = function(state, focused)
				return props.visual(key, state, focused)
			end,
		})
	end

	local count = #buttons
	for i, b in buttons do
		b.NextSelectionLeft = buttons[TaskViewLogic.stepGrid(i, props.columns, count, -1, 0)]
		b.NextSelectionRight = buttons[TaskViewLogic.stepGrid(i, props.columns, count, 1, 0)]
		b.NextSelectionUp = buttons[TaskViewLogic.stepGrid(i, props.columns, count, 0, -1)]
		b.NextSelectionDown = buttons[TaskViewLogic.stepGrid(i, props.columns, count, 0, 1)]
	end

	connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed or disabled() then
			return
		end
		for _, key in props.keys do
			if key.keyCode ~= nil and input.KeyCode == key.keyCode then
				props.onPress(key.id)
				return
			end
		end
	end)

	local rows = math.ceil(count / props.columns)
	local grid = create("Frame")({
		Name = "SequenceGrid",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(
			props.columns * props.keySize.X + (props.columns - 1) * gap,
			rows * props.keySize.Y + (rows - 1) * gap
		),
		SelectionGroup = true,
	}) :: Frame
	for _, b in buttons do
		b.Parent = grid
	end
	return grid
end

-- TIMING ---------------------------------------------------------------

export type TimingProps = {
	-- Seconds for one sweep there and back. Display only: the server
	-- decides whether a press landed in the window by its own clock.
	period: number,
	size: Vector2,
	visual: (cursor: Source<number>) -> { Instance },
	onPress: () -> (),
	position: UDim2?,
	anchorPoint: Vector2?,
}

-- The whole target is the press area, and A/Space work from anywhere:
-- a timing task tests timing, not aim.
function InputAdapters.Timing(props: TimingProps): TextButton
	local cursor = source(0)
	local startedAt = os.clock()
	connect(RunService.RenderStepped, function()
		-- Under reduced motion the cursor still moves (it IS the task),
		-- but the view should drop any trail/glow it draws around it.
		cursor(TaskViewLogic.sweep(os.clock() - startedAt, props.period))
	end)
	connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if input.KeyCode ~= Enum.KeyCode.ButtonA and keyPressed(input, processed, PRESS_KEYS) then
			props.onPress()
		end
	end)
	return Base.interactive({
		name = "Timing",
		size = props.size,
		onActivate = props.onPress, -- touch, click, and A on the focused target
		position = props.position,
		anchorPoint = props.anchorPoint,
		radius = Theme.radius.lg,
		visual = function()
			return props.visual(cursor)
		end,
	})
end

-- AIM ------------------------------------------------------------------

export type AimProps = {
	-- Radius of the virtual stick in reference pixels.
	radius: number,
	onAim: (dir: TaskViewLogic.Point?, strength: number) -> (),
	-- Fires on release (finger up, A pressed) with the last aim.
	onRelease: (dir: TaskViewLogic.Point?, strength: number) -> (),
	position: UDim2?,
	anchorPoint: Vector2?,
}

-- A virtual stick for one thumb: press anywhere on the pad and drag.
-- The stick's origin is where the thumb landed, not the pad's centre -
-- a thumb that lands off-centre shouldn't start already aiming.
-- Gamepad: either thumbstick aims, A fires.
function InputAdapters.Aim(props: AimProps): Frame
	local owner: any? = nil
	local origin: TaskViewLogic.Point = { x = 0, y = 0 }
	local lastDir: TaskViewLogic.Point? = nil
	local lastStrength = 0
	local knob: Source<Vector2> & ((Vector2) -> Vector2) = source(Vector2.zero) :: any

	local function aimTo(p: TaskViewLogic.Point, radiusPx: number)
		local dir, strength = TaskViewLogic.aim(origin, p, radiusPx, Tokens.taskView.stickDeadzone)
		lastDir, lastStrength = dir, strength
		knob(if dir then Vector2.new(dir.x, dir.y) * strength else Vector2.zero)
		props.onAim(dir, strength)
	end
	local function fire()
		props.onRelease(lastDir, lastStrength)
		lastDir, lastStrength = nil, 0
		knob(Vector2.zero)
	end

	local pad: Frame
	local diameter = props.radius * 2

	connect(UserInputService.InputChanged, function(input: InputObject)
		local t = input.UserInputType
		if
			owner ~= nil
			and pointerOf(input) == owner
			and (t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseMovement)
		then
			aimTo(pointOf(input), pad.AbsoluteSize.X / 2)
		elseif input.KeyCode == Enum.KeyCode.Thumbstick1 or input.KeyCode == Enum.KeyCode.Thumbstick2 then
			origin = { x = 0, y = 0 }
			-- Stick Y is up-positive; screen Y is down-positive.
			aimTo({ x = input.Position.X, y = -input.Position.Y }, 1)
		end
	end)
	connect(UserInputService.InputEnded, function(input: InputObject)
		if owner ~= nil and isPointerPress(input) and pointerOf(input) == owner then
			owner = nil
			if input.UserInputState == Enum.UserInputState.Cancel then
				lastDir, lastStrength = nil, 0
				knob(Vector2.zero)
				props.onAim(nil, 0)
			else
				fire()
			end
		end
	end)
	connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if keyPressed(input, processed, PRESS_KEYS) then
			fire()
		end
	end)

	pad = create("Frame")({
		Name = "AimPad",
		Size = UDim2.fromOffset(diameter, diameter),
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchorPoint or Vector2.zero,
		BackgroundColor3 = Theme.color.surfaceRaised,
		Active = true,
		Base.corner(Theme.radius.pill),
		InputBegan = function(input: InputObject)
			if owner == nil and isPointerPress(input) then
				owner = pointerOf(input)
				origin = pointOf(input)
			end
		end,
		create("Frame")({
			Name = "Knob",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(Theme.touch.minTargetPoints, Theme.touch.minTargetPoints),
			BackgroundColor3 = Theme.color.primary,
			Position = Env.animate(function()
				local k = knob()
				return UDim2.fromScale(0.5 + k.X / 2, 0.5 + k.Y / 2)
			end, Theme.motion.fast),
			Base.corner(Theme.radius.pill),
		}),
	}) :: Frame
	return pad
end

return InputAdapters
