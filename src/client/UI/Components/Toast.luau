--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- Toast (P6-2): a short, non-blocking notice at the top of the screen
-- ("Ava froze you!", "+50 coins"). Top-centre is the Info thumb zone
-- (Layout.THUMB_ZONES): readable at a glance, nowhere near a control.
--
--   Toast.card(props)  one toast, as a Frame (the gallery uses this).
--   Toast.show(text, kind, imageAssetId?)  queue one on the shared host.
--
-- `imageAssetId` adds a square picture at the right-hand end - a rival's
-- CallingCard cosmetic on the "X used Y on you" toast. It sits beside
-- the kind icon, never in place of it.
--
-- At most MAX_VISIBLE at once; a new one pushes out the oldest
-- (ComponentLogic.pushToast). Each stays ComponentLogic.toastSeconds.
-- A repeat of one already up merges into it: a count ("No target  ×3")
-- and a fresh timer, never a second card (ComponentLogic.findToast).
--
-- Toast.setCompact(true, below) while a race is on (RaceHUD.mount): shorter
-- cards sized to their text, tighter gaps and at most COMPACT_MAX, so the
-- stack doesn't wall off the top of the view mid-race (playtest,
-- 2026-10-06). `below` is the race HUD's top stack; toasts hang under
-- it and follow it as it grows (effect chips, portrait task bar).
-- Toasts never take focus or input - they can't steal a tap mid-race.
-- Kind is shown by an icon AND a stripe colour, never colour alone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local ComponentLogic = require(script.Parent.ComponentLogic)
local Env = require(script.Parent.Env)
local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Parent.Theme)
local UIScaleController = require(script.Parent.Parent.Parent.Controllers.UIScaleController)

local create = vide.create
local source = vide.source

export type Kind = "info" | "success" | "warning" | "danger"

export type Props = {
	text: string | () -> string,
	kind: Kind?,
	imageAssetId: number?,
	layoutOrder: number?,
	compact: boolean?,
}

local KIND: { [Kind]: { color: string, icon: string } } = {
	info = { color = "brand", icon = "info" },
	success = { color = "success", icon = "check" },
	warning = { color = "warning", icon = "warning" },
	danger = { color = "danger", icon = "close" },
}

local MAX_VISIBLE = 3
local WIDTH = 360 - 2 * Theme.spacing.lg
local HEIGHT = Theme.spacing.xxxl + Theme.spacing.xs -- 52
local IMAGE = HEIGHT - 2 * Theme.spacing.xs -- 44, inset like the text
local COMPACT_MAX = 2
local COMPACT_HEIGHT = Theme.spacing.xxl + Theme.spacing.xs -- 36
local COMPACT_ICON = Theme.spacing.lg
local COMPACT_IMAGE = COMPACT_HEIGHT - 2 * Theme.spacing.xs -- 28

local Toast = {}

-- The race version: one row laid out left to right, as wide as its text
-- (up to WIDTH, then truncated).
local function compactCard(props: Props, accent: Color3, icon: string, imageId: number?): Frame
	local hasImage = imageId ~= nil and imageId > 0
	local textMax = WIDTH - COMPACT_ICON - 4 * Theme.spacing.sm - (if hasImage then COMPACT_IMAGE else 0)
	return create("Frame")({
		Name = "Toast",
		Size = UDim2.fromOffset(0, COMPACT_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = props.layoutOrder or 0,
		BackgroundColor3 = Theme.elevation[3].surface,
		Base.corner(Theme.radius.md),
		create("UIStroke")({
			BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Theme.color.line,
			Transparency = Theme.elevation[3].strokeTransparency,
		}),
		create("UIPadding")({ PaddingRight = UDim.new(0, Theme.spacing.sm) }),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		create("Frame")({
			Name = "Stripe",
			LayoutOrder = 1,
			Size = UDim2.new(0, Theme.spacing.xs, 1, 0),
			BackgroundColor3 = accent,
			Base.corner(Theme.radius.sm),
		}),
		create("Frame")({
			Name = "IconSlot",
			LayoutOrder = 2,
			Size = UDim2.fromOffset(COMPACT_ICON, COMPACT_ICON),
			BackgroundTransparency = 1,
			Icons.view(icon, COMPACT_ICON, accent),
		}),
		Base.text("body", {
			Name = "Message",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(0, COMPACT_HEIGHT),
			AutomaticSize = Enum.AutomaticSize.X,
			Text = props.text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			create("UISizeConstraint")({ MaxSize = Vector2.new(textMax, COMPACT_HEIGHT) }),
		}),
		if hasImage
			then create("ImageLabel")({
				Name = "Image",
				LayoutOrder = 4,
				Size = UDim2.fromOffset(COMPACT_IMAGE, COMPACT_IMAGE),
				BackgroundTransparency = 1,
				Image = string.format("rbxassetid://%d", imageId :: number),
				ScaleType = Enum.ScaleType.Fit,
				Base.corner(Theme.radius.sm),
			})
			else nil,
	}) :: Frame
end

function Toast.card(props: Props): Frame
	local kindKey: Kind = props.kind or "info"
	local kind = KIND[kindKey]
	local accent = Theme.color[kind.color]
	local imageId = props.imageAssetId
	if props.compact then
		return compactCard(props, accent, kind.icon, imageId)
	end
	local hasImage = imageId ~= nil and imageId > 0
	local imageInset = if hasImage then IMAGE + Theme.spacing.sm else 0
	local textInset = Theme.spacing.md * 2 + Theme.spacing.xl + Theme.spacing.sm + imageInset
	return create("Frame")({
		Name = "Toast",
		Size = UDim2.fromOffset(WIDTH, HEIGHT),
		LayoutOrder = props.layoutOrder or 0,
		BackgroundColor3 = Theme.elevation[3].surface,
		Base.corner(Theme.radius.md),
		create("UIStroke")({
			BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Theme.color.line,
			Transparency = Theme.elevation[3].strokeTransparency,
		}),
		create("Frame")({
			Name = "Stripe",
			Size = UDim2.new(0, Theme.spacing.xs, 1, 0),
			BackgroundColor3 = accent,
			Base.corner(Theme.radius.sm),
		}),
		create("Frame")({
			Name = "IconSlot",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, Theme.spacing.md, 0.5, 0),
			Size = UDim2.fromOffset(Theme.spacing.xl, Theme.spacing.xl),
			BackgroundTransparency = 1,
			Icons.view(kind.icon, Theme.spacing.xl, accent),
		}),
		Base.text("body", {
			Name = "Message",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, Theme.spacing.md + Theme.spacing.xl + Theme.spacing.sm, 0.5, 0),
			Size = UDim2.new(1, -textInset, 1, -Theme.spacing.sm),
			Text = props.text,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		if hasImage
			then create("ImageLabel")({
				Name = "Image",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -Theme.spacing.xs, 0.5, 0),
				Size = UDim2.fromOffset(IMAGE, IMAGE),
				BackgroundTransparency = 1,
				Image = string.format("rbxassetid://%d", imageId :: number),
				ScaleType = Enum.ScaleType.Fit,
				Base.corner(Theme.radius.sm),
			})
			else nil,
	}) :: Frame
