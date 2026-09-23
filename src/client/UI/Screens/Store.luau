--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The store screen (P6-6). Mounted by MenuController.
--
-- DATA:
--   - the catalogue (Config/Store) and the cosmetic/power-up registries:
--     static config, read once.
--   - StoreState: LIVE and targeted - pushed on profile load and after
--     every grant, loadout or equip change. nil until the first push,
--     and the screen shows a loading state rather than guessing what
--     the player owns.
--   - the purchase flow: StoreScreenLogic's reducer, owned by
--     MenuController (it has to outlive a closed screen, since a Roblox
--     prompt can still be open). Fed by StorePurchaseResult, the
--     MarketplaceService prompt-closed signals, and StoreState.
--
-- LAYOUT, top to bottom: category tabs, the item grid (scrolls), and
-- the selected item's panel with the Buy button - pinned at the bottom
-- where the thumb already is. Tapping a card selects it; only the panel
-- buys, so a stray tap while scrolling can never open a prompt.
--
-- Rarity is a coloured edge AND the word, never the colour alone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local StoreScreenLogic = require(script.Parent.Parent.StoreScreenLogic)
local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local MenuShell = require(script.Parent.MenuShell)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local derive = vide.derive
local effect = vide.effect
local indexes = vide.indexes
local values = vide.values
local switch = vide.switch

local TAB_H = 48
local CARD_W = (MenuShell.INNER - Theme.spacing.sm) / 2
local CARD_H = 92
local PANEL_H = 212
local PREVIEW = 72

export type Store = {
	items: { StoreScreenLogic.Item },
	rarityOf: (StoreScreenLogic.Grant) -> string?,
	-- One line per grant ("500 coins", "Founder's Trail"), for the panel.
	grantText: (StoreScreenLogic.Grant) -> string,
	cosmeticName: (cosmeticId: string) -> string,
	state: () -> StoreScreenLogic.StoreState?,
	flow: () -> StoreScreenLogic.Flow,
	buy: (key: string) -> (),
	dismiss: () -> (),
	-- Equip (or, with equip = false, take off) a cosmetic this player owns.
	equip: (cosmeticId: string, equip: boolean) -> (),
	close: () -> (),
}

local CATEGORY_TAB: { [string]: { label: string, icon: string } } = {
	Passes = { label = "Passes", icon = "star" },
	Bundles = { label = "Bundles", icon = "gem" },
	PowerUps = { label = "Power", icon = "bolt" },
	Cosmetics = { label = "Style", icon = "flame" },
	Currency = { label = "Coins", icon = "coin" },
}

-- Keyed by StoreScreenLogic.Rarity. Brand for Rare so it reads as the
-- special one; ink-muted for Common so it doesn't compete.
local RARITY_COLOR: { [string]: string } = { Common = "inkMuted", Uncommon = "success", Rare = "brand" }

local function priceText(item: StoreScreenLogic.Item): string
	return string.format("R$ %d", item.robuxPrice)
end

