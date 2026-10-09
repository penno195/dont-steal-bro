--!strict
-- The theme UI code requires (P6-1): Tokens.luau's hex values and
-- numbers turned into the Roblox types a GuiObject actually takes.
-- This is the only file that converts; nothing else should call
-- Color3.fromHex on a token.
--
-- Sizes stay plain numbers in REFERENCE pixels (see Tokens.luau
-- "UNITS") - the global UIScale does the per-device multiplication, so
-- a component writes `UDim2.fromOffset(Theme.spacing.lg, ...)` and
-- never multiplies by a scale itself.

local Tokens = require(script.Parent.Tokens)

export type TextStyle = { font: Font, size: number, min: number, outline: boolean }

-- Map views of Tokens' records, for iterating: the solver types a
-- frozen record's values as `unknown` in a generic for loop.
type TextToken = { size: number, min: number, weight: string, family: string }
type FillToken = { top: string, bottom: string, lip: string, rim: string, ink: string }
local fillTokens = Tokens.fill :: { [string]: FillToken }
type ElevationToken = { surface: string, strokeTransparency: number }
local colorTokens = Tokens.color :: { [string]: string }
local radiusTokens = Tokens.radius :: { [string]: number }
local typeTokens = Tokens.type :: { [string]: TextToken }
local elevationTokens = Tokens.elevation :: { ElevationToken }

local Theme = {}

local colors: { [string]: Color3 } = {}
for name, hex in colorTokens do
	colors[name] = Color3.fromHex(hex)
end
Theme.color = table.freeze(colors)

Theme.spacing = Tokens.spacing
Theme.touch = Tokens.touch
Theme.motion = Tokens.motion
Theme.displayOrder = Tokens.displayOrder
Theme.decision = Tokens.decision

local radii: { [string]: UDim } = {}
for name, px in radiusTokens do
	radii[name] = UDim.new(0, px)
end
-- Half the height, whatever the height is: fully round ends.
radii.pill = UDim.new(0.5, 0)
Theme.radius = table.freeze(radii)

-- Two families (architecture.md §5.6: "one or two fonts"). Builder Sans
-- is Roblox's own UI face with the four weights the body styles use;
-- Luckiest Guy is the display face (one weight). Both ship with the
-- client, so no asset load on a slow phone.
local WEIGHT: { [string]: Enum.FontWeight } = {
	Regular = Enum.FontWeight.Regular,
	Medium = Enum.FontWeight.Medium,
	Bold = Enum.FontWeight.Bold,
	ExtraBold = Enum.FontWeight.ExtraBold,
}
local FAMILY: { [string]: Font } = {
	body = Font.fromEnum(Enum.Font.BuilderSans),
	display = Font.fromEnum(Enum.Font.LuckiestGuy),
}

local styles: { [string]: TextStyle } = {}
for name, style in typeTokens do
	local weight = WEIGHT[style.weight]
	assert(weight ~= nil, string.format("Theme: type style %q has unknown weight %q", name, style.weight))
	local family: Font? = FAMILY[style.family]
	assert(family, string.format("Theme: type style %q has unknown family %q", name, style.family))
	local display = style.family == "display"
	styles[name] = table.freeze({
		font = if display then family else Font.new(family.Family, weight),
		size = style.size,
		min = style.min,
		outline = display,
	})
end
Theme.type = table.freeze(styles)

Theme.outline = table.freeze({
	color = colors[Tokens.outline.color],
	thickness = Tokens.outline.thickness,
})

-- Whether display text in `ink` should carry the dark outline: light
-- ink does; dark ink (on a gold or light-green fill) would blur into it.
-- Pass the result as Base.text's `outline` argument.
function Theme.takesOutline(ink: Color3): boolean
	return ink.R * 0.299 + ink.G * 0.587 + ink.B * 0.114 > 0.5
end

-- Gradient fills, converted. `gradient` is the vertical top -> bottom
-- ColorSequence a UIGradient takes (Rotation 90).
export type Fill = { top: Color3, bottom: Color3, lip: Color3, rim: Color3, ink: Color3, gradient: ColorSequence }
local fills: { [string]: Fill } = {}
for name, f in fillTokens do
	local top, bottom = Color3.fromHex(f.top), Color3.fromHex(f.bottom)
	local ink: Color3? = colors[f.ink]
	assert(ink, string.format("Theme: fill %q has unknown ink %q", name, f.ink))
	fills[name] = table.freeze({
		top = top,
		bottom = bottom,
		lip = Color3.fromHex(f.lip),
		rim = Color3.fromHex(f.rim),
		ink = ink,
		gradient = ColorSequence.new(top, bottom),
	})
end
Theme.fill = table.freeze(fills)
Theme.lip = Tokens.lip

export type Elevation = { surface: Color3, strokeTransparency: number }
local levels: { Elevation } = {}
for i, level in elevationTokens do
	levels[i] = table.freeze({
		surface = colors[level.surface],
		strokeTransparency = level.strokeTransparency,
	})
end
Theme.elevation = table.freeze(levels)

-- Applies a text style the way architecture.md §5.6 asks: TextScaled so
-- the label fits its box, bounded by a UITextSizeConstraint so it never
-- shrinks below legible or balloons on a tablet. Reuses an existing
-- constraint so calling it twice doesn't stack them.
function Theme.applyText(label: TextLabel | TextButton | TextBox, styleName: string)
	local style = Theme.type[styleName]
	assert(style ~= nil, string.format("Theme.applyText: no type style %q", styleName))
	-- All three classes share these properties; the solver can't write
	-- through a union, so write through one member's type.
	local target = label :: TextLabel
	target.FontFace = style.font
	target.TextScaled = true
	local constraint = target:FindFirstChildOfClass("UITextSizeConstraint") or Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = style.size
	constraint.MinTextSize = style.min
	constraint.Parent = target
	local outline = target:FindFirstChild("Outline")
	if style.outline then
		local stroke = (outline or Instance.new("UIStroke")) :: UIStroke
		stroke.Name = "Outline"
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		stroke.Color = Theme.outline.color
		stroke.Thickness = Theme.outline.thickness
		stroke.Parent = target
	elseif outline then
		outline:Destroy()
	end
end

return table.freeze(Theme)
