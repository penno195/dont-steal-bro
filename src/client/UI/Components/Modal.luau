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

export type CornerAction = {
	label: string,
	onActivate: () -> (),
}

export type Props = {
	title: string,
	body: string?,
	-- Stacked vertically, first on top: one thumb reaches a full-width
	-- stack more easily than a side-by-side pair on a narrow phone.
	actions: { Action },
	-- Two actions side by side instead (the hub intro's Next / Skip), so
	-- a picture `content` keeps more of the height on a landscape phone.
	actionsInline: boolean?,
	-- A small text-only action in the card's bottom-right corner (the
	-- tutorial welcome's Skip). The actions then sit centred in a row
	-- beside it, each at the width an inline pair would have.
	corner: CornerAction?,
	-- The body's height in lines; 3 if unset. Short copy above a picture
	-- can give a line back to it.
	bodyLines: number?,
	-- Shows a close button, and lets B / tap-outside dismiss.
	dismissible: boolean?,
	onDismiss: (() -> ())?,
	-- Richer content than `body` can hold (P6-8's payoff explainer):
	-- built inside the modal's Vide scope and placed between the body
	-- and the actions. Its width is Modal.CONTENT_WIDTH, and it sizes
	-- its own height - except a ScrollingFrame, whose height `open`
	-- fits to the screen, and an ImageLabel, which it shrinks to fit
	-- (fitToScreen).
	content: (() -> Instance)?,
}

-- The reference phone's width minus a gutter each side, so the card
-- fits the smallest supported screen with the page still visible.
local CARD_WIDTH = 360 - 2 * Theme.spacing.lg
local ACTION_WIDTH = CARD_WIDTH - 2 * Theme.spacing.lg
-- The corner link's visual width: room for a short word like "Skip".
local CORNER_WIDTH = 56

local Modal = {}

Modal.CONTENT_WIDTH = ACTION_WIDTH

-- A 16:9 picture as `content` (the tutorial's step and intro pictures):
-- a Studio screenshot, full content width, shrunk by fitToScreen on a
-- short screen.
function Modal.picture(assetId: number): ImageLabel
	return create("ImageLabel")({
		Name = "Picture",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(ACTION_WIDTH, math.floor(ACTION_WIDTH * 9 / 16)),
		Image = string.format("rbxassetid://%d", assetId),
		ScaleType = Enum.ScaleType.Fit,
		Base.corner(Theme.radius.md),
	}) :: ImageLabel
end

function Modal.card(props: Props): Frame
	local children: { Instance } = {
		Base.text("body", {
			Name = "Body",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.type.body.size * (props.bodyLines or 3)),
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
	local inline = props.actionsInline == true and #props.actions > 1
	local actionWidth = if props.corner
		then (ACTION_WIDTH - Theme.spacing.sm) / 2
		elseif inline then (ACTION_WIDTH - Theme.spacing.sm * (#props.actions - 1)) / #props.actions
		else ACTION_WIDTH
	local buttons: { Instance } = {}
	for i, action in props.actions do
		table.insert(
			buttons,
			Button({
				label = action.label,
				onActivate = action.onActivate,
				variant = action.variant or (if i == 1 then "primary" else "secondary"),
				disabled = action.disabled,
				loading = action.loading,
				width = actionWidth,
				order = i,
				layoutOrder = 10 + i,
			})
		)
	end
	if props.corner then
		-- No layout on the row itself: the buttons centre in a strip of
		-- their own, and the corner link hangs off the right edge.
		local corner = props.corner
		local strip = create("Frame")({
			Name = "Centre",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		for _, button in buttons do
			button.Parent = strip
		end
		local row = create("Frame")({
			Name = "Actions",
			LayoutOrder = 10,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(ACTION_WIDTH, Theme.touch.primaryHeight),
			strip,
			Base.interactive({
				name = "Corner",
				size = Vector2.new(CORNER_WIDTH, Theme.type.body.size + Theme.spacing.sm),
				onActivate = corner.onActivate,
				order = #props.actions + 1,
				anchorPoint = Vector2.new(1, 0.5),
				position = UDim2.fromScale(1, 0.5),
				visual = function()
					return {
						Base.text("body", {
							Size = UDim2.fromScale(1, 1),
							Text = corner.label,
							TextColor3 = Theme.color.inkMuted,
							TextXAlignment = Enum.TextXAlignment.Right,
						}),
					}
				end,
			}),
		})
		table.insert(children, row)
	elseif inline then
		local row = create("Frame")({
			Name = "Actions",
			LayoutOrder = 10,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(ACTION_WIDTH, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		for _, button in buttons do
			button.Parent = row
		end
		table.insert(children, row)
	else
		for _, button in buttons do
			table.insert(children, button)
		end
	end

	local card = create("Frame")({
		Name = "ModalCard",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(CARD_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		-- The UI art pass's stage panel at elevation 3 (see Panel): the
		-- UIGradient tints white, in a thick gold rim.
		BackgroundColor3 = Color3.new(1, 1, 1),
		SelectionGroup = true,
		SelectionBehaviorUp = Enum.SelectionBehavior.Stop,
		SelectionBehaviorDown = Enum.SelectionBehavior.Stop,
		SelectionBehaviorLeft = Enum.SelectionBehavior.Stop,
		SelectionBehaviorRight = Enum.SelectionBehavior.Stop,
		Base.corner(Theme.radius.lg),
		create("UIGradient")({ Rotation = 90, Color = Theme.fill.panel.gradient }),
		create("UIStroke")({
			BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Theme.fill.panel.rim,
			Transparency = Theme.elevation[3].strokeTransparency,
			Thickness = 3,
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
					order = #props.actions + (if props.corner then 2 else 1),
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

-- Keeps the actions on screen. A ScrollingFrame `content` (one child:
-- the body it scrolls) is as tall as its body, up to whatever the
-- screen has left after the card's header, actions and padding; past
-- that it scrolls. Measured from the laid-out card rather than
-- estimated, so a short screen, a notch or a big Text and HUD size
-- can't push "Got it" off the bottom (mobile audit, iPhone portrait).
-- Everything is converted to reference px by the content's own width
-- ratio, which already includes the global and enter-animation scales.
--
-- A picture `content` (an ImageLabel, e.g. a tutorial step's screenshot)
-- shrinks the same way, keeping its shape, so a wide short screen (a
-- landscape phone) keeps the title and "Got it" on screen. Full size is
-- the size it was built at.
--
-- Anything else (the claim pop-up's reward cards) has nothing that can
-- give up height, so the whole card shrinks instead: `fit` scales it,
-- through the enter animation's UIScale, until it fits the screen.
local function fitToScreen(card: Frame, screen: ScreenGui, enter: UIScale, fit: (number) -> ())
	local scroll = card:FindFirstChildWhichIsA("ScrollingFrame")
	local body = scroll and scroll:FindFirstChildWhichIsA("GuiObject")
	local picture = card:FindFirstChildWhichIsA("ImageLabel")
	local fitted: GuiObject? = if scroll ~= nil and body ~= nil then scroll else picture
	if fitted == nil then
		local function refitWhole()
			local scale = enter.Scale
			if scale <= 0 or card.AbsoluteSize.X <= 0 then
				return
			end
			-- The card's height at an enter scale of 1, and the global
			-- scale (screen px per reference px) from its width.
			local natural = card.AbsoluteSize.Y / scale
			local global = card.AbsoluteSize.X / scale / CARD_WIDTH
			local room = screen.AbsoluteSize.Y - 2 * Theme.spacing.lg * global
			fit(math.clamp(room / math.max(natural, 1), 0.5, 1))
		end
		cleanup(card:GetPropertyChangedSignal("AbsoluteSize"):Connect(refitWhole))
		cleanup(screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(refitWhole))
		refitWhole()
		return
	end
	local full = fitted.Size
	local function refit()
		local s = fitted.AbsoluteSize.X / math.max(fitted.Size.X.Offset, 1)
		if s <= 0 then
			return
		end
		local chrome = (card.AbsoluteSize.Y - fitted.AbsoluteSize.Y) / s
		local room = screen.AbsoluteSize.Y / s - 2 * Theme.spacing.lg - chrome
		local size
		if fitted == scroll and body ~= nil then
			local height = math.max(math.min(body.AbsoluteSize.Y / s, room), Theme.touch.primaryHeight * 2)
			size = UDim2.fromOffset(full.X.Offset, height)
		else
			local height = math.max(math.min(full.Y.Offset, room), Theme.touch.primaryHeight)
			size = UDim2.fromOffset(full.X.Offset * height / math.max(full.Y.Offset, 1), height)
		end
		if math.abs(fitted.Size.Y.Offset - size.Y.Offset) > 0.5 then
			fitted.Size = size
		end
	end
	local signals = {
		fitted:GetPropertyChangedSignal("AbsoluteSize"),
		card:GetPropertyChangedSignal("AbsoluteSize"),
		screen:GetPropertyChangedSignal("AbsoluteSize"),
	}
	if body ~= nil and fitted == scroll then
		table.insert(signals, body:GetPropertyChangedSignal("AbsoluteSize"))
	end
	for _, signal in signals do
		cleanup(signal:Connect(refit))
	end
	refit()
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
		--
		-- The holder's height follows the card's measured one rather than
		-- AutomaticSize: through two UIScales Roblox sized it short of the
		-- card (241 vs 321 px for the tutorial reward pop-up), and with the
		-- card hung from its top that pushed the card up off a short screen.
		-- The card is centred in it, so the enter grow and fit stay centred.
		local holder = create("Frame")({
			Name = "ModalHolder",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(CARD_WIDTH, 0),
			BackgroundTransparency = 1,
			Parent = contentGui,
		})
		cleanup(UIScaleController.attachScale(holder))
		local dialog = Modal.card(props)
		dialog.AnchorPoint = Vector2.new(0.5, 0.5)
		dialog.Position = UDim2.fromScale(0.5, 0.5)
		local fit = source(1)
		local enter = create("UIScale")({
			Name = "Enter",
			Scale = Env.animate(function()
				return (if shown() then 1 else 0.92) * fit()
			end, Theme.motion.base),
			Parent = dialog,
		})
		dialog.Parent = holder
		-- The card's height at an enter scale of 1, in the holder's own
		-- (pre-global-scale) px.
		local function syncHolder()
			local global = holder.AbsoluteSize.X / CARD_WIDTH
			local scale = enter.Scale
			if global <= 0 or scale <= 0 then
				return
			end
			local height = dialog.AbsoluteSize.Y / global / scale
			if math.abs(holder.Size.Y.Offset - height) > 0.5 then
				holder.Size = UDim2.fromOffset(CARD_WIDTH, height)
			end
		end
		cleanup(dialog:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncHolder))
		cleanup(holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncHolder))
		syncHolder()
		fitToScreen(dialog, contentGui, enter, function(value: number)
			if math.abs(value - fit()) > 0.01 then
				fit(value)
			end
		end)
		return dialog
	end)

	local inputConn = UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.ButtonB then
			dismiss()
		end
	end)

	shown(true)
	if UIScaleController.getInputMode() == Enum.PreferredInput.Gamepad then
		local actions = card:FindFirstChild("Actions")
		local centre = actions and actions:FindFirstChild("Centre")
		local first = (centre or actions or card):FindFirstChild("Button")
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
