--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The in-race HUD (P6-3). Mounted by RaceHUDController for the Race
-- round state, and by RaceHUDPreview with fake data for device review.
--
-- WHAT GOES WHERE (Layout.THUMB_ZONES):
--   - Top-centre, the Info zone: placement and the qualification-line
--     gap, the round countdown, the objective arrow; under them the
--     effect chips (and, in portrait, the task progress bar).
--   - Top-left, landscape only: the task list. Portrait has no room
--     beside the info bar, so it gets the bar alone.
--   - The first Primary zone: the power-up slots (powerups.md
--     "Inventory and aiming"), above and left of Roblox's jump button.
--     Tap or click a slot to select it (the glow outline); tap the
--     selected one to quick-fire; press and drag out of a slot to aim,
--     release to fire, drag back onto it to cancel. With a keyboard,
--     1-N select, Q fires, and holding right-click aims in first
--     person (Q or left-click fires); a gamepad uses L1/R1, X and L2
--     the same way.
--   - The screen edges, on their own full-bleed ScreenGui: a band per
--     debuff category you're suffering (HudLogic.EDGES), never the
--     middle of the screen.
--
-- Nothing on it is a sentence: numbers, icons, and task names of a word
-- or two.
--
-- NO POLLING THE SERVER, AND NO PER-FRAME GUI CHURN. Every value comes
-- from the Store's sources, which the controller fills from remotes
-- when something actually changes. The one clock is local: a Heartbeat
-- reads Clock.now() (server time) and writes it, rounded to 0.1s, into
-- a Vide source. Vide only propagates a primitive that changed, so the
-- ring redraws 10 times a second, each number's text changes once a
-- second, and anything that doesn't depend on time never re-runs. See
-- docs/race-hud.md "Performance".

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Clock = require(ReplicatedStorage.Shared.Clock)
local Base = require(script.Parent.Parent.Components.Base)
local C = require(script.Parent.Parent.Components)
local Feel = require(script.Parent.Parent.Components.Feel)
local HudLogic = require(script.Parent.Parent.HudLogic)
local Layout = require(script.Parent.Parent.Layout)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local derive = vide.derive
local effect = vide.effect
local cleanup = vide.cleanup
local indexes = vide.indexes
local switch = vide.switch

local Env = C.Env
local Icons = C.Icons

export type TaskRow = { title: string, completed: boolean }
-- One inventory slot. `id`/`name` are nil when it's empty.
-- aimable: the item is Aimed, so hold-to-aim does something with it.
export type Slot = { index: number, id: string?, name: string?, aimable: boolean? }
-- How the player is aiming: along the first-person camera (hold
-- right-click / L2), or along a drag from the slot (touch).
export type AimMode = "Camera" | "Drag"
-- Degrees clockwise from screen-up, and studs on the ground plane.
export type Objective = { bearing: number, distance: number }

-- What the HUD reads. Sources are owned by whoever mounts it (so they
-- outlive a remount), and list entries should be frozen: Vide treats a
-- frozen table as unchanged when the same one comes back, which is what
-- stops a task row or effect chip redrawing when nothing about it moved.
export type Store = {
	selfId: number,
	qualifierCount: number,
	raceSeconds: number, -- the ring's full length
	endsAt: () -> number?, -- server time the race ends
	tasks: () -> { TaskRow },
	progress: () -> { HudLogic.ProgressEntry },
	slots: () -> { Slot }, -- always the full slot count, empty ones included
	selected: () -> number,
	aiming: () -> boolean,
	pending: () -> boolean, -- a use is on its way to the server
	effects: () -> { HudLogic.Effect },
	objective: () -> Objective?,
	select: (index: number) -> (),
	fire: () -> (), -- the selected slot, at whatever is locked on
	startAim: (mode: AimMode) -> (),
	dragAim: (dx: number, dy: number) -> (), -- pixels from where the drag began
	-- fireIfLocked: fire first if a target is locked (hold-to-aim release).
	endAim: (fireIfLocked: boolean?) -> (),
	now: (() -> number)?, -- clock override for the preview; default Clock.now
}

