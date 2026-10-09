--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The frame every full-screen menu (P6-6: store, leaderboards, results,
-- settings) sits in, so they agree on the parts a thumb learns once:
--
--   +--------------------------+
--   | Title      [trailing] (X)|  header: what this is, one widget (the
--   |                          |          store's currency pill), and
--   |          body            |          the way out, the same X as a
--   |                          |          task view's (user, 2026-10-09)
--   +--------------------------+  body: the screen's own content, given
--                                         its height so it can size a list
--
-- A screen whose way out is a next step rather than a close (Results'
-- Continue) passes `closeLabel` and gets a full-width footer button
-- instead of the X.
--
-- A single column COLUMN reference px wide under attachScale, as tall as
-- the usable rect at the current scale, centred. Portrait fills the
-- phone; landscape gets a centred column over an opaque backdrop, which
-- is still one-handed and saves every screen a second layout.
--
-- A screen whose body needs more height than landscape has (the scale
-- follows the short axis, so landscape is always ~360 tall) can opt into
-- `split`: in landscape the column widens to two panes side by side,
-- each up to INNER wide, and the body is told so through BodyLayout.
-- Decided once at mount: Roblox's default orientation only flips
-- between the two landscapes, which keep the same width.
--
-- Close is also gamepad B / Escape, bound while the screen is up.
-- On a gamepad, focus enters the screen when it opens (UI/Focus.luau).

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local Focus = require(script.Parent.Parent.Focus)
local Layout = require(script.Parent.Parent.Layout)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local derive = vide.derive
local cleanup = vide.cleanup

local Env = C.Env

local MenuShell = {}

MenuShell.COLUMN = 344
MenuShell.GUTTER = Theme.spacing.lg
-- The width the body can use: the column minus its side gutters.
MenuShell.INNER = MenuShell.COLUMN - 2 * MenuShell.GUTTER
-- A scrolling list's bar width. Roblox clips the list's content to
-- AbsoluteWindowSize, which leaves the bar out even with
-- VerticalScrollBarInset None, so content as wide as the list loses its
-- right edge under the bar. A list is made this much wider than its
-- content instead, and the bar sits in the gutter (playtest, 2026-10-06).
MenuShell.SCROLLBAR = 4

local HEADER_H = 56
local FOOTER_H = Theme.touch.primaryHeight + 2 * Theme.spacing.md
-- The task view's close-button art, a little smaller to sit inside the
-- header rather than straddle a card corner.
local CLOSE_SIZE = 48
local CLOSE_ACTION = "MenuShellClose"

-- How the body is laid out: `pane` is the width of one pane (the whole
-- body when not split), in reference px.
export type BodyLayout = {
	split: boolean,
	pane: number,
}

-- Pure: the body layout for a usable size in reference px. Split only in
-- landscape, with each pane as wide as fits, capped at INNER.
function MenuShell.bodyLayout(wantsSplit: boolean, width: number, height: number): BodyLayout
	if not wantsSplit or Layout.orientationOf(width, height) ~= "Landscape" then
		return { split = false, pane = MenuShell.INNER }
	end
	local pane = math.floor((width - 3 * MenuShell.GUTTER) / 2)
	return { split = true, pane = math.min(pane, MenuShell.INNER) }
end

export type Props = {
	name: string,
	title: string | Base.Source<string>,
	-- Builds the header's one widget, inside the screen's Vide scope.
	trailing: (() -> Instance)?,
	-- A footer button with this label replaces the header's X (see the
	-- top of this file). Default nil: the X.
	closeLabel: string?,
	onClose: () -> (),
	-- Two panes side by side in landscape (see the header). Default false.
	split: boolean?,
	-- Builds the body, inside the screen's Vide scope. `height` is the
	-- body's height in reference px; its width is MenuShell.INNER unless
	-- the screen asked for `split`, in which case `layout` says.
	body: (height: Base.Source<number>, layout: BodyLayout) -> { Instance },
}

