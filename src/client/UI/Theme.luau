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

export type TextStyle = { font: Font, size: number, min: number }

-- Map views of Tokens' records, for iterating: the solver types a
-- frozen record's values as `unknown` in a generic for loop.
type TextToken = { size: number, min: number, weight: string }
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

-- One family (architecture.md §5.6: "one or two fonts"). Builder Sans
-- is Roblox's own UI face, ships with the client (no asset load on a
-- slow phone), and has the four weights the type scale uses.
local WEIGHT: { [string]: Enum.FontWeight } = {
	Regular = Enum.FontWeight.Regular,
	Medium = Enum.FontWeight.Medium,
	Bold = Enum.FontWeight.Bold,
	ExtraBold = Enum.FontWeight.ExtraBold,
}
local BASE_FONT = Font.fromEnum(Enum.Font.BuilderSans)

local styles: { [string]: TextStyle } = {}
for name, style in typeTokens do
	local weight = WEIGHT[style.weight]
	assert(weight ~= nil, string.format("Theme: type style %q has unknown weight %q", name, style.weight))
	styles[name] = table.freeze({
		font = Font.new(BASE_FONT.Family, weight),
		size = style.size,
		min = style.min,
	})
end
Theme.type = table.freeze(styles)

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
end

return table.freeze(Theme)
