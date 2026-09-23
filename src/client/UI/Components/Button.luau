--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- Button (P6-2): primary, secondary and danger variants, each with idle,
-- hovered, pressed, disabled and loading states (ComponentLogic ranks
-- them; Base.interactive detects them). Height is the primary-button
-- token; the hit area pads to 44 points on its own.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local ComponentLogic = require(script.Parent.ComponentLogic)
local Env = require(script.Parent.Env)
local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local derive = vide.derive
local show = vide.show

export type Props = {
	label: string | Base.Source<string>,
	onActivate: () -> (),
	variant: ComponentLogic.Variant?,
	icon: string?,
	-- Reference pixels. Defaults to a comfortable single-action width.
	width: number?,
	disabled: (boolean | Base.Source<boolean>)?,
	loading: (boolean | Base.Source<boolean>)?,
	order: number?,
	layoutOrder: number?,
	position: UDim2?,
	anchorPoint: Vector2?,
}

local DEFAULT_WIDTH = Theme.spacing.xxxl * 4 -- 192

local function Button(props: Props): TextButton
	local variant: ComponentLogic.Variant = props.variant or "primary"
	local loading: Base.Source<boolean> = Base.read(props.loading or false)
	local size = Vector2.new(props.width or DEFAULT_WIDTH, Theme.touch.primaryHeight)

	return Base.interactive({
		name = "Button",
		size = size,
		radius = Theme.radius.md,
		disabled = props.disabled,
		loading = loading,
		onActivate = props.onActivate,
		order = props.order,
		layoutOrder = props.layoutOrder,
		position = props.position,
		anchorPoint = props.anchorPoint,
		visual = function(state, _focused)
			local style = derive(function()
				return ComponentLogic.variantStyle(variant, state())
			end)
			local ink = function(): Color3
				return Theme.color[style().ink]
			end
			local fill = Env.animate(function(): Color3
				return Theme.color[style().fill]
			end, Theme.motion.fast)

			return {
				create("Frame")({
					Name = "Surface",
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = fill,
					BackgroundTransparency = function()
						return style().fillTransparency
					end,
					Base.corner(Theme.radius.md),
					create("UIStroke")({
						ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
						Color = function()
							return Theme.color[style().stroke]
						end,
						Transparency = function()
							return style().strokeTransparency
						end,
						Thickness = 1,
					}),
					-- Hover/press brighten through a white overlay.
					create("Frame")({
						Name = "Overlay",
						Size = UDim2.fromScale(1, 1),
						BackgroundColor3 = Color3.new(1, 1, 1),
						BackgroundTransparency = function()
							return style().overlayTransparency
						end,
						ZIndex = 2,
						Base.corner(Theme.radius.md),
					}),
					create("Frame")({
						Name = "Content",
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						ZIndex = 3,
						Visible = function()
							return not loading()
						end,
						Base.padding(Theme.spacing.md),
						create("UIListLayout")({
							FillDirection = Enum.FillDirection.Horizontal,
							HorizontalAlignment = Enum.HorizontalAlignment.Center,
							VerticalAlignment = Enum.VerticalAlignment.Center,
							Padding = UDim.new(0, Theme.spacing.sm),
							SortOrder = Enum.SortOrder.LayoutOrder,
						}),
						(if props.icon then Icons.view(props.icon, Theme.spacing.xl, ink) else nil) :: any,
						Base.text("label", {
							LayoutOrder = 2,
							Size = UDim2.new(1, if props.icon then -(Theme.spacing.xl + Theme.spacing.sm) else 0, 1, 0),
							Text = props.label,
							TextColor3 = ink,
						}),
					}),
					-- Only built while loading, so no spinner ticks otherwise.
					show(loading, function()
						local spinner = Base.spinner(Theme.spacing.xl, ink)
						spinner.ZIndex = 3
						return spinner
					end) :: any,
				}),
			}
		end,
	})
end

return Button
