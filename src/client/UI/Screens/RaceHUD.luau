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
--   - The first Primary zone: the held power-up. On touch it is the use
--     button, above and left of Roblox's jump button. With a keyboard or
--     gamepad it is the same card with a key hint instead, because
--     there is nothing to tap.
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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Clock = require(ReplicatedStorage.Shared.Clock)
local Base = require(script.Parent.Parent.Components.Base)
local C = require(script.Parent.Parent.Components)
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
export type Held = { id: string, name: string }
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
	held: () -> Held?,
	pending: () -> boolean, -- a use is on its way to the server
	effects: () -> { HudLogic.Effect },
	objective: () -> Objective?,
	use: () -> (),
	now: (() -> number)?, -- clock override for the preview; default Clock.now
}

local CLOCK_STEP = 0.1
local USE_ACTION = "RaceHUDUsePowerUp"
local USE_KEY = Enum.KeyCode.Q
-- ButtonA is jump and R2 is Roblox's tool activate; X is free.
local USE_PAD = Enum.KeyCode.ButtonX

local RING = 64
local PILL = 88
local GAP = Theme.spacing.sm
local TOP_WIDTH = 2 * PILL + RING + 2 * GAP
local CHIP = 36
local TASK_WIDTH = 150
local TASK_ROW = 18
local POWER_WIDTH = 160
local POWER_HEIGHT = 52

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
	return card("Placement", 1, UDim2.fromOffset(PILL, RING), {
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

local function taskBar(done: () -> number, total: () -> number, width: number, order: number): GuiObject
	return C.ProgressBar({
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
end

-- POWER-UP -------------------------------------------------------------

local function powerUpCard(store: Store, position: () -> UDim2): Frame
	local touch = function()
		return Env.inputMode() == Enum.PreferredInput.Touch
	end
	local name = derive(function()
		local held = store.held()
		return if held then held.name else "Empty"
	end)
	local empty = derive(function()
		return store.held() == nil
	end)

	local button = C.Button({
		label = name,
		icon = "bolt",
		variant = "primary",
		width = POWER_WIDTH,
		disabled = empty,
		loading = store.pending,
		onActivate = store.use,
		position = UDim2.fromScale(0.5, 0.5),
		anchorPoint = Vector2.new(0.5, 0.5),
	})

	-- Keyboard and gamepad: the same card, with the key to press where
	-- the tap target would be.
	local hint = card("KeyHint", 0, UDim2.fromScale(1, 1), {
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		create("Frame")({
			Name = "Key",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(28, 28),
			BackgroundColor3 = Theme.color.surfaceRaised,
			Base.corner(Theme.radius.sm),
			create("UIStroke")({ Color = Theme.color.ink, Thickness = 1 }),
			Base.text("label", {
				Size = UDim2.fromScale(1, 1),
				Text = function()
					return if Env.isGamepad() then "X" else "Q"
				end,
			}),
		}),
		(function()
			local icon = Icons.view("bolt", 24, function(): Color3
				return if empty() then Theme.color.inkMuted else Theme.color.warning
			end)
			icon.LayoutOrder = 2
			return icon
		end)(),
		Base.text("label", {
			Name = "Name",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(POWER_WIDTH - 28 - 24 - 3 * GAP - 2 * Theme.spacing.xs, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = function(): Color3
				return if empty() then Theme.color.inkMuted else Theme.color.ink
			end,
			Text = name,
		}),
	})

	effect(function()
		local isTouch = touch()
		button.Visible = isTouch
		hint.Visible = not isTouch
	end)

	return create("Frame")({
		Name = "PowerUp",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.fromOffset(POWER_WIDTH, POWER_HEIGHT),
		BackgroundTransparency = 1,
		button :: GuiObject,
		hint :: GuiObject,
	}) :: Frame
end

-- The centre of this orientation's first Primary zone.
local function primaryCentre(orientation: string): UDim2
	for _, zone in Layout.THUMB_ZONES[orientation :: Layout.Orientation] do
		if zone.kind == "Primary" then
			local r = zone.rect
			return UDim2.fromScale(r.x + r.width / 2, r.y + r.height / 2)
		end
	end
	return UDim2.fromScale(0.75, 0.75)
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

		local power = powerUpCard(store, function()
			return primaryCentre(orientation())
		end)
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

		-- Keyboard and gamepad use. Bound on touch too: harmless, and a
		-- tablet with a keyboard attached switches modes mid-race.
		ContextActionService:BindAction(USE_ACTION, function(_, inputState: Enum.UserInputState)
			if inputState ~= Enum.UserInputState.Begin or store.held() == nil or store.pending() then
				return Enum.ContextActionResult.Pass
			end
			store.use()
			return Enum.ContextActionResult.Sink
		end, false, USE_KEY, USE_PAD)
		cleanup(function()
			ContextActionService:UnbindAction(USE_ACTION)
		end)
	end)

	return function()
		destroy()
		gui:Destroy()
		edgeGui:Destroy()
	end
end

return RaceHUD
