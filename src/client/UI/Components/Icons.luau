--!strict
-- The icon registry (P6-2). Components ask for an icon by KEY, never by
-- asset id, so swapping in real art is a change to this table alone.
--
-- Keys without art yet have `image = nil` and a text `glyph` stand-in,
-- which `Icons.view` draws when there's no image. Fill in `image` (and
-- `rect` for a sprite sheet) per key; no component changes. Glyphs are
-- deliberately distinct shapes, not just distinct colours, like the
-- real icons must be.
--
-- `fullColor` art (from gvesster's Free Icon Pack - commercial use OK,
-- never redistribute the source PNGs) is drawn as-is and ignores the
-- tint a caller passes. Those keys are separate from the tinted
-- `close`/`check`, which Toast and friends colour per state.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

export type Icon = {
	glyph: string,
	image: string?, -- rbxassetid://... once art exists
	rect: Rect?, -- sub-rect in a sprite sheet
	fullColor: boolean?, -- draw the art's own colours, never tinted
}

local ICONS: { [string]: Icon } = {
	-- The decision pair. Keys match Tokens.decision.
	["grab-hand"] = { glyph = "✊", image = "rbxassetid://102273073070888" },
	["open-hands"] = { glyph = "👐", image = "rbxassetid://87993865993222" },

	-- White silhouettes from the pack: tinted per state like a glyph.
	-- (The ✕ glyph isn't in the UI font and drew as a box.)
	close = { glyph = "✕", image = "rbxassetid://122744587536870" },
	back = { glyph = "‹" },
	check = { glyph = "✓", image = "rbxassetid://79957894059133" },
	-- White silhouettes from game-icons.net (CC BY 3.0 - Lorc, Delapouite,
	-- Carl Olsen, Sbed, Zeromancer, DarkZaitzev; credit them in-game).
	lock = { glyph = "🔒", image = "rbxassetid://104226281842552" },
	info = { glyph = "i" },
	warning = { glyph = "!", image = "rbxassetid://94459837108575" },
	coin = { glyph = "¢", image = "rbxassetid://122080278870723" },
	gem = { glyph = "◆", image = "rbxassetid://91124997557663" },
	star = { glyph = "★" },
	settings = { glyph = "⚙", image = "rbxassetid://121595912998780" },
	shop = { glyph = "🛒", image = "rbxassetid://127041926651820" },
	trophy = { glyph = "🏆", image = "rbxassetid://75761907635692" },
	-- A win's item-drop chance on the Studio's stakes. make-ui-icons.ps1.
	gift = { glyph = "🎁", image = "rbxassetid://93505921226948" },
	-- The Locker. Drawn by scripts/make-ui-icons.ps1 (assets/ui/locker.png).
	locker = { glyph = "🎒", image = "rbxassetid://98422090914868" },
	bolt = { glyph = "⚡", image = "rbxassetid://135765129052417" }, -- power-ups
	flame = { glyph = "🔥", image = "rbxassetid://105424020512075" }, -- streak
	shield = { glyph = "⛨", image = "rbxassetid://85964163524838" },
	["shield-reflect"] = { glyph = "⛨", image = "rbxassetid://92508130976489" },

	-- Race HUD (P6-3). Status effect icons are keyed by category, so a
	-- new effect in an existing category needs no new art.
	-- The silhouettes without a pack source are drawn by make-ui-icons.ps1.
	arrow = { glyph = "▲", image = "rbxassetid://120767400257382" }, -- objective compass; rotated, so it must point up
	chevron = { glyph = "⌃", image = "rbxassetid://86275122876329" }, -- objective a floor up (turned 180 for down)
	trash = { glyph = "🗑", image = "rbxassetid://73911474022830" }, -- the power-up discard bin
	down = { glyph = "▼", image = "rbxassetid://107723111049144" }, -- below the qualification line
	pending = { glyph = "○", image = "rbxassetid://91187308390505" }, -- task not done yet
	slow = { glyph = "🐌", image = "rbxassetid://114450983188248" }, -- Movement debuff
	eye = { glyph = "👁", image = "rbxassetid://99292701416698" }, -- Vision debuff
	boost = { glyph = "⏩", image = "rbxassetid://136608479953566" }, -- any buff

	-- Station markers (P7-6).
	rival = { glyph = "👤", image = "rbxassetid://103224537713261" }, -- a rival is working at this station

	-- The Hub's practice party button. Borrows the rival silhouette until
	-- a two-person icon is drawn.
	party = { glyph = "👥", image = "rbxassetid://103224537713261" },

	-- One per power-up, keyed by PowerUpDef.id so a lookup needs no map.
	freeze = { glyph = "❄", image = "rbxassetid://112112451877002" },
	["phase-step"] = { glyph = "👻", image = "rbxassetid://118964136173077" },
	["push-trip"] = { glyph = "🦶", image = "rbxassetid://112836779423376" },
	["second-wind"] = { glyph = "✚", image = "rbxassetid://90962466530359" },
	overclock = { glyph = "⏱", image = "rbxassetid://94894402537890" },
	["task-scramble"] = { glyph = "?", image = "rbxassetid://123237739342553" },
	["task-insight"] = { glyph = "🔍", image = "rbxassetid://84702376814005" },
	["slow-field"] = { glyph = "✺", image = "rbxassetid://112944125272267" },
	["sprint-boost"] = { glyph = "👟", image = "rbxassetid://93563018958820" },
	blind = { glyph = "🙈", image = "rbxassetid://99292701416698" },

	-- Task views. Full-colour art that reads as a button/badge by itself.
	["close-button"] = { glyph = "✕", image = "rbxassetid://84660084127544", fullColor = true },
	["info-button"] = { glyph = "i", image = "rbxassetid://91647157562980", fullColor = true },
	["check-badge"] = { glyph = "✓", image = "rbxassetid://115035144784851", fullColor = true },
	["cross-badge"] = { glyph = "✕", image = "rbxassetid://82032145962986", fullColor = true },
	-- Drawn to match the pack's coins by scripts/make-ui-icons.ps1.
	restart = { glyph = "🔄", image = "rbxassetid://132275802112019", fullColor = true },
}

local Icons = {}

-- Fetch the art up front: an icon first shown mid-task (a socket's
-- check) otherwise pops in a beat after the moment it marks.
do
	local ids = {}
	for _, icon in ICONS do
		if icon.image ~= nil then
			table.insert(ids, icon.image)
		end
	end
	task.spawn(function()
		pcall(ContentProvider.PreloadAsync, ContentProvider, ids)
	end)
end

-- For keys that come from data (a drop's power-up id), so a caller can
-- fall back rather than trip `get`'s assert.
function Icons.has(key: string): boolean
	return ICONS[key] ~= nil
end

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
			ImageColor3 = if icon.fullColor then Color3.new(1, 1, 1) else color,
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

-- A reward's picture that follows its data: the item's own full-colour
-- art (`image`, an asset id) when it has some, else icon `key` tinted
-- `color`. Fills its parent; the caller sizes it. Every key a reward
-- falls back to has real art, so this never needs the glyph stand-in.
function Icons.picture(key: () -> string, image: () -> number?, color: Color3): ImageLabel
	local function fallback(): Icon
		local icon = ICONS[key()]
		return if icon ~= nil and icon.image ~= nil then icon else ICONS.gem
	end
	return create("ImageLabel")({
		Name = "Picture",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ScaleType = Enum.ScaleType.Fit,
		Image = function()
			local id = image()
			return if id ~= nil then string.format("rbxassetid://%d", id) else fallback().image :: string
		end,
		ImageRectOffset = function()
			local rect = if image() == nil then fallback().rect else nil
			return if rect then rect.Min else Vector2.zero
		end,
		ImageRectSize = function()
			local rect = if image() == nil then fallback().rect else nil
			return if rect then rect.Max - rect.Min else Vector2.zero
		end,
		ImageColor3 = function()
			local own = image() ~= nil or fallback().fullColor == true
			return if own then Color3.new(1, 1, 1) else color
		end,
	}) :: ImageLabel
end

return Icons