local CLOCK_STEP = 0.1
local USE_ACTION = "RaceHUDUsePowerUp"
local SELECT_ACTION = "RaceHUDSelectPowerUp"
local USE_KEY = Enum.KeyCode.Q
-- ButtonA is jump and R2 is Roblox's tool activate; X is free.
local USE_PAD = Enum.KeyCode.ButtonX
-- Hold to aim: the camera goes first person (RaceHUDController), so
-- the aim is where you look.
local AIM_MOUSE = Enum.UserInputType.MouseButton2
local AIM_PAD = Enum.KeyCode.ButtonL2
local SELECT_KEYS = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
}
local PREVIOUS_PAD = Enum.KeyCode.ButtonL1
local NEXT_PAD = Enum.KeyCode.ButtonR1

local RING = 64
local PILL = 88
local GAP = Theme.spacing.sm
local TOP_WIDTH = 2 * PILL + RING + 2 * GAP
local CHIP = 36
local TASK_WIDTH = 150
local TASK_ROW = 18
-- Above Tokens.touch.minTargetPoints, so no hit-area padding at scale
-- 1, and three of them still fit portrait's half-width Primary zone.
local SLOT = 60
local SLOT_LABEL = 14
-- The slot drag, in screen pixels: a press that never moves this far is
-- a tap; an aim dragged back within CANCEL_RADIUS of where it began is
-- a cancel (roughly back over the slot it started on).
local DRAG_DEADZONE = 12
local CANCEL_RADIUS = SLOT / 2

local CATEGORY_ICON: { [string]: string } = { HardControl = "lock", Movement = "slow", Vision = "eye" }
local EFFECT_ICONS = { "boost", "lock", "slow", "eye", "warning" }

-- Each line state changes the icon as well as the colour.
-- Keyed by HudLogic.LineState.
local LINE_STYLE: { [string]: { icon: string, color: string } } = {
	safe = { icon = "check", color = "success" },
	edge = { icon = "warning", color = "warning" },
	out = { icon = "down", color = "danger" },
	none = { icon = "check", color = "inkMuted" },
}
local LINE_ICONS = { "check", "warning", "down" }

-- Per side: where the band sits, and the UIGradient rotation that puts
-- its opaque end against the screen edge (0 runs left to right).
local SIDES: { [string]: { anchor: Vector2, rotation: number, across: boolean } } = {
	Top = { anchor = Vector2.new(0, 0), rotation = 90, across = true },
	Bottom = { anchor = Vector2.new(0, 1), rotation = 270, across = true },
	Left = { anchor = Vector2.new(0, 0), rotation = 0, across = false },
	Right = { anchor = Vector2.new(1, 0), rotation = 180, across = false },
}
local EDGE_FADE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.15),
	NumberSequenceKeypoint.new(1, 1),
})
-- Engine-driven, so a pulsing edge costs no Lua per frame.
local PULSE = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

local function effectIcon(entry: HudLogic.Effect): string
	if entry.kind == "Buff" then
		return "boost"
	end
	return CATEGORY_ICON[entry.category] or "warning"
end

-- An icon whose key is reactive. Icons.view is built once per key, so
-- art added to Icons.luau later still shows up here unchanged.
local function iconFor(key: () -> string, keys: { string }, size: number, color: Color3 | () -> Color3): any
	local map: { [string]: any } = {}
	for _, k in keys do
		map[k] = function()
			return Icons.view(k, size, color)
		end
	end
	return switch(key)(map)
end

