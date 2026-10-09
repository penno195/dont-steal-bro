--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The Locker: what the player owns, and what they take into the next
-- race. Mounted by MenuController. design-decisions.md Q8, "the Locker
-- and choosing a loadout", is the brief.
--
-- DATA: StoreState only (live, targeted), the same payload the store
-- reads. nil until the first push, and the screen says it's loading.
-- Practice pickups never appear: they aren't in the profile.
--
-- THREE TABS:
--   Power  the three loadout slots, then the stock grid. Tap a stock
--          tile to add a copy, tap a slot to take it out. Both are free
--          and reversible (stock is spent only at race start), so a tap
--          acts at once, unlike the store, where a tap only selects.
--   Style  owned cosmetics. Tap to wear, tap again to take off.
--   Titles the whole ladder, locked rungs greyed with the streak they
--          need. Tap one to wear it; tap your pick again to go back to
--          wearing your highest (TitleService's default).
--
-- LAYOUT: in landscape the controls sit in the left pane and the grid
-- in the right (MenuShell's split). In portrait they stack, grid last.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local LockerLogic = require(script.Parent.Parent.LockerLogic)
local StoreScreenLogic = require(script.Parent.Parent.StoreScreenLogic)
local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local Icons = require(script.Parent.Parent.Components.Icons)
local MenuShell = require(script.Parent.MenuShell)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local derive = vide.derive
local indexes = vide.indexes
local switch = vide.switch
local show = vide.show

local TAB_H = Theme.touch.primaryHeight -- C.TabBar's height (TabBar.luau HEIGHT)
local SLOT_H = 72
local SLOT_ICON = 32
local CARD_H = 64
local CARD_ICON = 36
local CAPTION_H = 2 * Theme.type.caption.size + Theme.spacing.xs
-- The Power tab's controls above (or beside) the grid: a heading, the
-- slots, the spend note and the "Same as last round" button.
local LOADOUT_H = Theme.type.label.size
	+ Theme.spacing.xs
	+ SLOT_H
	+ Theme.spacing.xs
	+ CAPTION_H
	+ Theme.spacing.xs
	+ Theme.touch.primaryHeight
local STYLE_H = CAPTION_H

export type Locker = {
	state: () -> StoreScreenLogic.StoreState?,
	powerUpIds: { string }, -- every power-up, for the icon switch
	powerUpName: (powerUpId: string) -> string,
	powerUpRarity: (powerUpId: string) -> string?,
	cosmeticName: (cosmeticId: string) -> string,
	cosmeticCategory: (cosmeticId: string) -> string?,
	cosmeticRarity: (cosmeticId: string) -> string?,
	-- Cosmetic categories in the order the Style tab groups them.
	categoryOrder: { string },
	-- Put a power-up in a loadout slot, or take it out with nil.
	setSlot: (slotIndex: number, powerUpId: string?) -> (),
	repeatLast: () -> (),
	equip: (cosmeticId: string, slot: string, wear: boolean) -> (),
	-- The title ladder (config), and each title's name and colour.
	titleLadder: { LockerLogic.TitleDef },
	titleName: (titleId: string) -> string,
	titleColor: (titleId: string) -> Color3,
	-- Wear a title, or nil to go back to the highest rung.
	equipTitle: (titleId: string?) -> (),
	close: () -> (),
}

local TABS: { { label: string, icon: string? } } = {
	{ label = "Power", icon = "bolt" },
	{ label = "Style", icon = "flame" },
	{ label = "Titles", icon = "trophy" },
}

-- Rarity is a coloured edge AND the word, as in the store.
local RARITY_COLOR: { [string]: string } = { Common = "inkMuted", Uncommon = "success", Rare = "brand" }

local BLOCK_TEXT: { [string]: string } = {
	LoadoutFull = "Loadout full",
	AllPlaced = "All in loadout",
}

-- A tile's frame: surface fill, rarity edge, pressed tint. `worn` swaps
-- the edge for the focus colour (a cosmetic being worn): one UIStroke,
-- since Roblox draws only one per object.
local function tileFill(state: () -> string, rarity: () -> string?, children: { any }, worn: (() -> boolean)?): Instance
	local isWorn = worn or function()
		return false
	end
	local props: { [any]: any } = {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Base.STAGE_BACKGROUND,
		Base.stageGradient(function()
			return state() == "pressed"
		end),
		Base.corner(Theme.radius.md),
		create("UIStroke")({
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
			Color = function()
				return if isWorn() then Theme.color.focus else Theme.color[RARITY_COLOR[rarity() or ""] or "line"]
			end,
			Thickness = function()
				return if isWorn() then 3 elseif rarity() then 2 else 1
			end,
		}),
		Base.padding(Theme.spacing.sm),
	}
	for _, child in children do
		table.insert(props, child)
	end
	return create("Frame")(props)
end

-- A power-up icon whose key changes (a slot's item), as RaceHUD's
-- iconFor: one Icons.view per power-up id, switched between.
local function iconFor(
	locker: Locker,
	key: () -> string?,
	size: number,
	color: () -> Color3,
	props: { [string]: any }
): Instance
	local map: { [string]: any } = {}
	for _, id in locker.powerUpIds do
		map[id] = function()
			return Icons.view(id, size, color)
		end
	end
	props.Name = "Icon"
	props.BackgroundTransparency = 1
	props.Size = UDim2.fromOffset(size, size);
	(props :: any)[1] = switch(key)(map)
	return create("Frame")(props)
end

-- ===== Power tab ============================================================

local function slotTile(locker: Locker, slot: () -> LockerLogic.Slot, index: number, width: number): Instance
	local id = derive(function()
		return slot().powerUpId
	end)
	local rarity = derive(function(): string?
		local i = id()
		return if i then locker.powerUpRarity(i) else nil
	end)
	return Base.interactive({
		name = "Slot" .. index,
		size = Vector2.new(width, SLOT_H),
		layoutOrder = index,
		order = index,
		radius = Theme.radius.md,
		disabled = function()
			return id() == nil
		end,
		onActivate = function()
			if id() ~= nil then
				locker.setSlot(index, nil)
			end
		end,
		visual = function(state)
			return {
				tileFill(state, rarity, {
					show(function()
						return id() ~= nil
					end, function()
						return {
							iconFor(locker, id, SLOT_ICON, function()
								return Theme.color.ink
							end, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0) }),
							-- Owned stock always shows its count; a practice item never has one.
							Base.text("caption", {
								Name = "Count",
								AnchorPoint = Vector2.new(1, 0),
								Position = UDim2.fromScale(1, 0),
								Size = UDim2.fromOffset(32, Theme.type.caption.size + Theme.spacing.xxs),
								Text = function()
									return "×" .. slot().stock
								end,
								TextXAlignment = Enum.TextXAlignment.Right,
							}),
							Base.text("caption", {
								Name = "Name",
								AnchorPoint = Vector2.new(0, 1),
								Position = UDim2.fromScale(0, 1),
								Size = UDim2.new(1, 0, 0, Theme.type.caption.size + Theme.spacing.xxs),
								Text = function()
									local i = id()
									return if i then locker.powerUpName(i) else ""
								end,
								TextTruncate = Enum.TextTruncate.AtEnd,
							}),
						} :: any
					end) :: any,
					show(function()
						return id() == nil
					end, function()
						return Base.text("caption", {
							Name = "Empty",
							Size = UDim2.fromScale(1, 1),
							Text = "Empty",
							TextColor3 = Theme.color.inkMuted,
						}) :: any
					end) :: any,
				}),
			}
		end,
	})
end

local function stockCard(locker: Locker, row: () -> LockerLogic.StockRow, index: number, width: number): Instance
	local rarity = derive(function()
		return locker.powerUpRarity(row().powerUpId)
	end)
	local block = derive(function(): string?
		local s = locker.state()
		return if s then LockerLogic.addBlock(s :: any, row()) else "LoadoutFull"
	end)
	local ink = function(): Color3
		return if block() then Theme.color.inkMuted else Theme.color.ink
	end
	return Base.interactive({
		name = "Stock" .. index,
		size = Vector2.new(width, CARD_H),
		layoutOrder = index,
		order = 10 + index,
		radius = Theme.radius.md,
		onActivate = function()
			local s = locker.state()
			if s ~= nil and block() == nil then
				locker.setSlot(LockerLogic.nextSlot(s :: any), row().powerUpId)
			end
		end,
		visual = function(state)
			return {
				tileFill(state, rarity, {
					iconFor(
						locker,
						function()
							return row().powerUpId
						end,
						CARD_ICON,
						ink,
						{
							AnchorPoint = Vector2.new(0, 0.5),
							Position = UDim2.fromScale(0, 0.5),
						}
					),
					Base.text("label", {
						Name = "Name",
						Position = UDim2.fromOffset(CARD_ICON + Theme.spacing.sm, 0),
						Size = UDim2.new(1, -(CARD_ICON + Theme.spacing.sm), 0.5, 0),
						Text = function()
							return locker.powerUpName(row().powerUpId)
						end,
						TextColor3 = ink,
						TextTruncate = Enum.TextTruncate.AtEnd,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
					Base.text("caption", {
						Name = "Detail",
						Position = UDim2.new(0, CARD_ICON + Theme.spacing.sm, 0.5, 0),
						Size = UDim2.new(1, -(CARD_ICON + Theme.spacing.sm), 0.5, 0),
						Text = function()
							local b = block()
							local count = "×" .. row().count
							return if b then count .. " · " .. BLOCK_TEXT[b] else count .. " · " .. (rarity() or "")
						end,
						TextColor3 = function()
							return if block()
								then Theme.color.inkMuted
								else Theme.color[RARITY_COLOR[rarity() or ""] or "inkMuted"]
						end,
						TextTruncate = Enum.TextTruncate.AtEnd,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
				}),
			}
		end,
	})
end

local function loadoutSection(locker: Locker, pane: number, position: UDim2): Instance
	local state = locker.state
	local slots = derive(function(): { LockerLogic.Slot }
		local s = state()
		return if s then LockerLogic.slots(s :: any) else {}
	end)
	local offer = derive(function()
		local s = state()
		return s ~= nil and LockerLogic.repeatOffer(s :: any) ~= nil
	end)
	local slotW = (pane - 2 * Theme.spacing.sm) / 3

	return create("Frame")({
		Name = "Loadout",
		Position = position,
		Size = UDim2.fromOffset(pane, LOADOUT_H),
		BackgroundTransparency = 1,
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, Theme.spacing.xs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Base.text("label", {
			Name = "Heading",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.type.label.size),
			Text = "Next race",
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		create("Frame")({
			Name = "Slots",
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, SLOT_H),
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			indexes(slots, function(slot: () -> LockerLogic.Slot, index: number)
				return slotTile(locker, slot, index, slotW)
			end) :: any,
		}),
		-- Said up front, so losing a round never comes with a surprise.
		Base.text("caption", {
			Name = "SpendNote",
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, CAPTION_H),
			Text = "Used up when the race starts, win or lose. Tap a slot to take it out.",
			TextColor3 = Theme.color.inkMuted,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}),
		show(offer, function()
			return C.Button({
				label = "Same as last round",
				variant = "secondary",
				icon = "bolt",
				width = pane,
				onActivate = locker.repeatLast,
				order = 5,
				layoutOrder = 4,
			}) :: any
		end) :: any,
	})
end

local function grid(name: string, position: UDim2, pane: number, height: () -> number, children: { any }): Instance
	local cardW = (pane - Theme.spacing.sm) / 2
	local props: { [any]: any } = {
		Name = name,
		Position = position,
		Size = function()
			-- One bar wider than the cards: see MenuShell.SCROLLBAR.
			return UDim2.fromOffset(pane + MenuShell.SCROLLBAR, height())
		end,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = MenuShell.SCROLLBAR,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		create("UIGridLayout")({
			CellSize = UDim2.fromOffset(cardW, CARD_H),
			CellPadding = UDim2.fromOffset(Theme.spacing.sm, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for _, child in children do
		table.insert(props, child)
	end
	return create("ScrollingFrame")(props)
end

-- An empty grid's explanation, in the grid's place.
local function emptyState(position: UDim2, pane: number, height: () -> number, title: string, body: string): Instance
	return create("Frame")({
		Name = "Empty",
		Position = position,
		Size = function()
			return UDim2.fromOffset(pane, height())
		end,
		BackgroundTransparency = 1,
		MenuShell.message(title, body),
	})
end

-- ===== Style tab ============================================================

local function cosmeticCard(locker: Locker, row: () -> LockerLogic.CosmeticRow, index: number, width: number): Instance
	local rarity = derive(function()
		return locker.cosmeticRarity(row().cosmeticId)
	end)
	return Base.interactive({
		name = "Cosmetic" .. index,
		size = Vector2.new(width, CARD_H),
		layoutOrder = index,
		order = 10 + index,
		radius = Theme.radius.md,
		disabled = function()
			return row().slot == nil
		end,
		onActivate = function()
			local r = row()
			if r.slot ~= nil then
				locker.equip(r.cosmeticId, r.slot, not r.equipped)
			end
		end,
		visual = function(state)
			return {
				tileFill(state, rarity, {
					Base.text("label", {
						Name = "Name",
						Size = UDim2.fromScale(1, 0.5),
						Text = function()
							return locker.cosmeticName(row().cosmeticId)
						end,
						TextTruncate = Enum.TextTruncate.AtEnd,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
					Base.text("caption", {
						Name = "Detail",
						Position = UDim2.fromScale(0, 0.5),
						Size = UDim2.fromScale(1, 0.5),
						Text = function()
							local r = row()
							if r.equipped then
								return "✓ Wearing"
							end
							return string.format(
								"%s · %s",
								-- "StreakFlair" reads as "Streak Flair".
								(string.gsub(locker.cosmeticCategory(r.cosmeticId) or "", "(%l)(%u)", "%1 %2")),
								rarity() or ""
							)
						end,
						TextColor3 = function()
							return if row().equipped then Theme.color.success else Theme.color.inkMuted
						end,
						TextTruncate = Enum.TextTruncate.AtEnd,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
				}, function()
					return row().equipped
				end),
			}
		end,
	})
end

-- ===== Titles tab ===========================================================

local function titleCard(locker: Locker, row: () -> LockerLogic.TitleRow, index: number, width: number): Instance
	local locked = derive(function()
		return not row().unlocked
	end)
	return Base.interactive({
		name = "Title" .. index,
		size = Vector2.new(width, CARD_H),
		layoutOrder = index,
		order = 10 + index,
		radius = Theme.radius.md,
		disabled = locked,
		onActivate = function()
			local tap = LockerLogic.titleTap(row())
			if tap ~= nil then
				locker.equipTitle(tap.titleId)
			end
		end,
		visual = function(state)
			return {
				tileFill(state, function()
					return nil
				end, {
					Base.text("label", {
						Name = "Name",
						Size = UDim2.fromScale(1, 0.5),
						Text = function()
							return locker.titleName(row().titleId)
						end,
						-- A title's own colour, as on the nametag; muted while locked.
						TextColor3 = function()
							return if locked() then Theme.color.inkMuted else locker.titleColor(row().titleId)
						end,
						TextTruncate = Enum.TextTruncate.AtEnd,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
					Base.text("caption", {
						Name = "Detail",
						Position = UDim2.fromScale(0, 0.5),
						Size = UDim2.fromScale(1, 0.5),
						Text = function()
							local r = row()
							if not r.unlocked then
								return string.format("Locked · best streak %d", r.minStreak)
							elseif r.worn then
								return if r.picked then "✓ Wearing" else "✓ Wearing (your highest)"
							end
							return string.format("Streak %d", r.minStreak)
						end,
						TextColor3 = function()
							return if row().worn then Theme.color.success else Theme.color.inkMuted
						end,
						TextTruncate = Enum.TextTruncate.AtEnd,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
				}, function()
					return row().worn
				end),
			}
		end,
	})
end

-- ===== body =================================================================

local function body(locker: Locker, height: () -> number, layout: MenuShell.BodyLayout): { Instance }
	local pane = layout.pane
	local cardW = (pane - Theme.spacing.sm) / 2
	local tabIndex = source(1)
	local loaded = derive(function()
		return locker.state() ~= nil
	end)

	local stockRows = derive(function(): { LockerLogic.StockRow }
		local s = locker.state()
		return if s then LockerLogic.stock(s :: any, locker.powerUpRarity, locker.powerUpName) else {}
	end)
	local cosmeticRows = derive(function(): { LockerLogic.CosmeticRow }
		local s = locker.state()
		if s == nil then
			return {}
		end
		return LockerLogic.cosmetics(
			s :: any,
			locker.cosmeticCategory,
			StoreScreenLogic.slotFor,
			locker.cosmeticName,
			locker.categoryOrder
		)
	end)
	local titleRows = derive(function(): { LockerLogic.TitleRow }
		local s = locker.state()
		return if s then LockerLogic.titles(s :: any, locker.titleLadder) else {}
	end)

	-- Where the grid goes, given how tall the controls above it are.
	local controlsTop = TAB_H + Theme.spacing.sm
	local function gridPlace(controlsH: number): (UDim2, () -> number)
		if layout.split then
			return UDim2.fromOffset(pane + MenuShell.GUTTER, 0), height
		end
		local top = controlsTop + controlsH + Theme.spacing.sm
		return UDim2.fromOffset(0, top), function()
			return math.max(0, height() - top)
		end
	end

	local function powerTab(): Instance
		local position, gridH = gridPlace(LOADOUT_H)
		return create("Frame")({
			Name = "Power",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			loadoutSection(locker, pane, UDim2.fromOffset(0, controlsTop)),
			switch(derive(function()
				return #stockRows() > 0
			end))({
				[true] = function()
					return grid("Stock", position, pane, gridH, {
						indexes(stockRows, function(row: () -> LockerLogic.StockRow, index: number)
							return stockCard(locker, row, index, cardW)
						end) :: any,
					})
				end,
				[false] = function()
					return emptyState(
						position,
						pane,
						gridH,
						"No power-ups yet",
						"Win in the Decision Studio to earn some, or grab them on the map. Practice pickups stay in the hub."
					)
				end,
			}) :: any,
		})
	end

	local function styleTab(): Instance
		local position, gridH = gridPlace(STYLE_H)
		return create("Frame")({
			Name = "Style",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Base.text("caption", {
				Name = "Hint",
				Position = UDim2.fromOffset(0, controlsTop),
				Size = UDim2.fromOffset(pane, STYLE_H),
				Text = "Tap to wear it. Tap again to take it off.",
				TextColor3 = Theme.color.inkMuted,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
			}),
			switch(derive(function()
				return #cosmeticRows() > 0
			end))({
				[true] = function()
					return grid("Cosmetics", position, pane, gridH, {
						indexes(cosmeticRows, function(row: () -> LockerLogic.CosmeticRow, index: number)
							return cosmeticCard(locker, row, index, cardW)
						end) :: any,
					})
				end,
				[false] = function()
					return emptyState(
						position,
						pane,
						gridH,
						"Nothing to wear yet",
						"Cosmetics you earn or buy show up here."
					)
				end,
			}) :: any,
		})
	end

	local function titlesTab(): Instance
		local position, gridH = gridPlace(STYLE_H)
		return create("Frame")({
			Name = "Titles",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Base.text("caption", {
				Name = "Hint",
				Position = UDim2.fromOffset(0, controlsTop),
				Size = UDim2.fromOffset(pane, STYLE_H),
				Text = "Tap a title to wear it. Tap your pick again to wear your highest.",
				TextColor3 = Theme.color.inkMuted,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
			}),
			grid("Titles", position, pane, gridH, {
				indexes(titleRows, function(row: () -> LockerLogic.TitleRow, index: number)
					return titleCard(locker, row, index, cardW)
				end) :: any,
			}) :: any,
		})
	end

	return {
		C.TabBar({
			tabs = TABS,
			selected = tabIndex,
			onSelect = tabIndex,
			width = pane,
			order = 1,
		}),
		switch(loaded)({
			[true] = function()
				return switch(tabIndex)({
					[1] = powerTab,
					[2] = styleTab,
					[3] = titlesTab,
				}) :: any
			end,
			[false] = function()
				return MenuShell.message("Opening your Locker", "Getting your inventory.", true)
			end,
		}) :: any,
	}
end

local Locker = {}

function Locker.mount(controller: any, locker: Locker): () -> ()
	return MenuShell.mount(controller, {
		name = "LockerScreen",
		title = "Locker",
		onClose = locker.close,
		split = true,
		body = function(height, layout)
			return body(locker, height, layout)
		end,
	})
end

return Locker
