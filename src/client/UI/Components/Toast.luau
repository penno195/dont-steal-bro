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
-- Small on purpose (playtest, 2026-10-06: full-width 52-tall cards
-- walled off the top of the view): one row as wide as its text, at most
-- MAX_VISIBLE at once, a new one pushing out the oldest
-- (ComponentLogic.pushToast). Each stays ComponentLogic.toastSeconds.
-- A repeat of one already up merges into it: a count ("No target  ×3")
-- and a fresh timer, never a second card (ComponentLogic.findToast).
--
-- Toast.follow(frame) hangs the stack under `frame` and tracks it as it
-- grows - the race HUD's top stack (RaceHUD.mount), so toasts never
-- cover the timer. Toast.follow(nil) returns it to the top.
-- Toasts never take focus or input - they can't steal a tap mid-race.
-- Kind is shown by an icon AND a badge colour, never colour alone. The
-- UI art pass puts the toast on the stage panel in a gold rim, the icon
-- dark on a square badge of the kind's colour.

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
}

local KIND: { [Kind]: { color: string, icon: string } } = {
	info = { color = "brand", icon = "info" },
	success = { color = "success", icon = "check" },
	warning = { color = "warning", icon = "warning" },
	danger = { color = "danger", icon = "close" },
}

local MAX_VISIBLE = 2
local WIDTH = 360 - 2 * Theme.spacing.lg -- the widest a card gets
local HEIGHT = Theme.spacing.xxl + Theme.spacing.xs -- 36
local ICON = Theme.spacing.lg
local IMAGE = HEIGHT - 2 * Theme.spacing.xs -- 28, inset like the text
local BADGE = IMAGE

local Toast = {}

-- One row laid out left to right, as wide as its text (up to WIDTH,
-- then truncated).
function Toast.card(props: Props): Frame
	local kindKey: Kind = props.kind or "info"
	local kind = KIND[kindKey]
	local accent = Theme.color[kind.color]
	local imageId = props.imageAssetId
	local hasImage = imageId ~= nil and imageId > 0
	local textMax = WIDTH - BADGE - 3 * Theme.spacing.sm - Theme.spacing.xs - (if hasImage then IMAGE else 0)
	return create("Frame")({
		Name = "Toast",
		Size = UDim2.fromOffset(0, HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = props.layoutOrder or 0,
		-- The UIGradient tints white into the stage panel (Panel).
		BackgroundColor3 = Color3.new(1, 1, 1),
		Base.corner(Theme.radius.md),
		create("UIGradient")({ Rotation = 90, Color = Theme.fill.panel.gradient }),
		create("UIStroke")({
			BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Theme.fill.panel.rim,
			Thickness = 2,
		}),
		create("UIPadding")({
			PaddingLeft = UDim.new(0, Theme.spacing.xs),
			PaddingRight = UDim.new(0, Theme.spacing.sm),
		}),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		create("Frame")({
			Name = "Badge",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(BADGE, BADGE),
			BackgroundColor3 = accent,
			Base.corner(Theme.radius.md),
			create("UIStroke")({
				BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = accent:Lerp(Theme.color.outline, 0.6),
				Thickness = 2,
			}),
			-- Every kind colour is light enough for the dark outline ink.
			create("Frame")({
				Name = "IconSlot",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(ICON, ICON),
				BackgroundTransparency = 1,
				Icons.view(kind.icon, ICON, Theme.color.outline),
			}),
		}),
		Base.text("body", {
			Name = "Message",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(0, HEIGHT),
			AutomaticSize = Enum.AutomaticSize.X,
			Text = props.text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			create("UISizeConstraint")({ MaxSize = Vector2.new(textMax, HEIGHT) }),
		}),
		if hasImage
			then create("ImageLabel")({
				Name = "Image",
				LayoutOrder = 4,
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
				Padding = UDim.new(0, Theme.spacing.xs),
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

-- Hang the stack just under `below` (in real pixels, so both guis'
-- insets and scales cancel out), or back at the top with nil.
function Toast.follow(below: GuiObject?)
	if not hostStarted then
		startHost()
	end
	for _, conn in followConns do
		conn:Disconnect()
	end
	followConns = {}
	local target = below
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
	queue((ComponentLogic.pushToast(current, entry, MAX_VISIBLE)))
	expire(entry)
end

return Toast
