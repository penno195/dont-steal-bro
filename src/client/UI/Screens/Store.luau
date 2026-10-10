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
local TweenService = game:GetService("TweenService")

local vide = require(ReplicatedStorage.Packages.Vide)

local StoreScreenLogic = require(script.Parent.Parent.StoreScreenLogic)
local SeasonTrackLogic = require(script.Parent.Parent.SeasonTrackLogic)
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
local untrack = vide.untrack

local TAB_H = Theme.touch.primaryHeight -- C.TabBar's height (TabBar.luau HEIGHT)
local CARD_H = 92
local PANEL_H = 212
local PREVIEW = 72
local CARD_IMAGE = 48 -- the item picture, top-right of a card; the name wraps beside it

export type Store = {
	items: { StoreScreenLogic.Item },
	-- The tab it opens on; nil = the first. The hub's coin balance opens
	-- straight on "Currency".
	initialCategory: StoreScreenLogic.Category?,
	-- The item it opens on, overriding initialCategory: a hub plinth
	-- opens the store on what it shows. Ignored if it isn't listed.
	initialKey: string?,
	-- StoreOffers.isOffered on the synced server clock: what's on sale
	-- right now. The server refuses anything else regardless.
	isOffered: (StoreScreenLogic.Item) -> boolean,
	-- What an item costs now, and its struck-through "was" price.
	priceOf: (StoreScreenLogic.Item) -> StoreScreenLogic.Price,
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
	-- The Season tab: the live season's track as rows, nil when none is
	-- running, and a season id's pass key from config.
	seasonView: () -> SeasonTrackLogic.View?,
	passKeyOf: (seasonId: string) -> string?,
	-- Claim season rewards: one row up to a tile's list position, or
	-- (both nil) Claim All. An intent; the server decides what pays.
	claim: (track: ("Free" | "Premium")?, upTo: number?) -> (),
	close: () -> (),
}

local CATEGORY_TAB: { [string]: { label: string, icon: string } } = {
	Season = { label = "Season", icon = "star" },
	Bundles = { label = "Bundles", icon = "gem" },
	PowerUps = { label = "Power", icon = "bolt" },
	Cosmetics = { label = "Style", icon = "flame" },
	Currency = { label = "Coins", icon = "coin" },
}

-- Keyed by StoreScreenLogic.Rarity. Brand for Rare so it reads as the
-- special one; ink-muted for Common so it doesn't compete.
local RARITY_COLOR: { [string]: string } = { Common = "inkMuted", Uncommon = "success", Rare = "brand" }

local function priceText(store: Store, item: StoreScreenLogic.Item): string
	return StoreScreenLogic.priceText(item, store.priceOf(item))
end

