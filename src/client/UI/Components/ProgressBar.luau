--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- ProgressBar (P6-2): a horizontal fill. The fill is a Scale fraction
-- of the track, so the bar is correct at any width the caller gives it.
-- An optional label sits above the track with the value on the right,
-- so progress never relies on the fill colour alone.
--
-- UI art pass: a dark track in the gold rim, and a glossy fill running
-- left to right - gold into pink by default, or a lighter-to-full ramp
-- of the caller's colour.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local ComponentLogic = require(script.Parent.ComponentLogic)
local Env = require(script.Parent.Env)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

export type Props = {
	value: number | Base.Source<number>,
	max: number,
	-- Tokens.color key for the fill; default "primary".
	color: string?,
	label: string?,
	-- Text shown on the right of the label row; default "value/max".
	valueText: (string | Base.Source<string>)?,
	width: number?, -- reference px; default fills the parent
	layoutOrder: number?,
}

local TRACK = Theme.spacing.md -- 12 px tall

local function ProgressBar(props: Props): Frame
	local value: Base.Source<number> = Base.read(props.value)
	local fraction = Env.animate(function()
		return ComponentLogic.fraction(value(), props.max)
	end, Theme.motion.base)
	local fill: Color3? = Theme.color[props.color or "primary"]
	assert(fill ~= nil, "ProgressBar: unknown colour token")
	local ramp = if props.color == nil
		then ColorSequence.new(Theme.fill.primary.top, Theme.color.brand)
		else ColorSequence.new(fill:Lerp(Color3.new(1, 1, 1), 0.3), fill)

	local hasLabel = props.label ~= nil
	local labelRow = Theme.type.caption.size + Theme.spacing.xs
	local valueText: Base.Source<string> = if props.valueText
		then Base.read(props.valueText)
		else function()
			return string.format("%d/%d", math.floor(value()), props.max)
		end

	return create("Frame")({
		Name = "ProgressBar",
		BackgroundTransparency = 1,
		LayoutOrder = props.layoutOrder or 0,
		Size = if props.width
			then UDim2.fromOffset(props.width, TRACK + (if hasLabel then labelRow else 0))
			else UDim2.new(1, 0, 0, TRACK + (if hasLabel then labelRow else 0)),
		(if hasLabel
			then Base.text("caption", {
				Name = "Label",
				Size = UDim2.new(0.7, 0, 0, labelRow - Theme.spacing.xs),
				Text = props.label,
				TextColor3 = Theme.color.inkMuted,
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			else nil) :: any,
		(if hasLabel
			then Base.text("caption", {
				Name = "Value",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0.3, 0, 0, labelRow - Theme.spacing.xs),
				Text = valueText,
				TextXAlignment = Enum.TextXAlignment.Right,
			})
			else nil) :: any,
		create("Frame")({
			Name = "Track",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, TRACK),
			BackgroundColor3 = Theme.color.background,
			Base.corner(Theme.radius.pill),
			create("UIStroke")({
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = Theme.color.rim,
				Thickness = 2,
			}),
			create("Frame")({
				Name = "Fill",
				BackgroundColor3 = Color3.new(1, 1, 1),
				Size = function()
					return UDim2.fromScale(fraction(), 1)
				end,
				Visible = function()
					return fraction() > 0.001
				end,
				Base.corner(Theme.radius.pill),
				create("UIGradient")({ Color = ramp }),
				create("Frame")({
					Name = "Gloss",
					Position = UDim2.fromOffset(Theme.spacing.xs, Theme.spacing.xxs),
					Size = UDim2.new(1, -Theme.spacing.sm, 0.35, 0),
					BackgroundColor3 = Color3.new(1, 1, 1),
					BackgroundTransparency = 0.55,
					Base.corner(Theme.radius.pill),
				}),
			}),
		}),
	}) :: Frame
end

return ProgressBar
