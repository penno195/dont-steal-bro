--!strict
-- The icon registry (P6-2). Components ask for an icon by KEY, never by
-- asset id, so swapping in real art is a change to this table alone.
--
-- NO ART EXISTS YET. Every entry has `image = nil` and a text `glyph`
-- stand-in, and `Icons.view` draws the glyph when there's no image.
-- When the atlas is uploaded, fill in `image` (and `rect` for a sprite
-- sheet) per key; no component changes. Glyphs are deliberately
-- distinct shapes, not just distinct colours, like the real icons must be.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

export type Icon = {
	glyph: string,
	image: string?, -- rbxassetid://... once art exists
	rect: Rect?, -- sub-rect in a sprite sheet
}

local ICONS: { [string]: Icon } = {
	-- The decision pair. Keys match Tokens.decision.
	["grab-hand"] = { glyph = "✊" },
	["open-hands"] = { glyph = "👐" },

	close = { glyph = "✕" },
	back = { glyph = "‹" },
	check = { glyph = "✓" },
	lock = { glyph = "🔒" },
	info = { glyph = "i" },
	warning = { glyph = "!" },
	coin = { glyph = "¢" },
	gem = { glyph = "◆" },
	star = { glyph = "★" },
	settings = { glyph = "⚙" },
	shop = { glyph = "🛒" },
	trophy = { glyph = "🏆" },
	bolt = { glyph = "⚡" }, -- power-ups
	flame = { glyph = "🔥" }, -- streak
}

local Icons = {}

function Icons.get(key: string): Icon
	local icon = ICONS[key]
	assert(icon ~= nil, string.format("Icons: no icon %q", key))
	return icon
end

-- A square icon `size` reference pixels on a side, tinted `color`.
-- Real art is an ImageLabel; the stand-in is a TextLabel with the glyph.
function Icons.view(key: string, size: number, color: Color3 | () -> Color3): GuiObject
	local icon = Icons.get(key)
	if icon.image ~= nil then
		return create("ImageLabel")({
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(size, size),
			Image = icon.image,
			ImageRectOffset = if icon.rect then icon.rect.Min else Vector2.zero,
			ImageRectSize = if icon.rect then icon.rect.Max - icon.rect.Min else Vector2.zero,
			ImageColor3 = color,
			ScaleType = Enum.ScaleType.Fit,
		}) :: ImageLabel
	end
	return create("TextLabel")({
		Name = "Icon",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Text = icon.glyph,
		TextColor3 = color,
		FontFace = Theme.type.label.font,
		TextScaled = true,
	}) :: TextLabel
end

return Icons