-- Mounts the screen; returns the unmount.
function MenuShell.mount(controller: any, props: Props): () -> ()
	local gui = controller.createScreen(props.name, { displayOrder = Theme.displayOrder.panel }) :: ScreenGui

	local destroy = vide.root(function()
		local rect = source(controller.getUsableRect() :: Layout.Rect)
		cleanup(controller.observeUsableRect(rect))

		-- Column height in reference px: the usable height undone by the
		-- UIScale, so the scaled column exactly fills it.
		local columnHeight = derive(function()
			return rect().height / math.max(Env.scale(), 0.01)
		end)
		local footerH = if props.closeLabel then FOOTER_H else Theme.spacing.md
		local bodyHeight = derive(function()
			return math.max(0, columnHeight() - HEADER_H - footerH)
		end)
		local startRect = rect()
		local startScale = math.max(Env.scale(), 0.01)
		local layout =
			MenuShell.bodyLayout(props.split == true, startRect.width / startScale, startRect.height / startScale)
		local bodyWidth = if layout.split then 2 * layout.pane + MenuShell.GUTTER else MenuShell.INNER
		local columnWidth = bodyWidth + 2 * MenuShell.GUTTER

		create("Frame")({
			Name = "Backdrop",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.color.background,
			BorderSizePixel = 0,
			Active = true, -- swallow taps so nothing behind the menu fires
			Parent = gui,
		})

		local column = create("Frame")({
			Name = "Column",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = function()
				return UDim2.fromOffset(columnWidth, columnHeight())
			end,
			BackgroundTransparency = 1,

			create("Frame")({
				Name = "Header",
				Size = UDim2.fromOffset(columnWidth, HEADER_H),
				BackgroundTransparency = 1,
				create("UIPadding")({
					PaddingLeft = UDim.new(0, MenuShell.GUTTER),
					PaddingRight = UDim.new(0, MenuShell.GUTTER),
				}),
				Base.text("headline", {
					Name = "Title",
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.fromScale(0, 0.5),
					Size = UDim2.new(0.6, 0, 0, Theme.type.headline.size + Theme.spacing.xs),
					Text = props.title,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
				if props.closeLabel == nil
					then C.IconButton({
						icon = "close-button",
						iconSize = CLOSE_SIZE,
						label = "Close",
						onActivate = props.onClose,
						order = 1000, -- last in gamepad order: never the default focus
						anchorPoint = Vector2.new(1, 0.5),
						position = UDim2.fromScale(1, 0.5),
					})
					else nil,
				if props.trailing
					then create("Frame")({
						Name = "Trailing",
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.new(
							1,
							if props.closeLabel == nil then -(CLOSE_SIZE + Theme.spacing.sm) else 0,
							0.5,
							0
						),
						Size = UDim2.fromScale(0.4, 1),
						BackgroundTransparency = 1,
						create("UIListLayout")({
							FillDirection = Enum.FillDirection.Horizontal,
							HorizontalAlignment = Enum.HorizontalAlignment.Right,
							VerticalAlignment = Enum.VerticalAlignment.Center,
						}),
						props.trailing(),
					})
					else nil,
			}),

			create("Frame")({
				Name = "Body",
				Position = UDim2.fromOffset(MenuShell.GUTTER, HEADER_H),
				Size = function()
					return UDim2.fromOffset(bodyWidth, bodyHeight())
				end,
				BackgroundTransparency = 1,
				ClipsDescendants = true,
				props.body(bodyHeight, layout),
			}),

			if props.closeLabel
				then create("Frame")({
					Name = "Footer",
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.fromScale(0, 1),
					Size = UDim2.fromOffset(columnWidth, FOOTER_H),
					BackgroundTransparency = 1,
					C.Button({
						label = props.closeLabel,
						variant = "secondary",
						icon = "back",
						width = MenuShell.INNER,
						onActivate = props.onClose,
						order = 1000,
						anchorPoint = Vector2.new(0.5, 0.5),
						position = UDim2.fromScale(0.5, 0.5),
					}),
				})
				else nil,

			Parent = gui,
		}) :: Frame
		cleanup(controller.attachScale(column))

		ContextActionService:BindAction(CLOSE_ACTION, function(_, inputState: Enum.UserInputState)
			if inputState == Enum.UserInputState.Begin then
				props.onClose()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.ButtonB, Enum.KeyCode.Escape)
		cleanup(function()
			ContextActionService:UnbindAction(CLOSE_ACTION)
		end)
	end)

	-- Gamepad focus starts on the body's first element. While the body
	-- is still loading, that's Close, the only selectable thing on screen.
	local exitFocus = Focus.enter(gui)

	return function()
		exitFocus()
		destroy()
		gui:Destroy()
	end
end

-- A centred message block for loading, empty and error states, so none
-- of the menus is ever left blank. `busy` adds a spinner above it.
function MenuShell.message(
	title: string | Base.Source<string>,
	body: (string | Base.Source<string>)?,
	busy: boolean?
): Frame
	return create("Frame")({
		Name = "Message",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(MenuShell.INNER, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		if busy
			then create("Frame")({
				Name = "SpinnerSlot",
				LayoutOrder = 0,
				Size = UDim2.fromOffset(32, 32),
				BackgroundTransparency = 1,
				Base.spinner(32, function()
					return Theme.color.inkMuted
				end),
			})
			else nil,
		Base.text("title", {
			Name = "Title",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.type.title.size + Theme.spacing.xs),
			Text = title,
		}),
		if body
			then Base.text("body", {
				Name = "Body",
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, 2 * Theme.type.body.size + Theme.spacing.sm),
				Text = body,
				TextColor3 = Theme.color.inkMuted,
				TextWrapped = true,
			})
			else nil,
	}) :: Frame
end

return MenuShell