local function row(order: number, height: number, children: { any }): Frame
	local props: { [any]: any } = {
		Name = "Row",
		LayoutOrder = order,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(TOP_WIDTH, height),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for _, child in children do
		table.insert(props, child)
	end
	return create("Frame")(props) :: Frame
end

local function card(name: string, order: number, size: UDim2, children: { any }): Frame
	local props: { [any]: any } = {
		Name = name,
		LayoutOrder = order,
		Size = size,
		BackgroundColor3 = Theme.color.surface,
		BackgroundTransparency = 0.15,
		Base.corner(Theme.radius.md),
		create("UIStroke")({ Color = Theme.color.line, Transparency = 0.6, Thickness = 1 }),
		Base.padding(Theme.spacing.xs),
	}
	for _, child in children do
		table.insert(props, child)
	end
	return create("Frame")(props) :: Frame
end

-- INFO BAR -------------------------------------------------------------

local function placementCard(standing: () -> HudLogic.Standing?): Frame
	local line = derive(function(): HudLogic.LineState
		return HudLogic.lineState(standing())
	end)
	local lineColor = function(): Color3
		return Theme.color[LINE_STYLE[line()].color]
	end
	-- Punches when you qualify (FeelController, P8-3).
	local placement = card("Placement", 1, UDim2.fromOffset(PILL, RING), {
		Base.text("headline", {
			Name = "Place",
			Size = UDim2.fromScale(1, 0.6),
			Text = function()
				local s = standing()
				return if s then HudLogic.placeLabel(s.place, s.tied) else "-"
			end,
		}),
		create("Frame")({
			Name = "Line",
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0, 0.6),
			Size = UDim2.fromScale(1, 0.4),
			Visible = function()
				return line() ~= "none"
			end,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Theme.spacing.xxs),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			-- Colour-blind mode swaps the icon for a word (P6-8): the icon's
			-- shape is enough to tell the states apart, but a word needs
			-- no learning.
			switch(function(): string
				return if Env.colorBlindMode() then "word" else LINE_STYLE[line()].icon
			end)((function()
				local map: { [string]: () -> Instance } = {
					word = function()
						return Base.text("label", {
							Name = "LineWord",
							LayoutOrder = 1,
							Size = UDim2.fromOffset(40, 20),
							TextColor3 = lineColor,
							Text = function()
								return HudLogic.lineWord(line())
							end,
						})
					end,
				}
				for _, k in LINE_ICONS do
					map[k] = function()
						return Icons.view(k, 16, lineColor)
					end
				end
				return map
			end)()),
			Base.text("label", {
				Name = "Gap",
				LayoutOrder = 2,
				Size = UDim2.fromOffset(32, 20),
				TextColor3 = lineColor,
				Text = derive(function()
					local s = standing()
					return HudLogic.gapLabel(if s then s.gap else nil)
				end),
			}),
		}),
	})
	Feel.attach(placement, "Placement")
	return placement
end

local function objectiveCard(objective: () -> Objective?, allDone: () -> boolean): Frame
	local arrow = Icons.view("arrow", 28, Theme.color.ink)
	arrow.LayoutOrder = 1
	local done = Icons.view("check", 28, Theme.color.success)
	done.LayoutOrder = 1
	effect(function()
		local o = objective()
		arrow.Rotation = if o then o.bearing else 0
		arrow.Visible = o ~= nil and not allDone()
		done.Visible = allDone()
	end)
	return card("Objective", 3, UDim2.fromOffset(PILL, RING), {
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		arrow,
		done,
		Base.text("label", {
			Name = "Distance",
			LayoutOrder = 2,
			Size = UDim2.fromOffset(PILL - 2 * Theme.spacing.xs, 20),
			Text = derive(function()
				local o = objective()
				if allDone() then
					return "Done"
				end
				return if o then tostring(math.floor(o.distance)) else "-"
			end),
		}),
	})
end

