--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- IconButton (P6-2): a square, icon-only button - close, back, settings.
-- The visual is the `iconButton` token (44 at scale 1); at the 0.75
-- scale floor the hit area pads to 59 reference px so it still renders
-- at 44 points while the icon stays put.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local ComponentLogic = require(script.Parent.ComponentLogic)
local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local derive = vide.derive

export type Props = {
	icon: string,
	-- What the button does, e.g. "Close". Shown nowhere yet (Roblox has
	-- no screen-reader label), but names the instance for debugging and
	-- is the string a future tooltip/accessibility pass will read.
	label: string,
	onActivate: () -> (),
	variant: ComponentLogic.Variant?, -- default "ghost"
	disabled: (boolean | Base.Source<boolean>)?,
	loading: (boolean | Base.Source<boolean>)?,
	order: number?,
	layoutOrder: number?,
	position: UDim2?,
	anchorPoint: Vector2?,
}

local function IconButton(props: Props): TextButton
	local variant: ComponentLogic.Variant = props.variant or "ghost"
	local loading: Base.Source<boolean> = Base.read(props.loading or false)
	local edge = Theme.touch.iconButton

	local button = Base.interactive({
		name = "IconButton",
		size = Vector2.new(edge, edge),
		radius = Theme.radius.pill,
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
			return {
				create("Frame")({
					Name = "Surface",
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = function()
						return Theme.color[style().fill]
					end,
					BackgroundTransparency = function()
						return style().fillTransparency
					end,
					Base.corner(Theme.radius.pill),
					create("Frame")({
						Name = "Overlay",
						Size = UDim2.fromScale(1, 1),
						BackgroundColor3 = Color3.new(1, 1, 1),
						BackgroundTransparency = function()
							return style().overlayTransparency
						end,
						Base.corner(Theme.radius.pill),
					}),
					create("Frame")({
						Name = "IconSlot",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromOffset(Theme.spacing.xl, Theme.spacing.xl),
						BackgroundTransparency = 1,
						Visible = function()
							return not loading()
						end,
						Icons.view(props.icon, Theme.spacing.xl, ink),
					}),
					vide.show(loading, function()
						return Base.spinner(Theme.spacing.lg, ink)
					end) :: any,
				}),
			}
		end,
	})
	button.Name = "IconButton_" .. props.label
	return button
end

return IconButton
