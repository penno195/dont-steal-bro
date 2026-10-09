--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- IconButton (P6-2): a square, icon-only button - close, back, settings.
-- Since the UI art pass it's a rounded square on Base.raised, Button's
-- surface with the small lip; the ghost default stays surfaceless at
-- rest, so a full-colour close icon still sits on nothing.
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
	-- Icon edge in reference px. Default Theme.spacing.xl; a full-colour
	-- icon that is itself a button (close-button) fills the whole edge.
	iconSize: number?,
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
	local iconSize = props.iconSize or Theme.spacing.xl
	local ghost = variant == "ghost"

	local button = Base.interactive({
		name = "IconButton",
		size = Vector2.new(edge, edge),
		radius = Theme.radius.lg,
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
			local fill = derive(function(): Theme.Fill
				return Theme.fill[ComponentLogic.fillName(variant, state())]
			end)
			return Base.raised({
				fill = fill,
				-- The ghost has no surface at rest, so nothing to sink onto.
				lip = if ghost then 0 else Theme.lip.small,
				transparency = function()
					return style().fillTransparency
				end,
				radius = Theme.radius.lg,
				gloss = not ghost,
				sunk = function()
					return state() == "pressed"
				end,
				children = {
					create("Frame")({
						Name = "Overlay",
						Size = UDim2.fromScale(1, 1),
						BackgroundColor3 = Color3.new(1, 1, 1),
						BackgroundTransparency = function()
							return style().overlayTransparency
						end,
						ZIndex = 2,
						Base.corner(Theme.radius.lg),
					}),
					create("Frame")({
						Name = "IconSlot",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromOffset(iconSize, iconSize),
						BackgroundTransparency = 1,
						ZIndex = 3,
						Visible = function()
							return not loading()
						end,
						Icons.view(props.icon, iconSize, ink),
					}),
					vide.show(loading, function()
						local spinner = Base.spinner(Theme.spacing.lg, ink)
						spinner.ZIndex = 3
						return spinner
					end) :: any,
				},
			})
		end,
	})
	button.Name = "IconButton_" .. props.label
	return button
end

return IconButton