local function effectChip(entry: () -> HudLogic.Effect, now: () -> number): Frame
	local buff = derive(function()
		return entry().kind == "Buff"
	end)
	local ink = function(): Color3
		return if buff() then Theme.color.success else Theme.color.danger
	end
	return create("Frame")({
		Name = "Effect",
		Size = UDim2.fromOffset(CHIP + 24, CHIP),
		BackgroundColor3 = Theme.color.surface,
		BackgroundTransparency = 0.15,
		-- Shape as well as colour: a buff is a pill, a debuff is square.
		create("UICorner")({
			CornerRadius = function()
				return if buff() then Theme.radius.pill else Theme.radius.sm
			end,
		}),
		create("UIStroke")({ Color = ink, Thickness = 2 }),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.xxs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		iconFor(function()
			return effectIcon(entry())
		end, EFFECT_ICONS, 20, ink),
		Base.text("label", {
			Name = "Seconds",
			LayoutOrder = 2,
			Size = UDim2.fromOffset(22, 20),
			Text = derive(function()
				return tostring(HudLogic.wholeSecondsLeft(entry().expiresAt, now()))
			end),
		}),
	}) :: Frame
end

-- TASKS ----------------------------------------------------------------

local function taskRow(entry: () -> TaskRow, index: number): Frame
	local done = derive(function()
		return entry().completed
	end)
	local ink = function(): Color3
		return if done() then Theme.color.inkMuted else Theme.color.ink
	end
	return create("Frame")({
		Name = "Task",
		LayoutOrder = index + 1,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, TASK_ROW),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.xs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		iconFor(
			function()
				return if done() then "check" else "pending"
			end,
			{ "check", "pending" },
			TASK_ROW - 4,
			function(): Color3
				return if done() then Theme.color.success else Theme.color.ink
			end
		),
		Base.text("caption", {
			Name = "Title",
			LayoutOrder = 2,
			Size = UDim2.new(1, -(TASK_ROW + Theme.spacing.xs), 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = ink,
			Text = function()
				return entry().title
			end,
		}),
	}) :: Frame
end

-- Punches on each of your own task completions (FeelController, P8-3).
local function taskBar(done: () -> number, total: () -> number, width: number, order: number): GuiObject
	local bar = C.ProgressBar({
		value = function()
			local t = total()
			return if t > 0 then done() / t else 0
		end,
		max = 1,
		label = "Tasks",
		valueText = derive(function()
			return string.format("%d/%d", done(), total())
		end),
		width = width,
		layoutOrder = order,
	})
	Feel.attach(bar, "Tasks")
	return bar
end

-- POWER-UP -------------------------------------------------------------

-- One slot: the item's icon and name, its number on a keyboard, and the
-- glow outline when selected (red while a drag is armed to cancel).
-- Pointer input goes to `press` by hand rather than through
-- Base.interactive, because a press on a slot may become a drag.
local function powerUpSlot(
	store: Store,
	slot: () -> Slot,
	cancelling: () -> boolean,
	press: (index: number, input: InputObject) -> ()
): TextButton
	local empty = derive(function()
		return slot().id == nil
	end)
	local isSelected = derive(function()
		return store.selected() == slot().index
	end)

	local icon = Icons.view("bolt", 26, function(): Color3
		return if empty() then Theme.color.inkMuted else Theme.color.warning
	end)
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.new(0.5, 0, 0, Theme.spacing.xs)
	-- Hidden when empty rather than muted: the bolt is an emoji glyph,
	-- which ignores TextColor3, so a muted empty slot looked full.
	vide.effect(function()
		icon.Visible = not empty()
	end)

	local button = create("TextButton")({
		Name = "Slot",
		LayoutOrder = function()
			return slot().index
		end,
		Size = UDim2.fromOffset(SLOT, SLOT),
		Text = "",
		AutoButtonColor = false,
		Selectable = false, -- L1/R1 select on a gamepad; the stick is steering
		BackgroundColor3 = Theme.color.surface,
		BackgroundTransparency = function()
			return if store.pending() and isSelected() then 0.5 else 0.15
		end,
		Base.corner(Theme.radius.md),
		create("UIStroke")({
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = function(): Color3
				if not isSelected() then
					return Theme.color.line
				end
				return if cancelling() then Theme.color.danger else Theme.color.warning
			end,
			Thickness = function()
				return if isSelected() then 3 else 1
			end,
			Transparency = function()
				return if isSelected() then 0 else 0.6
			end,
		}),
		icon,
		Base.text("caption", {
			Name = "Name",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -Theme.spacing.xxs),
			Size = UDim2.new(1, -Theme.spacing.xxs * 2, 0, SLOT_LABEL),
			TextColor3 = function(): Color3
				return if empty() then Theme.color.inkMuted else Theme.color.ink
			end,
			Text = function()
				return slot().name or ""
			end,
		}),
		Base.text("caption", {
			Name = "Number",
			Position = UDim2.fromOffset(Theme.spacing.xxs, 0),
			Size = UDim2.fromOffset(SLOT_LABEL, SLOT_LABEL),
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Visible = function()
				return Env.inputMode() == Enum.PreferredInput.KeyboardAndMouse
			end,
			Text = function()
				return tostring(slot().index)
			end,
		}),
	}) :: TextButton

	button.InputBegan:Connect(function(input: InputObject)
		press(slot().index, input)
	end)
	return button
