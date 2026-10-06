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
	text: string,
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

local MAX_VISIBLE = 3
local WIDTH = 360 - 2 * Theme.spacing.lg
local HEIGHT = Theme.spacing.xxxl + Theme.spacing.xs -- 52
local IMAGE = HEIGHT - 2 * Theme.spacing.xs -- 44, inset like the text

local Toast = {}

function Toast.card(props: Props): Frame
	local kindKey: Kind = props.kind or "info"
	local kind = KIND[kindKey]
	local accent = Theme.color[kind.color]
	local imageId = props.imageAssetId
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

type Entry = { text: string, kind: Kind, imageAssetId: number? }

local queue = source({} :: { Entry })
local hostStarted = false

local function startHost()
	hostStarted = true
	local gui = UIScaleController.createScreen("Toasts", { displayOrder = Theme.displayOrder.toast })
	vide.root(function()
		local stack = create("Frame")({
			Name = "Stack",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, Theme.spacing.sm),
			Size = UDim2.fromOffset(WIDTH, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Active = false,
			create("UIListLayout")({
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
			}),
			vide.values(queue, function(entry: Entry, index: () -> number)
				local entered = source(false)
				local card = Toast.card({ text = entry.text, kind = entry.kind, imageAssetId = entry.imageAssetId })
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
			Parent = gui,
		})
		UIScaleController.attachScale(stack)
	end)
end

function Toast.show(text: string, kind: Kind?, imageAssetId: number?)
	if not hostStarted then
		startHost()
	end
	local entry: Entry = { text = text, kind = kind or "info", imageAssetId = imageAssetId }
	local nextQueue = ComponentLogic.pushToast(queue(), entry, MAX_VISIBLE)
	queue(nextQueue)
	task.delay(ComponentLogic.toastSeconds(text), function()
		local current = queue()
		local i = table.find(current, entry)
		if i then
			local trimmed = table.clone(current)
			table.remove(trimmed, i)
			queue(trimmed)
		end
	end)
end

return Toast