end

-- THE HOST: one screen, created on first use, living for the session.

-- count is a source so a merged repeat relabels its card in place;
-- token is bumped on every merge, so only the latest timer removes it.
type Entry = {
	text: string,
	kind: Kind,
	imageAssetId: number?,
	count: (() -> number) & ((number) -> number),
	token: number,
}

local queue = source({} :: { Entry })
local compact = source(false)
local stackY = source(Theme.spacing.sm)
local hostStarted = false
local gui: ScreenGui? = nil
local followConns: { RBXScriptConnection } = {}

local function startHost()
	hostStarted = true
	local screen = UIScaleController.createScreen("Toasts", { displayOrder = Theme.displayOrder.toast })
	gui = screen
	vide.root(function()
		local stack = create("Frame")({
			Name = "Stack",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = function()
				return UDim2.new(0.5, 0, 0, stackY())
			end,
			Size = UDim2.fromOffset(WIDTH, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Active = false,
			create("UIListLayout")({
				Padding = function()
					return UDim.new(0, if compact() then Theme.spacing.xs else Theme.spacing.sm)
				end,
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
			}),
			vide.values(queue, function(entry: Entry, index: () -> number)
				local entered = source(false)
				local card = Toast.card({
					text = function()
						return ComponentLogic.toastLabel(entry.text, entry.count())
					end,
					kind = entry.kind,
					imageAssetId = entry.imageAssetId,
					compact = vide.untrack(compact),
				})
				-- Reactive: when the oldest drops out, the rest renumber.
				vide.effect(function()
					card.LayoutOrder = index()
				end)
				create("UIScale")({
					Scale = Env.animate(function()
						return if entered() then 1 else 0.9
					end, Theme.motion.fast),
					Parent = card,
				})
				entered(true)
				return card
			end) :: any,
			Parent = screen,
		})
		UIScaleController.attachScale(stack)
	end)
end

-- Takes `entry` down after its reading time, unless a merge has since
-- bumped its token (that merge scheduled its own, later, removal).
local function expire(entry: Entry)
	local token = entry.token
	task.delay(ComponentLogic.toastSeconds(entry.text), function()
		local current = queue()
		local i = table.find(current, entry)
		if i and entry.token == token then
			local trimmed = table.clone(current)
			table.remove(trimmed, i)
			queue(trimmed)
		end
	end)
end

-- Race mode on or off. Cards already up keep their size; new ones use
-- the new mode. With `below`, the stack sits just under that element
-- (in real pixels, so both guis' insets and scales cancel out).
function Toast.setCompact(on: boolean, below: GuiObject?)
	if not hostStarted then
		startHost()
	end
	compact(on)
	for _, conn in followConns do
		conn:Disconnect()
	end
	followConns = {}
	local target = if on then below else nil
	if target == nil then
		stackY(Theme.spacing.sm)
		return
	end
	local function place()
		local host = gui :: ScreenGui
		local bottom = target.AbsolutePosition.Y + target.AbsoluteSize.Y - host.AbsolutePosition.Y
		stackY(math.max(Theme.spacing.sm, bottom + Theme.spacing.xs))
	end
	table.insert(followConns, target:GetPropertyChangedSignal("AbsolutePosition"):Connect(place))
	table.insert(followConns, target:GetPropertyChangedSignal("AbsoluteSize"):Connect(place))
	place()
end

function Toast.show(text: string, kind: Kind?, imageAssetId: number?)
	if not hostStarted then
		startHost()
	end
	local resolved: Kind = kind or "info"
	local current = queue()
	local i = ComponentLogic.findToast(current, function(e: Entry)
		return e.text == text and e.kind == resolved and e.imageAssetId == imageAssetId
	end)
	if i then
		local entry = current[i]
		entry.token += 1
		entry.count(vide.untrack(entry.count) + 1)
		expire(entry)
		return
	end
	local entry: Entry = { text = text, kind = resolved, imageAssetId = imageAssetId, count = source(1), token = 0 }
	queue((ComponentLogic.pushToast(current, entry, if compact() then COMPACT_MAX else MAX_VISIBLE)))
	expire(entry)
end

return Toast