end

-- The slot row, and under it (keyboard and gamepad only) the keys to
-- fire and aim with. Owns the one press in flight: a tap selects, or
-- fires if the slot is already selected; a drag aims and fires on
-- release; dragged back onto its start it cancels (HudLogic.slotGesture).
local function powerUpPanel(store: Store, position: () -> UDim2, slotCount: number): Frame
	local cancelling = source(false)
	type Press = { input: InputObject, start: Vector2, furthest: number, index: number, aiming: boolean }
	local active: Press? = nil

	local function pointAt(input: InputObject): Vector2
		return Vector2.new(input.Position.X, input.Position.Y)
	end

	local function press(index: number, input: InputObject)
		local kind = input.UserInputType
		if active ~= nil or (kind ~= Enum.UserInputType.Touch and kind ~= Enum.UserInputType.MouseButton1) then
			return
		end
		active = { input = input, start = pointAt(input), furthest = 0, index = index, aiming = false }
	end

	-- A touch reports its moves and its end on the same InputObject; a
	-- mouse reports moves as MouseMovement and the end as MouseButton1.
	local function track(input: InputObject, ended: boolean)
		local current = active
		if current == nil then
			return
		end
		local mouse = current.input.UserInputType == Enum.UserInputType.MouseButton1
		local kind = input.UserInputType
		local same = input == current.input
			or (mouse and (kind == Enum.UserInputType.MouseMovement or kind == Enum.UserInputType.MouseButton1))
		if not same then
			return
		end

		local offset = pointAt(input) - current.start
		current.furthest = math.max(current.furthest, offset.Magnitude)
		local gesture = HudLogic.slotGesture(current.furthest, offset.Magnitude, DRAG_DEADZONE, CANCEL_RADIUS)

		if not ended then
			if gesture ~= "Tap" and not current.aiming then
				current.aiming = true
				store.select(current.index)
				store.startAim("Drag")
			end
			if current.aiming then
				store.dragAim(offset.X, offset.Y)
				cancelling(gesture == "Cancel")
			end
			return
		end

		active = nil
		cancelling(false)
		if gesture == "Tap" then
			if store.selected() == current.index then
				store.fire()
			else
				store.select(current.index)
			end
		elseif gesture == "Aim" then
			store.dragAim(offset.X, offset.Y)
			store.fire()
			store.endAim()
		else
			store.endAim()
		end
	end

	local moved = UserInputService.InputChanged:Connect(function(input: InputObject)
		track(input, false)
	end)
	local lifted = UserInputService.InputEnded:Connect(function(input: InputObject)
		track(input, true)
	end)
	cleanup(function()
		moved:Disconnect()
		lifted:Disconnect()
	end)

	local width = slotCount * SLOT + (slotCount - 1) * GAP
	return create("Frame")({
		Name = "PowerUps",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = position,
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, Theme.spacing.xxs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		create("Frame")({
			Name = "Slots",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(width, SLOT),
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			indexes(store.slots, function(slot: () -> Slot)
				return powerUpSlot(store, slot, cancelling, press)
			end) :: any,
		}),
		Base.text("caption", {
			Name = "Keys",
			LayoutOrder = 2,
			Size = UDim2.fromOffset(width, SLOT_LABEL),
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Right,
			Visible = function()
				return Env.inputMode() ~= Enum.PreferredInput.Touch
			end,
			Text = function()
				-- The aim half only when the selected item can aim: on
				-- anything else, holding it does nothing.
				local aimable = store.slots()[store.selected()].aimable == true
				if Env.isGamepad() then
					return if aimable then "X use   L2 aim" else "X use"
				end
				return if aimable then "Q use   RMB aim" else "Q use"
			end,
		}),
	}) :: Frame
