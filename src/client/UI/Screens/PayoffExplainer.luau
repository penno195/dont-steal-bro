--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- "How it works" (P6-8): the one-screen Steal or Share explainer, as a
-- modal. Opened from the (i) on the Decision Studio's payoff table and
-- from the Negotiate and Choose tips.
--
-- One screen, top to bottom: how picking works, the four ways a table
-- can go (each with the Steal/Share faces, so it matches the buttons),
-- the one-line lesson, then the streak. Every prize comes from
-- DecisionLogic.explainerRows, which reads prizeFor, so the sheet can't
-- disagree with what the server pays out.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.Components.Base)
local C = require(script.Parent.Parent.Components)
local DecisionLogic = require(script.Parent.Parent.DecisionLogic)
local Theme = require(script.Parent.Parent.Theme)
local Tokens = require(script.Parent.Parent.Tokens)
local UIScaleController = require(script.Parent.Parent.Parent.Controllers.UIScaleController)

local create = vide.create

local PayoffExplainer = {}

local PIP = 18

-- A Frame from props plus an array of children.
local function frame(props: { [any]: any }, children: { any }): Frame
	for _, child in children do
		table.insert(props, child)
	end
	return create("Frame")(props) :: Frame
end

-- One small face per finalist: a diamond for a stealer and a pill for
-- a sharer, in their colours, the same shapes as the hold buttons.
local function pips(stealers: number, seats: number): Frame
	local children: { any } = {
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Theme.spacing.xxs),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
	}
	for i = 1, seats do
		local steal = i <= stealers
		local spec = if steal then Tokens.decision.steal else Tokens.decision.share
		table.insert(
			children,
			create("Frame")({
				Name = spec.label,
				LayoutOrder = i,
				Size = UDim2.fromOffset(PIP, PIP),
				-- A diamond is a square turned 45 degrees; shrink it so its
				-- corners stay inside the pip's box.
				Rotation = if steal then 45 else 0,
				BackgroundColor3 = Theme.color[spec.color],
				create("UIScale")({ Scale = if steal then 0.72 else 1 }),
				Base.corner(if steal then Theme.radius.none else Theme.radius.pill),
			})
		)
	end
	return frame({
		Name = "Pips",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(seats * (PIP + Theme.spacing.xxs), PIP),
	}, children)
end

local function line(style: string, text: string, order: number, color: Color3?): TextLabel
	return Base.text(style, {
		Name = "Line",
		LayoutOrder = order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextScaled = false,
		TextSize = Theme.type[style].size,
		Text = text,
		TextColor3 = color or Theme.color.ink,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
end

local function row(entry: DecisionLogic.ExplainerRow, seats: number, order: number): Frame
	local headline = line("label", entry.headline, 1)
	local detail = line("body", entry.detail, 2, Theme.color.inkMuted)
	return create("Frame")({
		Name = "Case",
		LayoutOrder = order,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		pips(entry.stealers, seats),
		create("Frame")({
			Name = "Words",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -(seats * (PIP + Theme.spacing.xxs) + Theme.spacing.sm), 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			create("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder }),
			headline,
			detail,
		}),
	}) :: Frame
end

-- The sheet's content, for Modal's `content`. Plain text sizes rather
-- than TextScaled: this is reading copy, so it wraps at a fixed size
-- and the box grows to fit (it still scales with the global UIScale,
-- which is what Text and HUD size drives).
function PayoffExplainer.content(seats: number, maxHeight: number): ScrollingFrame
	local E = DecisionLogic.EXPLAINER
	local children: { any } = {
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	table.insert(children, line("body", E.secret, 1))
	for i, entry in DecisionLogic.explainerRows(seats) do
		table.insert(children, row(entry, seats, 1 + i))
	end
	table.insert(children, line("label", "★ " .. E.lesson, 10, Theme.color.steal))
	table.insert(children, line("body", E.streak, 11))

	local body = frame({
		Name = "Explainer",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH - Theme.spacing.sm, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, children)

	-- Sized to the content up to `maxHeight`, then it scrolls. In
	-- portrait it never reaches the cap. A landscape phone is too short
	-- for the whole sheet (mobile-audit's recurring issue #2).
	return create("ScrollingFrame")({
		Name = "ExplainerScroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		create("UISizeConstraint")({ MaxSize = Vector2.new(math.huge, maxHeight) }),
		body,
	}) :: ScrollingFrame
end

-- Opens the sheet. Returns `close`. `seats` is the finalist count; the
-- default 3 is every real Studio (NPCs fill empty seats, Q2).
function PayoffExplainer.open(seats: number?, onClosed: (() -> ())?): () -> ()
	local close: () -> ()
	local function done()
		close()
		if onClosed then
			onClosed()
		end
	end
	close = C.Modal.open({
		title = DecisionLogic.EXPLAINER.title,
		content = function()
			-- The usable height in reference px, minus the card's own
			-- header, button and padding.
			local rect = UIScaleController.getUsableRect()
			local available = rect.height / math.max(C.Env.scale(), 0.01)
			local chrome = Theme.touch.iconButton + Theme.touch.primaryHeight + 4 * Theme.spacing.lg
			return PayoffExplainer.content(seats or 3, math.max(available - chrome, 160))
		end,
		actions = { { label = "Got it", onActivate = done } },
		dismissible = true,
		onDismiss = done,
	})
	return close
end

return PayoffExplainer
