--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- CurrencyPill (P6-2): a balance, e.g. coins, in a rounded pill. The
-- number counts toward a new value rather than jumping (snaps under
-- reduced motion), and abbreviates past 9,999 via
-- ComponentLogic.formatAmount - which truncates, so the pill never shows
-- more than the player has. With `onActivate` it becomes a button (a
-- "+" opens the store).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local ComponentLogic = require(script.Parent.ComponentLogic)
local Env = require(script.Parent.Env)
local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

export type Props = {
	amount: number | Base.Source<number>,
	icon: string?, -- default "coin"
	onActivate: (() -> ())?,
	order: number?,
	layoutOrder: number?,
	position: UDim2?,
	anchorPoint: Vector2?,
}

local HEIGHT = Theme.spacing.xxl -- 32 visual; hit area pads to 44pt
local WIDTH = Theme.spacing.xxxl * 2 + Theme.spacing.sm -- 104

local function contents(props: Props, state: Base.Source<ComponentLogic.State>?): { Instance }
	local amount: Base.Source<number> = Base.read(props.amount)
	local shown = Env.animate(amount, Theme.motion.slow)
	local hasPlus = props.onActivate ~= nil
	local iconSize = Theme.spacing.xl - Theme.spacing.xs

	return {
		create("Frame")({
			Name = "Surface",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.color.surfaceRaised,
			Base.corner(Theme.radius.pill),
			create("UIStroke")({ ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = Theme.color.line }),
			create("Frame")({
				Name = "Overlay",
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BackgroundTransparency = function()
					return if state then ComponentLogic.variantStyle("secondary", state()).overlayTransparency else 1
				end,
				Base.corner(Theme.radius.pill),
			}),
			create("Frame")({
				Name = "IconSlot",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, Theme.spacing.xs, 0.5, 0),
				Size = UDim2.fromOffset(iconSize, iconSize),
				BackgroundTransparency = 1,
				Icons.view(props.icon or "coin", iconSize, Theme.color.warning),
			}),
			Base.text("label", {
				Name = "Amount",
				Position = UDim2.fromOffset(iconSize + Theme.spacing.sm, 0),
				Size = UDim2.new(
					1,
					-(iconSize + Theme.spacing.sm + (if hasPlus then iconSize else Theme.spacing.sm)),
					1,
					0
				),
				Text = function()
					return ComponentLogic.formatAmount(shown())
				end,
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
			(if hasPlus
				then Base.text("label", {
					Name = "Plus",
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -Theme.spacing.xs, 0.5, 0),
					Size = UDim2.fromOffset(iconSize, iconSize),
					Text = "+",
					TextColor3 = Theme.color.success,
				})
				else nil) :: any,
		}),
	}
end

local function CurrencyPill(props: Props): GuiObject
	local onActivate = props.onActivate
	if onActivate == nil then
		local frame = create("Frame")({
			Name = "CurrencyPill",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(WIDTH, HEIGHT),
			LayoutOrder = props.layoutOrder or 0,
			Position = props.position or UDim2.new(),
			AnchorPoint = props.anchorPoint or Vector2.zero,
		}) :: Frame
		for _, child in contents(props, nil) do
			child.Parent = frame
		end
		return frame
	end
	return Base.interactive({
		name = "CurrencyPill",
		size = Vector2.new(WIDTH, HEIGHT),
		radius = Theme.radius.pill,
		onActivate = onActivate,
		order = props.order,
		layoutOrder = props.layoutOrder,
		position = props.position,
		anchorPoint = props.anchorPoint,
		visual = function(state, _focused)
			return contents(props, state)
		end,
	})
end

return CurrencyPill