end

-- The right edge of this orientation's first Primary zone, vertically
-- centred in it. The slots hang left from there, so they stay clear of
-- the jump button in landscape and of the screen edge in portrait.
local function primaryAnchor(orientation: string): UDim2
	for _, zone in Layout.THUMB_ZONES[orientation :: Layout.Orientation] do
		if zone.kind == "Primary" then
			local r = zone.rect
			return UDim2.new(r.x + r.width, -Theme.spacing.sm, r.y + r.height / 2, 0)
		end
	end
	return UDim2.new(1, -Theme.spacing.sm, 0.75, 0)
end

-- EDGES ----------------------------------------------------------------

-- One category's bands. Depth is a fraction of the screen's SHORT axis,
-- so a band is the same thickness on every side and in either
-- orientation; it's computed in pixels from the full-bleed gui's own
-- size, which is why this is Offset rather than Scale.
local function edgeSet(edge: HudLogic.Edge, visible: () -> boolean, shortAxis: () -> number, z: number): Frame
	local depth = derive(function()
		return math.floor(edge.depth * shortAxis())
	end)
	local bands: { Frame } = {}
	for _, side in edge.sides do
		local spec = SIDES[side]
		table.insert(
			bands,
			create("Frame")({
				Name = side,
				AnchorPoint = spec.anchor,
				Position = UDim2.fromScale(spec.anchor.X, spec.anchor.Y),
				Size = function()
					return if spec.across then UDim2.new(1, 0, 0, depth()) else UDim2.new(0, depth(), 1, 0)
				end,
				BackgroundColor3 = Theme.color[edge.color],
				BorderSizePixel = 0,
				create("UIGradient")({ Transparency = EDGE_FADE, Rotation = spec.rotation }),
			}) :: Frame
		)
	end

	if edge.pulse then
		local tweens: { Tween } = {}
		for _, band in bands do
			table.insert(tweens, TweenService:Create(band, PULSE, { BackgroundTransparency = 0.6 }))
		end
		effect(function()
			local on = visible() and not Env.reducedMotion()
			for i, tween in tweens do
				if on then
					tween:Play()
				else
					tween:Cancel()
					bands[i].BackgroundTransparency = 0
				end
			end
		end)
		cleanup(function()
			for _, tween in tweens do
				tween:Cancel()
			end
		end)
	end

	local props: { [any]: any } = {
		Name = "Edge" .. edge.category,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = z,
		Visible = visible,
	}
	for _, band in bands do
		table.insert(props, band)
	end
	return create("Frame")(props) :: Frame
end

-- MOUNT ----------------------------------------------------------------

local RaceHUD = {}