-- An item's picture (StoreItemDef.imageAssetId), drawn in its own
-- colours. `item` may be a source (the panel's selection). An item with
-- no art yet (0, disabled only) shows nothing; the card's rarity edge
-- and name still read.
local function itemImage(
	item: StoreScreenLogic.Item? | () -> StoreScreenLogic.Item?,
	size: number,
	props: { [string]: any }
): Instance
	local get: () -> StoreScreenLogic.Item? = if type(item) == "function"
		then item
		else function()
			return item :: StoreScreenLogic.Item?
		end
	props.Name = "Image"
	props.BackgroundTransparency = 1
	props.Size = UDim2.fromOffset(size, size)
	props.ScaleType = Enum.ScaleType.Fit
	props.Image = function()
		local i = get()
		return if i and i.imageAssetId ~= 0 then "rbxassetid://" .. i.imageAssetId else ""
	end
	(props :: any)[1] = Base.corner(Theme.radius.md)
	return create("ImageLabel")(props)
end

local function card(
	store: Store,
	item: StoreScreenLogic.Item,
	selected: () -> string?,
	choose: (string) -> (),
	cardW: number
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
		elseif s == "TooFewCoins" then
			return "Need " .. priceText(store, item)
		end
		return StoreScreenLogic.priceRich(item, store.priceOf(item))
	end)
	-- A sale reads as the word, not just the struck-through price.
	local onSale = derive(function()
		return store.priceOf(item).was ~= nil
	end)
	local isSelected = derive(function()
		return selected() == item.key
	end)

	return Base.interactive({
		name = item.key,
		size = Vector2.new(cardW, CARD_H),
		onActivate = function()
			choose(item.key)
		end,
		radius = Theme.radius.md,
		visual = function(state)
			return {
				create("Frame")({
					Name = "Fill",
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = Base.STAGE_BACKGROUND,
					Base.stageGradient(function()
						return state() == "pressed" or isSelected()
					end),
					Base.corner(Theme.radius.md),
					create("UIStroke")({
						ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
						BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
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
					itemImage(item, CARD_IMAGE, {
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
					}),
					Base.text("label", {
						Name = "Name",
						Size = UDim2.new(1, -(CARD_IMAGE + Theme.spacing.xs), 0, 2 * Theme.type.label.size),
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
					Base.text("caption", {
						Name = "Sale",
						AnchorPoint = Vector2.new(1, 1),
						Position = UDim2.new(1, 0, 1, -(Theme.type.body.size + Theme.spacing.xs)),
						Size = UDim2.new(0.5, 0, 0, Theme.type.caption.size + Theme.spacing.xxs),
						Text = "SALE",
						TextColor3 = Theme.color.warning,
						TextXAlignment = Enum.TextXAlignment.Right,
						Visible = onSale,
					}),
					Base.text("body", {
						Name = "Tag",
						AnchorPoint = Vector2.new(0, 1),
						Position = UDim2.fromScale(0, 1),
						Size = UDim2.new(1, 0, 0, Theme.type.body.size + Theme.spacing.xxs),
						RichText = true,
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
local function buyButton(store: Store, item: () -> StoreScreenLogic.Item?, pane: number): Instance
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
		elseif s == "TooFewCoins" then
			return "Need " .. priceText(store, i)
		elseif s == "Owned" or s == "Equipped" then
			return "Owned"
		elseif mine() and store.flow().phase == "Processing" then
			return "Processing..."
		end
		return "Buy · " .. priceText(store, i)
	end)
	return C.Button({
		label = label,
		variant = "primary",
		icon = "shop",
		width = pane - 2 * Theme.spacing.md,
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
local function flowBanner(store: Store, pane: number): Instance
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
		BackgroundColor3 = Base.STAGE_BACKGROUND,
		ZIndex = 5,
		Base.corner(Theme.radius.md),
		Base.padding(Theme.spacing.md),
		Base.stage({ rim = color, thickness = 3 }),
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
			width = pane - 2 * Theme.spacing.md - 2 * Theme.spacing.md,
			onActivate = store.dismiss,
			order = 101,
			anchorPoint = Vector2.new(0.5, 1),
			position = UDim2.fromScale(0.5, 1),
		}),
	})
end

-- Claim All, on the season pass's panel (user decision 2026-10-09): pays
-- everything reached on both rows. It sits in the row the Equip buttons
-- use, which a pass never fills.
local function claimAllButton(store: Store, item: () -> StoreScreenLogic.Item?, pane: number): Instance
	local count = derive(function(): number?
		local i = item()
		local season = store.seasonView()
		if i == nil or season == nil or not StoreScreenLogic.isSeasonPass(i) then
			return nil
		end
		return season.free.claimable + season.premium.claimable
	end)
	return create("Frame")({
		Name = "ClaimAll",
		Position = UDim2.fromOffset(0, PREVIEW + Theme.spacing.sm),
		Size = UDim2.new(1, 0, 0, Theme.touch.iconButton),
		BackgroundTransparency = 1,
		Visible = function()
			return count() ~= nil
		end,
		C.Button({
			label = derive(function()
				local n = count() or 0
				return if n > 0 then string.format("Claim all · %d", n) else "Nothing to claim"
			end),
			variant = "secondary",
			icon = "gift",
			compact = true,
			width = pane - 2 * Theme.spacing.md,
			disabled = derive(function()
				return (count() or 0) == 0
			end),
			onActivate = function()
				store.claim(nil, nil)
			end,
			order = 95,
		}),
	})
end

local function panel(store: Store, item: () -> StoreScreenLogic.Item?, layout: MenuShell.BodyLayout): Instance
	local pane = layout.pane
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
			-- The pass names the season it unlocks: the Season tab's strip
			-- has no room for a heading of its own.
			local season = if grant.kind == "SeasonPass" then store.seasonView() else nil
			if season then
				local wins = math.max(season.free.wins, season.premium.wins)
				table.insert(lines, string.format("%s · %d wins so far · %s", season.name, wins, season.timeLeft))
			else
				table.insert(lines, store.grantText(grant))
			end
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
		size = UDim2.fromOffset(pane, PANEL_H),
		-- Under the grid, or beside it when split (MenuShell).
		anchorPoint = if layout.split then Vector2.zero else Vector2.new(0, 1),
		position = if layout.split then UDim2.fromOffset(pane + MenuShell.GUTTER, 0) else UDim2.fromScale(0, 1),
		children = {
			-- Preview: the item's picture on a rarity-edged tile. A
			-- cosmetic still has no 3D ViewportFrame preview;
			-- docs/menu-screens.md tracks that.
			create("Frame")({
				Name = "Preview",
				Size = UDim2.fromOffset(PREVIEW, PREVIEW),
				BackgroundColor3 = Theme.color.background,
				Base.corner(Theme.radius.md),
				create("UIStroke")({
					BorderStrokePosition = Enum.BorderStrokePosition.Inner,
					Color = function()
						return Theme.color[RARITY_COLOR[rarity() or ""] or "line"]
					end,
					Thickness = 2,
				}),
				itemImage(item, PREVIEW, {}),
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
				-- On sale, it opens with the struck-through "was" price.
				RichText = true,
				Text = function()
					local i = item()
					local r = rarity()
					local was = if i then store.priceOf(i).was else nil
					local sale = if i and was
						then string.format(
							'<font color="#%s">SALE</font> <s>%s</s> · ',
							Theme.color.warning:ToHex(),
							StoreScreenLogic.priceText(i, { now = was })
						)
						else ""
					return sale .. (if r then r .. " · " else "") .. contents()
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
						width = (pane - 2 * Theme.spacing.md - (count - 1) * Theme.spacing.sm) / math.max(count, 1),
						onActivate = function()
							local v = t()
							store.equip(v.cosmeticId, not v.equipped)
						end,
						order = 90 + index,
						layoutOrder = index,
					})
				end) :: any,
			}),
			claimAllButton(store, item, pane),
			buyButton(store, item, pane),
			flowBanner(store, pane),
		},
	})
end

-- ===== the Season tab (rewards-roadmap.md step 5b, next-stages.md 1a) ======
-- The owner's battle-pass reference: tiers left to right, the gold PAID
-- PASS row on top and the blue FREE PASS row below, each headed by a
-- fixed card. A tile is a raised surface carrying its win count in a tab
-- at the top and its status in a banner at the bottom. A reward the
-- player can claim turns the whole tile into its Claim button (user
-- decision 2026-10-09); Claim All and the pass itself live in the panel.
--
-- The strip swipes sideways on touch (a ScrollingFrame does that
-- natively) and steps a page at a time from the round arrows over its
-- edges; the slim indicator under it shows where you are. No native
-- scrollbar.

local GUTTER_W = 76 -- the two row cards left of the strip
local COLUMN_W = 88
local STRIDE = COLUMN_W + Theme.spacing.sm
local CHIP_H = 20 -- the wins tab and the status banner
local NAME_H = Theme.type.caption.size + Theme.spacing.xxs
local CORNER_ICON = 16
local TILE_MIN = 72
local LIP = Theme.lip.small
local INDICATOR_H = 6
local INDICATOR_ROW = INDICATOR_H + 2 * Theme.spacing.xs
local ARROW = 40

-- Stands in for an empty slot (a tier only the other row pays at), so a
-- hidden tile's bindings never read nil.
local EMPTY_ROW: SeasonTrackLogic.Row =
	{ index = 0, wins = 0, text = "", status = "Locked", icon = "gem", reached = false }

-- A row's fill with another rim: the tile's state shows in its rim.
local function withRim(fill: Theme.Fill, rim: Color3): Theme.Fill
	return { top = fill.top, bottom = fill.bottom, lip = fill.lip, rim = rim, ink = fill.ink, gradient = fill.gradient }
end

type Banner = { text: string, back: Color3, ink: Color3, icon: string? }

-- The banner: status is a word as well as a colour.
local function banner(row: SeasonTrackLogic.Row, passLocked: boolean): Banner
	if row.status == "Claimable" then
		return { text = "CLAIM", back = Theme.color.share, ink = Theme.color.onShare }
	elseif row.status == "Claimed" then
		return { text = "CLAIMED", back = Theme.color.outline, ink = Theme.color.success, icon = "check" }
	elseif row.status == "Next" then
		return { text = "NEXT", back = Theme.color.outline, ink = Theme.color.primary }
	elseif passLocked and row.reached then
		-- Buying the pass makes this one claimable at once.
		return { text = "REACHED", back = Theme.color.outline, ink = Theme.color.primary, icon = "lock" }
	end
	return {
		text = "LOCKED",
		back = Theme.color.outline,
		ink = Theme.color.ink,
		icon = if passLocked then "lock" else nil,
	}
end

-- Display-face text that carries the dark outline only on light ink
-- (Theme.takesOutline), whatever colour `ink` turns.
local function displayText(props: { [any]: any }, ink: () -> Color3): TextLabel
	props.TextColor3 = ink
	local label = Base.text("button", props, true)
	local outline = label:FindFirstChild("Outline") :: UIStroke?
	if outline then
		effect(function()
			outline.Enabled = Theme.takesOutline(ink())
		end)
	end
	return label
end

-- A pill across the tile, for the wins tab (top) and the banner (bottom).
local function chip(name: string, anchorY: number, back: () -> Color3, text: () -> string, ink: () -> Color3): Instance
	return create("Frame")({
		Name = name,
		AnchorPoint = Vector2.new(0, anchorY),
		Position = UDim2.fromScale(0, anchorY),
		Size = UDim2.new(1, 0, 0, CHIP_H),
		BackgroundColor3 = back,
		ZIndex = 4, -- over a claimed tile's dimming
		Base.corner(Theme.radius.sm),
		displayText({
			Size = UDim2.new(1, -Theme.spacing.xs, 1, -Theme.spacing.xxs),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Text = text,
			ZIndex = 4,
		}, ink),
	})
end

-- One view per icon key, for a switch: the corner icon and the item icon
-- change with the row.
local function iconViews(keys: { string }, build: (key: string) -> GuiObject): { [string]: () -> Instance }
	local views = {}
	for _, key in keys do
		views[key] = function(): Instance
			return build(key)
		end
	end
	return views
end

local function tile(
	get: () -> SeasonTrackLogic.Row?,
	isPremium: boolean,
	passLocked: () -> boolean,
	tileH: () -> number,
	order: number,
	claim: (row: SeasonTrackLogic.Row) -> ()
): Instance
	local row = derive(function(): SeasonTrackLogic.Row
		return get() or EMPTY_ROW
	end)
	local shown = derive(function()
		return get() ~= nil
	end)
	local claimable = derive(function()
		return shown() and row().status == "Claimable"
	end)
	local status = derive(function()
		return banner(row(), isPremium and passLocked())
	end)
	local base = if isPremium then Theme.fill.seasonPaid else Theme.fill.seasonFree
	local rims = {
		Next = withRim(base, Theme.color.focus),
		Claimable = withRim(base, Theme.fill.share.top),
		Claimed = withRim(base, Theme.color.success),
	}
	local picture = C.Icons.picture(function()
		return row().icon
	end, function()
		return row().image
	end, base.ink)
	picture.AnchorPoint = Vector2.new(0.5, 0)
	picture.Position = UDim2.new(0.5, 0, 0, CHIP_H + Theme.spacing.xs)
	picture.Size = UDim2.new(1, 0, 1, -(2 * CHIP_H + NAME_H + 3 * Theme.spacing.xs))
	create("UIAspectRatioConstraint")({ AspectRatio = 1, Parent = picture })
	local cornerIcon = derive(function()
		return status().icon or "none"
	end)

	return Base.interactive({
		name = if isPremium then "Paid" else "Free",
		size = derive(function()
			return Vector2.new(COLUMN_W, tileH())
		end),
		disabled = derive(function()
			return not claimable()
		end),
		onActivate = function()
			if claimable() then
				claim(row())
			end
		end,
		order = 200 + order,
		layoutOrder = order,
		radius = Theme.radius.md,
		visual = function(state)
			return {
				create("Frame")({
					Name = "Tile",
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					Visible = shown,
					Base.raised({
						fill = function()
							return rims[row().status] or base
						end,
						lip = LIP,
						radius = Theme.radius.md,
						sunk = function()
							return state() == "pressed"
						end,
						rimThickness = 3,
						gloss = true,
						children = {
							Base.padding(Theme.spacing.xs),
							-- Gold once the player's wins reach this tier.
							chip("Wins", 0, function()
								return if row().reached then Theme.color.primary else Theme.color.outline
							end, function()
								local w = row().wins
								return if w == 0 then "NOW" else string.format("%d WINS", w)
							end, function()
								return if row().reached then Theme.color.onPrimary else Theme.color.ink
							end),
							switch(cornerIcon)(iconViews({ "check", "lock" }, function(key)
								local icon = C.Icons.view(
									key,
									CORNER_ICON,
									if key == "check" then Theme.color.success else base.ink
								)
								icon.AnchorPoint = Vector2.new(1, 0)
								icon.Position = UDim2.new(1, 0, 0, CHIP_H + Theme.spacing.xxs)
								icon.ZIndex = 4
								return icon
							end)) :: any,
							picture,
							Base.text("caption", {
								Name = "Item",
								AnchorPoint = Vector2.new(0, 1),
								Position = UDim2.new(0, 0, 1, -(CHIP_H + Theme.spacing.xxs)),
								Size = UDim2.new(1, 0, 0, NAME_H),
								Text = function()
									return row().text
								end,
								TextColor3 = base.ink,
								FontFace = Font.new(Theme.type.caption.font.Family, Enum.FontWeight.Bold),
								TextTruncate = Enum.TextTruncate.AtEnd,
							}),
							chip("Status", 1, function()
								return status().back
							end, function()
								return status().text
							end, function()
								return status().ink
							end),
							-- A claimed item dims under its banner, like a
							-- ticked-off tier.
							create("Frame")({
								Name = "Dim",
								Size = UDim2.new(1, 2 * Theme.spacing.xs, 1, 2 * Theme.spacing.xs),
								Position = UDim2.fromOffset(-Theme.spacing.xs, -Theme.spacing.xs),
								BackgroundColor3 = Theme.color.scrim,
								BackgroundTransparency = 0.5,
								ZIndex = 3,
								Visible = function()
									return row().status == "Claimed"
								end,
								Base.corner(Theme.radius.md),
							}),
						},
					}) :: any,
				}),
			}
		end,
	})
end

-- The fixed card heading a row: PAID PASS (locked until bought) or
-- FREE PASS.
local function rowCard(isPremium: boolean, passLocked: () -> boolean, tileH: () -> number): Instance
	local fill = if isPremium then Theme.fill.seasonPaid else Theme.fill.seasonFree
	local lock = C.Icons.view("lock", CORNER_ICON, fill.ink)
	lock.AnchorPoint = Vector2.new(1, 0)
	lock.Position = UDim2.fromScale(1, 0)
	lock.ZIndex = 4
	effect(function()
		lock.Visible = isPremium and passLocked()
	end)
	local crest = C.Icons.view(if isPremium then "star" else "gem", 0, fill.ink)
	crest.AnchorPoint = Vector2.new(0.5, 0)
	crest.Position = UDim2.fromScale(0.5, 0)
	crest.Size = UDim2.new(1, 0, 1, -2 * Theme.type.button.size)
	create("UIAspectRatioConstraint")({ AspectRatio = 1, Parent = crest })
	return create("Frame")({
		Name = if isPremium then "PaidPass" else "FreePass",
		LayoutOrder = if isPremium then 1 else 2,
		Size = function()
			return UDim2.fromOffset(GUTTER_W - Theme.spacing.sm, tileH())
		end,
		BackgroundTransparency = 1,
		Base.raised({
			fill = function()
				return fill
			end,
			lip = LIP,
			radius = Theme.radius.md,
			rimThickness = 3,
			gloss = true,
			children = {
				Base.padding(Theme.spacing.xs),
				crest,
				lock,
				displayText({
					Name = "Label",
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.fromScale(0, 1),
					Size = UDim2.new(1, 0, 0, 2 * Theme.type.button.size),
					Text = if isPremium then "PAID\nPASS" else "FREE\nPASS",
					TextWrapped = true,
				}, function()
					return fill.ink
				end),
			},
		}) :: any,
	})
end

-- A round arrow over one edge of the strip, shown while there's more
-- that way; a tap steps one page.
local function arrow(direction: number, shown: () -> boolean, onActivate: () -> ()): Instance
	local button = Base.interactive({
		name = if direction < 0 then "Left" else "Right",
		size = Vector2.new(ARROW, ARROW),
		onActivate = onActivate,
		order = if direction < 0 then 190 else 290,
		anchorPoint = Vector2.new(if direction < 0 then 0 else 1, 0.5),
		position = UDim2.fromScale(if direction < 0 then 0 else 1, 0.5),
		radius = UDim.new(1, 0),
		visual = function(state)
			local chevron = C.Icons.view("chevron", ARROW / 2, Theme.color.ink)
			chevron.AnchorPoint = Vector2.new(0.5, 0.5)
			chevron.Position = UDim2.fromScale(0.5, 0.5)
			chevron.Rotation = if direction < 0 then -90 else 90 -- the art points up
			return Base.raised({
				fill = function()
					return Theme.fill.secondary
				end,
				lip = LIP,
				radius = UDim.new(1, 0),
				sunk = function()
					return state() == "pressed"
				end,
				gloss = true,
				children = { chevron },
			})
		end,
	})
	button.ZIndex = 10
	effect(function()
		button.Visible = shown()
	end)
	return button
end

local function seasonTrack(store: Store, height: () -> number, pane: number): Instance
	local hasSeason = derive(function()
		return store.seasonView() ~= nil
	end)
	-- Only read while hasSeason is true (the switch below), so the cast
	-- never hides a nil.
	local view = function(): SeasonTrackLogic.View
		return store.seasonView() :: SeasonTrackLogic.View
	end

	return create("Frame")({
		Name = "Season",
		Position = UDim2.fromOffset(0, TAB_H + Theme.spacing.sm),
		Size = function()
			return UDim2.fromOffset(pane, height())
		end,
		BackgroundTransparency = 1,
		switch(hasSeason)({
			[true] = function()
				local columns = derive(function()
					return SeasonTrackLogic.columns(view())
				end)
				local passLocked = derive(function()
					return view().premium.locked
				end)
				local stripH = derive(function()
					return math.max(0, height() - INDICATOR_ROW)
				end)
				local tileH = derive(function()
					return math.max(TILE_MIN, math.floor((stripH() - Theme.spacing.sm) / 2))
				end)
				local function stack(): Instance
					return create("UIListLayout")({
						FillDirection = Enum.FillDirection.Vertical,
						Padding = UDim.new(0, Theme.spacing.sm),
						SortOrder = Enum.SortOrder.LayoutOrder,
					})
				end
				local function claim(track: "Free" | "Premium")
					return function(row: SeasonTrackLogic.Row)
						store.claim(track, row.index)
					end
				end

				-- Where the strip is, in screen pixels: how far along, the
				-- furthest it goes, how much of it the window shows, and
				-- one tier's stride.
				local scroll = source({ at = 0, max = 0, window = 1, stride = STRIDE })

				local strip = create("ScrollingFrame")({
					Name = "Tiers",
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					ScrollBarThickness = 0,
					ScrollingDirection = Enum.ScrollingDirection.X,
					ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
					CanvasSize = function()
						return UDim2.fromOffset(#columns() * STRIDE - Theme.spacing.sm, 0)
					end,
					create("UIListLayout")({
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Theme.spacing.sm),
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
					indexes(columns, function(column: () -> SeasonTrackLogic.Column, index: number)
						return create("Frame")({
							Name = "Tier" .. index,
							LayoutOrder = index,
							Size = UDim2.new(0, COLUMN_W, 1, 0),
							BackgroundTransparency = 1,
							stack(),
							tile(function()
								return column().premium
							end, true, passLocked, tileH, 2 * index - 1, claim("Premium")),
							tile(function()
								return column().free
							end, false, passLocked, tileH, 2 * index, claim("Free")),
						})
					end) :: any,
				}) :: ScrollingFrame

				-- CanvasPosition is in screen pixels, like the Absolute*
				-- sizes, while STRIDE is reference px under the UIScale
				-- (seen in Studio, 2026-10-09), so the stride converts.
				local function measure()
					local canvas = strip.AbsoluteCanvasSize.X
					local offset = strip.CanvasSize.X.Offset
					scroll({
						at = strip.CanvasPosition.X,
						max = math.max(0, canvas - strip.AbsoluteWindowSize.X),
						window = strip.AbsoluteWindowSize.X,
						stride = if offset > 0 then STRIDE * canvas / offset else STRIDE,
					})
				end
				strip:GetPropertyChangedSignal("CanvasPosition"):Connect(measure)
				strip:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(measure)
				strip:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(measure)

				-- A page: every whole tier the window shows but one, so the
				-- last one seen stays in view.
				local function step(direction: number)
					local s = scroll()
					local page = math.max(1, math.floor(s.window / s.stride) - 1) * s.stride
					local target = math.clamp(s.at + direction * page, 0, s.max)
					TweenService:Create(
						strip,
						TweenInfo.new(C.Env.duration(Theme.motion.fast * 2), Enum.EasingStyle.Quad),
						{ CanvasPosition = Vector2.new(target, 0) }
					):Play()
				end

				-- Open on the tier the player can claim or is working
				-- toward, one tier in from the left so the one before it
				-- still shows. Deferred: the canvas is sized once the
				-- frame is parented.
				task.defer(function()
					measure()
					local focus = SeasonTrackLogic.focusColumn(columns())
					strip.CanvasPosition = Vector2.new(math.max(0, (focus - 2) * scroll().stride), 0)
				end)

				local children: { Instance } = {
					create("Frame")({
						Name = "Rows",
						Size = UDim2.new(0, GUTTER_W - Theme.spacing.sm, 1, 0),
						BackgroundTransparency = 1,
						stack(),
						rowCard(true, passLocked, tileH),
						rowCard(false, passLocked, tileH),
					}),
					create("Frame")({
						Name = "Track",
						Position = UDim2.fromOffset(GUTTER_W, 0),
						Size = function()
							return UDim2.fromOffset(pane - GUTTER_W, stripH())
						end,
						BackgroundTransparency = 1,
						strip :: Instance,
						arrow(-1, function()
							return scroll().at > 1
						end, function()
							step(-1)
						end),
						arrow(1, function()
							local s = scroll()
							return s.at < s.max - 1
						end, function()
							step(1)
						end),
					}),
					-- Where the window sits along the whole season.
					create("Frame")({
						Name = "Indicator",
						AnchorPoint = Vector2.new(0, 1),
						Position = UDim2.new(0, GUTTER_W, 1, -Theme.spacing.xs),
						Size = UDim2.fromOffset(pane - GUTTER_W, INDICATOR_H),
						BackgroundColor3 = Theme.color.outline,
						Visible = function()
							return scroll().max > 0
						end,
						Base.corner(UDim.new(1, 0)),
						create("Frame")({
							Name = "Thumb",
							Size = function()
								local s = scroll()
								local whole = s.max + s.window
								return UDim2.fromScale(if whole > 0 then math.max(0.12, s.window / whole) else 1, 1)
							end,
							Position = function()
								local s = scroll()
								local whole = s.max + s.window
								local thumb = if whole > 0 then math.max(0.12, s.window / whole) else 1
								local along = if s.max > 0 then s.at / s.max else 0
								return UDim2.fromScale(along * (1 - thumb), 0)
							end,
							BackgroundColor3 = Theme.color.primary,
							Base.corner(UDim.new(1, 0)),
						}),
					}),
				}
				return children :: any
			end,
			[false] = function()
				return MenuShell.message("No season running", "The next season's track shows up here.")
			end,
		}) :: any,
	})
end

local function body(store: Store, height: () -> number, layout: MenuShell.BodyLayout): { Instance }
	local pane = layout.pane
	local cardW = (pane - Theme.spacing.sm) / 2
	local initialItem: StoreScreenLogic.Item? = nil
	for _, item in store.items do
		if item.key == store.initialKey and StoreScreenLogic.isListed(item, store.isOffered(item)) then
			initialItem = item
		end
	end
	local initial = if initialItem then StoreScreenLogic.categoryOf(initialItem) else store.initialCategory
	local tabIndex = source(if initial then table.find(StoreScreenLogic.CATEGORIES, initial) or 1 else 1)
	-- Cast: derive widens a string-literal union back to `string`.
	local category = derive(function(): StoreScreenLogic.Category
		return StoreScreenLogic.CATEGORIES[tabIndex()]
	end) :: () -> StoreScreenLogic.Category
	local itemsHere = derive(function()
		local s = store.state()
		local season = if s then s.season else nil
		local livePassKey = if season then store.passKeyOf(season.id) else nil
		return StoreScreenLogic.itemsIn(store.items, category(), livePassKey, store.isOffered)
	end)
	local onSeason = derive(function()
		return category() == "Season"
	end)
	local selectedKey = source(nil :: string?)
	-- A tab switch selects that tab's first item, so the panel is never
	-- showing something from a tab the player has left. A refresh of the
	-- same tab (a StoreState push, a sale ending) keeps the selection if
	-- it's still listed. The first pass selects the item the store was
	-- opened on.
	local wanted = if initialItem then initialItem.key else nil
	effect(function()
		local list = itemsHere()
		local keep = wanted or untrack(selectedKey)
		local pick = if list[1] then list[1].key else nil
		for _, item in list do
			if item.key == keep then
				pick = keep
			end
		end
		wanted = nil
		selectedKey(pick)
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
		-- Split puts the panel beside the grid, so the grid gets the height.
		local panelH = if layout.split then 0 else PANEL_H + Theme.spacing.sm
		return math.max(0, height() - TAB_H - Theme.spacing.sm - panelH)
	end)

	local function grid(): Instance
		return create("ScrollingFrame")({
			Name = "Grid",
			Position = UDim2.fromOffset(0, TAB_H + Theme.spacing.sm),
			Size = function()
				-- One bar wider than the cards: see MenuShell.SCROLLBAR.
				return UDim2.fromOffset(pane + MenuShell.SCROLLBAR, gridHeight())
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
			-- Keyed by the config item itself: a card is built once per item
			-- shown, and a tab switch swaps whole cards rather than
			-- rewriting one card into another.
			values(itemsHere, function(item: StoreScreenLogic.Item, index: () -> number)
				local c = card(store, item, selectedKey, selectedKey, cardW) :: GuiObject
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
			width = pane,
			order = 1,
		}),
		switch(loaded)({
			[true] = function()
				return {
					-- The Season tab shows the track where the other tabs
					-- show their grid; the pass sits in the panel below.
					switch(onSeason)({
						[true] = function()
							return seasonTrack(store, gridHeight, pane)
						end,
						[false] = grid,
					}) :: any,
					panel(store, selected, layout),
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
		split = true,
		body = function(height, layout)
			return body(store, height, layout)
		end,
	})
end

return Store
