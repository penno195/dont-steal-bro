--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- Modal (P6-2): a dialog over a dimmed backdrop.
--
--   Modal.card(props)  the dialog itself, as a plain Frame - what the
--                      gallery shows inline, and what `open` centres.
--   Modal.open(props)  puts it on screen and returns `close`.
--
-- Two ScreenGuis (docs/ui-foundation.md "Safe areas"): the scrim is
-- full-bleed so the dim covers the notch strip too; the card and the
-- tap-outside catcher live on a safe-area screen one band above it, so
-- nothing tappable sits under a cutout.
--
-- Focus is trapped: the card is a SelectionGroup that stops at every
-- edge, so a gamepad can't wander onto the HUD behind the dialog.
-- Opening on a gamepad selects the first action; closing restores
-- whatever was selected before. B dismisses when `dismissible`.
--
-- One modal at a time: opening a second replaces the first's screens
-- (createScreen reuses the name). Stacked dialogs are a UX smell on a
-- phone anyway; chain them instead.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local Button = require(script.Parent.Button)
local Env = require(script.Parent.Env)
local IconButton = require(script.Parent.IconButton)
local Theme = require(script.Parent.Parent.Theme)
local UIScaleController = require(script.Parent.Parent.Parent.Controllers.UIScaleController)

local cleanup = vide.cleanup
local create = vide.create
local source = vide.source

export type Action = {
	label: string,
	onActivate: () -> (),
	variant: ("primary" | "secondary" | "danger")?,
	disabled: (boolean | Base.Source<boolean>)?,
	loading: (boolean | Base.Source<boolean>)?,
}

export type Props = {
	title: string,
	body: string?,
	-- Stacked vertically, first on top: one thumb reaches a full-width
	-- stack more easily than a side-by-side pair on a narrow phone.
	actions: { Action },
	-- Shows a close button, and lets B / tap-outside dismiss.
	dismissible: boolean?,
	onDismiss: (() -> ())?,
	-- Richer content than `body` can hold (P6-8's payoff explainer):
	-- built inside the modal's Vide scope and placed between the body
	-- and the actions. Its width is Modal.CONTENT_WIDTH, and it sizes
	-- its own height.
	content: (() -> Instance)?,
}

-- The reference phone's width minus a gutter each side, so the card
-- fits the smallest supported screen with the page still visible.
local CARD_WIDTH = 360 - 2 * Theme.spacing.lg
local ACTION_WIDTH = CARD_WIDTH - 2 * Theme.spacing.lg

local Modal = {}

Modal.CONTENT_WIDTH = ACTION_WIDTH

function Modal.card(props: Props): Frame
	local children: { Instance } = {
		Base.text("body", {
			Name = "Body",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.type.body.size * 3),
			Text = props.body or "",
			Visible = props.body ~= nil,
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}),
	}
	if props.content then
		local content = props.content() :: GuiObject
		content.LayoutOrder = 2
		table.insert(children, content)
	end
	for i, action in props.actions do
		table.insert(
			children,
			Button({
				label = action.label,
				onActivate = action.onActivate,
				variant = action.variant or (if i == 1 then "primary" else "secondary"),
				disabled = action.disabled,
				loading = action.loading,
				width = ACTION_WIDTH,
				order = i,
				layoutOrder = 10 + i,
			})
		)
	end

	local card = create("Frame")({
		Name = "ModalCard",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(CARD_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.elevation[3].surface,
		SelectionGroup = true,
		SelectionBehaviorUp = Enum.SelectionBehavior.Stop,
		SelectionBehaviorDown = Enum.SelectionBehavior.Stop,
		SelectionBehaviorLeft = Enum.SelectionBehavior.Stop,
		SelectionBehaviorRight = Enum.SelectionBehavior.Stop,
		Base.corner(Theme.radius.lg),
		create("UIStroke")({
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Theme.color.line,
			Transparency = Theme.elevation[3].strokeTransparency,
		}),
		Base.padding(Theme.spacing.lg),
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.md),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
		create("Frame")({
			Name = "Header",
			LayoutOrder = 0,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, Theme.touch.iconButton),
			Base.text("title", {
				Size = UDim2.new(1, -(Theme.touch.iconButton + Theme.spacing.sm), 1, 0),
				Text = props.title,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			(if props.dismissible and props.onDismiss
				then IconButton({
					icon = "close",
					label = "Close",
					onActivate = props.onDismiss,
					order = #props.actions + 1,
					anchorPoint = Vector2.new(1, 0.5),
					position = UDim2.fromScale(1, 0.5),
				})
				else nil) :: any,
		}),
	}) :: Frame
	for _, child in children do
		child.Parent = card
	end
	return card
end

-- Shows the modal. Returns `close`, which animates it out and cleans up;
-- safe to call more than once. Dismissal (close button, B, tapping
-- outside) calls `props.onDismiss` - the caller decides whether that
-- closes it, so a dismiss can be refused (e.g. mid-purchase).
function Modal.open(props: Props): () -> ()
	local previousSelection = GuiService.SelectedObject
	local closed = false
	local shown = source(false)

	local scrimGui = UIScaleController.createScreen("ModalScrim", {
		displayOrder = Theme.displayOrder.modal,
		fullBleed = true,
	})
	local contentGui = UIScaleController.createScreen("Modal", {
		displayOrder = Theme.displayOrder.modal + 1,
	})

	local function dismiss()
		if props.dismissible and props.onDismiss then
			props.onDismiss()
		end
	end

	local destroyRoot, card = vide.root(function()
		create("Frame")({
			Name = "Scrim",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.color.scrim,
			BackgroundTransparency = Env.animate(function()
				return if shown() then 0.45 else 1
			end, Theme.motion.base),
			Parent = scrimGui,
		})
		-- Tap-outside catcher. On the safe-area screen, not the scrim.
		create("TextButton")({
			Name = "Outside",
			Text = "",
			AutoButtonColor = false,
			Selectable = false,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Activated = dismiss,
			Parent = contentGui,
		})
		-- A GuiObject honours one UIScale, so the global scale goes on a
		-- holder and the enter animation (a small grow) on the card.
		local holder = create("Frame")({
			Name = "ModalHolder",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(CARD_WIDTH, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = contentGui,
		})
		cleanup(UIScaleController.attachScale(holder))
		local dialog = Modal.card(props)
		create("UIScale")({
			Name = "Enter",
			Scale = Env.animate(function()
				return if shown() then 1 else 0.92
			end, Theme.motion.base),
			Parent = dialog,
		})
		dialog.Parent = holder
		return dialog
	end)

	local inputConn = UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.ButtonB then
			dismiss()
		end
	end)

	shown(true)
	if UIScaleController.getInputMode() == Enum.PreferredInput.Gamepad then
		local first = card:FindFirstChild("Button")
		if first and first:IsA("GuiObject") then
			GuiService.SelectedObject = first
		end
	end

	return function()
		if closed then
			return
		end
		closed = true
		inputConn:Disconnect()
		shown(false)
		task.delay(Env.duration(Theme.motion.base), function()
			destroyRoot()
			scrimGui:Destroy()
			contentGui:Destroy()
			if previousSelection and previousSelection:IsDescendantOf(game) then
				GuiService.SelectedObject = previousSelection
			end
		end)
	end
end

return Modal