-- `controller` is UIScaleController (passed in, as the debug screens
-- do). Returns unmount.
function RaceHUD.mount(controller: any, store: Store): () -> ()
	-- Under the HUD's own layer, and full-bleed so the bands reach the
	-- physical edges, notch and all. Nothing on it is interactive.
	local edgeGui = controller.createScreen("RaceHUDEdges", {
		displayOrder = Theme.displayOrder.hud - 1,
		fullBleed = true,
	}) :: ScreenGui
	local gui = controller.createScreen("RaceHUD", { displayOrder = Theme.displayOrder.hud }) :: ScreenGui

	local destroy = vide.root(function()
		local readNow = store.now or Clock.now
		local now = source(HudLogic.quantize(readNow(), CLOCK_STEP))
		local heartbeat = RunService.Heartbeat:Connect(function()
			now(HudLogic.quantize(readNow(), CLOCK_STEP))
		end)
		cleanup(function()
			heartbeat:Disconnect()
		end)

		local function orientationOf(rect: Layout.Rect): Layout.Orientation
			return Layout.orientationOf(rect.width, rect.height)
		end
		local orientation = source(orientationOf(controller.getUsableRect()))
		cleanup(controller.observeUsableRect(function(rect: Layout.Rect)
			orientation(orientationOf(rect))
		end))
		local portrait = derive(function()
			return orientation() == "Portrait"
		end)

		local secondsLeft = derive(function()
			local endsAt = store.endsAt()
			return if endsAt then math.max(0, endsAt - now()) else store.raceSeconds
		end)
		local standing = derive(function()
			return HudLogic.standing(store.progress(), store.selfId, store.qualifierCount)
		end)
		local done = derive(function()
			return HudLogic.countDone(store.tasks())
		end)
		local total = derive(function()
			return #store.tasks()
		end)
		local allDone = derive(function()
			return total() > 0 and done() == total()
		end)
		local active = derive(function()
			return HudLogic.activeEffects(store.effects(), now())
		end)
		local suffering = derive(function()
			return HudLogic.sufferingCategories(store.effects(), now())
		end)

		-- Top stack: info bar, portrait task bar, effect chips.
		local compactTasks = taskBar(done, total, TOP_WIDTH - 2 * PILL / 3, 2)
		effect(function()
			compactTasks.Visible = portrait()
		end)
		local top = create("Frame")({
			Name = "Top",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.01),
			Size = UDim2.fromOffset(TOP_WIDTH, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, Theme.spacing.xs),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			row(1, RING, {
				placementCard(standing),
				C.CountdownRing({ secondsLeft = secondsLeft, total = store.raceSeconds, size = RING, layoutOrder = 2 }),
				objectiveCard(store.objective, allDone),
			}),
			compactTasks,
			row(3, CHIP, {
				indexes(active, function(entry: () -> HudLogic.Effect)
					return effectChip(entry, now)
				end),
			}),
			Parent = gui,
		}) :: Frame
		cleanup(controller.attachScale(top))

		-- Landscape task list, top-left.
		local tasks = create("Frame")({
			Name = "Tasks",
			Position = UDim2.fromScale(0.01, 0.02),
			Size = UDim2.fromOffset(TASK_WIDTH, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Theme.color.surface,
			BackgroundTransparency = 0.25,
			Visible = function()
				return not portrait()
			end,
			Base.corner(Theme.radius.md),
			Base.padding(Theme.spacing.sm),
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Theme.spacing.xxs),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			taskBar(done, total, TASK_WIDTH - 2 * Theme.spacing.sm, 1),
			indexes(store.tasks, function(entry: () -> TaskRow, index: number)
				return taskRow(entry, index)
			end) :: any,
			Parent = gui,
		}) :: Frame
		cleanup(controller.attachScale(tasks))

		local slotCount = #store.slots()
		local power = powerUpPanel(store, function()
			return primaryAnchor(orientation())
		end, slotCount)
		power.Parent = gui
		cleanup(controller.attachScale(power))

		-- Edges.
		local shortAxis = source(math.min(edgeGui.AbsoluteSize.X, edgeGui.AbsoluteSize.Y))
		local sizeChanged = edgeGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			shortAxis(math.min(edgeGui.AbsoluteSize.X, edgeGui.AbsoluteSize.Y))
		end)
		cleanup(function()
			sizeChanged:Disconnect()
		end)
		local z = 1
		for category, edge in HudLogic.EDGES do
			-- derive, so Visible is only written when it flips, not every
			-- time the clock re-runs `suffering`.
			local visible = derive(function()
				return table.find(suffering(), category) ~= nil
			end)
			local set = edgeSet(edge, visible, shortAxis, if edge.pulse then 10 else z)
			set.Parent = edgeGui
			z += 1
		end
		local unknown = derive(function()
			for _, category in suffering() do
				if HudLogic.EDGES[category] == nil then
					return true
				end
			end
			return false
		end)
		local other = edgeSet(HudLogic.edgeFor("Other"), unknown, shortAxis, 0)
		other.Parent = edgeGui

		-- Keyboard and gamepad. Bound on touch too: harmless, and a
		-- tablet with a keyboard attached switches modes mid-race.
		local function selectedHeld(): boolean
			return store.slots()[store.selected()].id ~= nil
		end
		ContextActionService:BindAction(USE_ACTION, function(_, inputState: Enum.UserInputState)
			if inputState ~= Enum.UserInputState.Begin or not selectedHeld() or store.pending() then
				return Enum.ContextActionResult.Pass
			end
			store.fire()
			return Enum.ContextActionResult.Sink
		end, false, USE_KEY, USE_PAD)

		-- Hold to aim along the (first-person) camera. Watched on
		-- UserInputService, not bound: the mouse / right stick still turn
		-- the camera (which is how the aim is steered), so nothing here
		-- may sink it, and the release must be seen even if something
		-- else took the press. While aiming, left-click fires too - the
		-- mouse is locked to the centre, so it can't be on a slot.
		local function isAimInput(input: InputObject): boolean
			return input.UserInputType == AIM_MOUSE or input.KeyCode == AIM_PAD
		end
		local aimBegan = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			if isAimInput(input) then
				store.startAim("Camera")
			elseif
				input.UserInputType == Enum.UserInputType.MouseButton1
				and store.aiming()
				and selectedHeld()
				and not store.pending()
			then
				store.fire()
			end
		end)
		local aimEnded = UserInputService.InputEnded:Connect(function(input: InputObject)
			if isAimInput(input) and store.aiming() then
				store.endAim(true) -- release fires, if something is locked
			end
		end)
		cleanup(function()
			aimBegan:Disconnect()
			aimEnded:Disconnect()
		end)

		local selectKeys = { PREVIOUS_PAD, NEXT_PAD }
		for index = 1, math.min(slotCount, #SELECT_KEYS) do
			table.insert(selectKeys, SELECT_KEYS[index])
		end
		ContextActionService:BindAction(SELECT_ACTION, function(_, inputState: Enum.UserInputState, input: InputObject)
			if inputState ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			local current = store.selected()
			if input.KeyCode == PREVIOUS_PAD then
				store.select((current - 2) % slotCount + 1)
			elseif input.KeyCode == NEXT_PAD then
				store.select(current % slotCount + 1)
			else
				store.select(table.find(SELECT_KEYS, input.KeyCode) :: number)
			end
			return Enum.ContextActionResult.Sink
		end, false, table.unpack(selectKeys))

		cleanup(function()
			ContextActionService:UnbindAction(USE_ACTION)
			ContextActionService:UnbindAction(SELECT_ACTION)
		end)
	end)

	return function()
		destroy()
		gui:Destroy()
		edgeGui:Destroy()
	end
end

return RaceHUD