local function card(
	store: Store,
	item: StoreScreenLogic.Item,
	selected: () -> string?,
	choose: (string) -> ()
): Instance
	local rarity = StoreScreenLogic.rarityOf(item, store.rarityOf)
	local itemState = derive(function()
		return StoreScreenLogic.itemState(item, store.state())
	end)
	local tag = derive(function(): string
		local s = itemState()
		if s == "Owned" or s == "Equipped" then
			return "✓ " .. s
		elseif s == "Unavailable" then
			return "Coming soon"
		end
		return priceText(item)
	end)
	local isSelected = derive(function()
		return selected() == item.key
	end)

	return Base.interactive({
		name = item.key,
		size = Vector2.new(CARD_W, CARD_H),
		onActivate = function()
			choose(item.key)
		end,
		radius = Theme.radius.md,
		visual = function(state)
			return {
				create("Frame")({
					Name = "Fill",
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = function()
						return if state() == "pressed" or isSelected()
							then Theme.color.surfaceRaised
							else Theme.color.surface
					end,
					Base.corner(Theme.radius.md),
					create("UIStroke")({
						ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
						Color = function()
							return if isSelected()
								then Theme.color.focus
								else Theme.color[RARITY_COLOR[rarity or ""] or "line"]
						end,
						Thickness = function()
							return if isSelected() then 3 elseif rarity then 2 else 1
						end,
					}),
					Base.padding(Theme.spacing.sm),
					Base.text("label", {
						Name = "Name",
						Size = UDim2.new(1, 0, 0, 2 * Theme.type.label.size),
						Text = item.displayName,
						TextWrapped = true,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextYAlignment = Enum.TextYAlignment.Top,
					}),
					Base.text("caption", {
						Name = "Rarity",
						AnchorPoint = Vector2.new(0, 1),
						Position = UDim2.new(0, 0, 1, -(Theme.type.body.size + Theme.spacing.xs)),
						Size = UDim2.new(1, 0, 0, Theme.type.caption.size + Theme.spacing.xxs),
						Text = rarity or "",
						TextColor3 = Theme.color[RARITY_COLOR[rarity or ""] or "inkMuted"],
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
					Base.text("body", {
						Name = "Tag",
						AnchorPoint = Vector2.new(0, 1),
						Position = UDim2.fromScale(0, 1),
						Size = UDim2.new(1, 0, 0, Theme.type.body.size + Theme.spacing.xxs),
						Text = tag,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
				}),
			}
		end,
	})
end

-- The buy button's label and state for the selected item, from its
-- ItemState and the purchase flow.
local function buyButton(store: Store, item: () -> StoreScreenLogic.Item?): Instance
	local itemState = derive(function()
		local i = item()
		return if i then StoreScreenLogic.itemState(i, store.state()) else nil
	end)
	local mine = derive(function()
		local i = item()
		local f = store.flow()
		return i ~= nil and f.key == i.key and f.phase ~= "Idle"
	end)
	local busy = derive(function()
		local p = store.flow().phase
		return p == "Requesting" or p == "Prompted" or p == "Processing"
	end)
	local label = derive(function(): string
		local i = item()
		local s = itemState()
		if i == nil or s == nil then
			return "Buy"
		elseif s == "Unavailable" then
			return "Coming soon"
		elseif s == "Owned" or s == "Equipped" then
			return "Owned"
		elseif mine() and store.flow().phase == "Processing" then
			return "Processing..."
		end
		return "Buy · " .. priceText(i)
	end)
	return C.Button({
		label = label,
		variant = "primary",
		icon = "shop",
		width = MenuShell.INNER - 2 * Theme.spacing.md,
		-- Any purchase in flight disables every Buy: one prompt at a time.
		disabled = derive(function()
			return itemState() ~= "Buyable" or (busy() and not mine())
		end),
		loading = derive(function()
			return mine() and busy()
		end),
		onActivate = function()
			local i = item()
			if i then
				store.buy(i.key)
			end
		end,
		order = 100,
		anchorPoint = Vector2.new(0.5, 1),
		position = UDim2.fromScale(0.5, 1),
	})
end

-- One line under the item for a finished or stuck purchase, with a way
-- to clear it. Failed and Delayed show the flow's own message verbatim.
local function flowBanner(store: Store): Instance
	local text = derive(function(): string?
		local f = store.flow()
		if f.phase == "Failed" or f.phase == "Delayed" then
			return f.message
		elseif f.phase == "Succeeded" then
			return "Purchase complete - it's in your inventory."
		end
		return nil
	end)
	local color = derive(function(): Color3
		local p = store.flow().phase
		return if p == "Failed"
			then Theme.color.danger
			elseif p == "Delayed" then Theme.color.warning
			else Theme.color.success
	end)
	local icon = derive(function(): string
		local p = store.flow().phase
		return if p == "Failed" then "⚠ " elseif p == "Delayed" then "… " else "✓ "
	end)
	return create("Frame")({
		Name = "FlowBanner",
		Visible = function()
			return text() ~= nil
		end,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.color.surfaceRaised,
		ZIndex = 5,
		Base.corner(Theme.radius.md),
		Base.padding(Theme.spacing.md),
		create("UIStroke")({ Color = color, Thickness = 2 }),
		Base.text("body", {
			Name = "Message",
			Size = UDim2.new(1, 0, 1, -(Theme.touch.primaryHeight + Theme.spacing.sm)),
			Text = function()
				return icon() .. (text() or "")
			end,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}),
		C.Button({
			label = "OK",
			variant = "secondary",
			width = MenuShell.INNER - 2 * Theme.spacing.md - 2 * Theme.spacing.md,
			onActivate = store.dismiss,
			order = 101,
			anchorPoint = Vector2.new(0.5, 1),
			position = UDim2.fromScale(0.5, 1),
		}),
	})
end

local function panel(store: Store, item: () -> StoreScreenLogic.Item?): Instance
	local rarity = derive(function(): string?
		local i = item()
		return if i then StoreScreenLogic.rarityOf(i, store.rarityOf) else nil
	end)
	local contents = derive(function(): string
		local i = item()
		if i == nil then
			return ""
		end
		local lines = {}
		for _, grant in i.grants do
			table.insert(lines, store.grantText(grant))
		end
		return table.concat(lines, " · ")
	end)
	local targets = derive(function(): { StoreScreenLogic.EquipTarget }
		local i = item()
		local s = store.state()
		if i == nil or s == nil then
			return {}
		end
		local owned = {}
		for _, t in StoreScreenLogic.equipTargets(i, s) do
			if t.owned then
				table.insert(owned, table.freeze(t))
			end
		end
		return owned
	end)

	return C.Panel({
		name = "Selected",
		elevation = 3,
		padding = Theme.spacing.md,
		size = UDim2.fromOffset(MenuShell.INNER, PANEL_H),
		anchorPoint = Vector2.new(0, 1),
		position = UDim2.fromScale(0, 1),
		children = {
			-- Preview. Every sellable item is still a placeholder with no
			-- asset id (enabled = false in config), so there is no model to
			-- put in a ViewportFrame yet; the rarity-edged tile stands in
			-- and docs/menu-screens.md tracks the swap.
			create("Frame")({
				Name = "Preview",
				Size = UDim2.fromOffset(PREVIEW, PREVIEW),
				BackgroundColor3 = Theme.color.background,
				Base.corner(Theme.radius.md),
				create("UIStroke")({
					Color = function()
						return Theme.color[RARITY_COLOR[rarity() or ""] or "line"]
					end,
					Thickness = 2,
				}),
				C.Icons.view("shop", 36, Theme.color.inkMuted),
			}),
			Base.text("title", {
				Name = "Name",
				Position = UDim2.fromOffset(PREVIEW + Theme.spacing.md, 0),
				Size = UDim2.new(1, -(PREVIEW + Theme.spacing.md), 0, Theme.type.title.size + Theme.spacing.xs),
				Text = function()
					local i = item()
					return if i then i.displayName else ""
				end,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			Base.text("caption", {
				Name = "Contents",
				Position = UDim2.fromOffset(PREVIEW + Theme.spacing.md, Theme.type.title.size + Theme.spacing.sm),
				Size = UDim2.new(
					1,
					-(PREVIEW + Theme.spacing.md),
					0,
					PREVIEW - Theme.type.title.size - Theme.spacing.sm
				),
				Text = function()
					local r = rarity()
					return (if r then r .. " · " else "") .. contents()
				end,
				TextColor3 = Theme.color.inkMuted,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
			}),
			-- Equip toggles for cosmetics this item gave the player.
			create("Frame")({
				Name = "Equip",
				Position = UDim2.fromOffset(0, PREVIEW + Theme.spacing.sm),
				Size = UDim2.new(1, 0, 0, Theme.touch.iconButton),
				BackgroundTransparency = 1,
				create("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					Padding = UDim.new(0, Theme.spacing.sm),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				indexes(targets, function(t: () -> StoreScreenLogic.EquipTarget, index: number)
					local count = #targets()
					return C.Button({
						label = derive(function()
							local v = t()
							return (if v.equipped then "Take off " else "Wear ") .. store.cosmeticName(v.cosmeticId)
						end),
						variant = "secondary",
						width = (MenuShell.INNER - 2 * Theme.spacing.md - (count - 1) * Theme.spacing.sm)
							/ math.max(count, 1),
						onActivate = function()
							local v = t()
							store.equip(v.cosmeticId, not v.equipped)
						end,
						order = 90 + index,
						layoutOrder = index,
					})
				end) :: any,
			}),
			buyButton(store, item),
			flowBanner(store),
		},
	})
end

local function body(store: Store, height: () -> number): { Instance }
	local tabIndex = source(1)
	-- Cast: derive widens a string-literal union back to `string`.
	local category = derive(function(): StoreScreenLogic.Category
		return StoreScreenLogic.CATEGORIES[tabIndex()]
	end) :: () -> StoreScreenLogic.Category
	local itemsHere = derive(function()
		return StoreScreenLogic.itemsIn(store.items, category())
	end)
	local selectedKey = source(nil :: string?)
	-- A tab switch selects that tab's first item, so the panel is never
	-- showing something from a tab the player has left.
	effect(function()
		local list = itemsHere()
		selectedKey(if list[1] then list[1].key else nil)
	end)
	local selected = derive(function(): StoreScreenLogic.Item?
		local key = selectedKey()
		for _, item in itemsHere() do
			if item.key == key then
				return item
			end
		end
		return nil
	end)
	local loaded = derive(function()
		return store.state() ~= nil
	end)

	local tabs = {}
	for _, id in StoreScreenLogic.CATEGORIES do
		table.insert(tabs, CATEGORY_TAB[id])
	end

	local gridHeight = derive(function()
		return math.max(0, height() - TAB_H - PANEL_H - 2 * Theme.spacing.sm)
	end)

	local function grid(): Instance
		return create("ScrollingFrame")({
			Name = "Grid",
			Position = UDim2.fromOffset(0, TAB_H + Theme.spacing.sm),
			Size = function()
				return UDim2.fromOffset(MenuShell.INNER, gridHeight())
			end,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 4,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(),
			create("UIGridLayout")({
				CellSize = UDim2.fromOffset(CARD_W, CARD_H),
				CellPadding = UDim2.fromOffset(Theme.spacing.sm, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			-- Keyed by the config item itself: a card is built once per item
			-- shown, and a tab switch swaps whole cards rather than
			-- rewriting one card into another.
			values(itemsHere, function(item: StoreScreenLogic.Item, index: () -> number)
				local c = card(store, item, selectedKey, selectedKey) :: GuiObject
				effect(function()
					c.LayoutOrder = index()
				end)
				return c :: any
			end) :: any,
		})
	end

	return {
		C.TabBar({
			tabs = tabs,
			selected = tabIndex,
			onSelect = tabIndex,
			width = MenuShell.INNER,
			order = 1,
		}),
		switch(loaded)({
			[true] = function()
				return {
					grid(),
					panel(store, selected),
				} :: any
			end,
			[false] = function()
				return MenuShell.message("Loading the store", "Getting your inventory.", true)
			end,
		}) :: any,
	}
end

local Store = {}

function Store.mount(controller: any, store: Store): () -> ()
	return MenuShell.mount(controller, {
		name = "StoreScreen",
		title = "Store",
		trailing = function()
			return C.CurrencyPill({
				amount = function()
					local s = store.state()
					return if s then s.currency else 0
				end,
				order = 0,
			})
		end,
		onClose = store.close,
		body = function(height)
			return body(store, height)
		end,
	})
end

return Store
