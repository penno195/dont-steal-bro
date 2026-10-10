--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The menu screens (P6-6): locker, store, leaderboards, results and
-- settings.
-- Owns their data (remotes -> Vide sources), the store's purchase flow,
-- the launcher that opens them, and which one is up. The screens never
-- touch a remote.
--
-- ONE MENU AT A TIME. Opening one closes whichever was open.
--
-- THE LAUNCHER: four buttons (locker, store, boards, settings) stacked on the
-- right edge at mid-height, where a right thumb rests in portrait and
-- clear of Roblox's jump button below. Hidden while a round is in play
-- (RaceHUD and the Decision Studio own the screen then), and while a
-- menu is open.
--
-- THE COIN BALANCE: hub only, top-right under Roblox's top bar - where
-- players look for a currency. The "+" says it's a button: it opens the
-- store on the Coins tab. Hidden while a menu is open (the store shows
-- its own balance) and in a match place, where the HUD owns the corners.
--
-- RESULTS opens itself on entering Results - but only once the Decision
-- Studio screen is gone (DecisionStudioController.isActive), because
-- the reveal outlives the Studio phase (docs/decision-studio.md).
--
-- Data freshness, per screen (the P6-6 note; docs/menu-screens.md):
--   store        StoreState live+targeted; catalogue is static config
--   leaderboards cached server-side, broadcast every 60-120s, kept here
--   results      RoundRecap once per round, targeted; tally counted here
--   settings     SettingsController (live, targeted)

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local vide = require(ReplicatedStorage.Packages.Vide)

local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local StoreConfig = require(ReplicatedStorage.Shared.Config.Store)
local Seasons = require(ReplicatedStorage.Shared.Config.Seasons)
local StoreOffers = require(ReplicatedStorage.Shared.StoreOffers)
local Titles = require(ReplicatedStorage.Shared.Config.Titles)
local BoardLogic = require(script.Parent.Parent.UI.BoardLogic)
local C = require(script.Parent.Parent.UI.Components)
local ResultsLogic = require(script.Parent.Parent.UI.ResultsLogic)
local StoreScreenLogic = require(script.Parent.Parent.UI.StoreScreenLogic)
local SeasonTrackLogic = require(script.Parent.Parent.UI.SeasonTrackLogic)
local Theme = require(script.Parent.Parent.UI.Theme)
local LeaderboardsScreen = require(script.Parent.Parent.UI.Screens.Leaderboards)
local LockerScreen = require(script.Parent.Parent.UI.Screens.Locker)
local DropNames = require(script.Parent.Parent.UI.DropNames)
local ResultsScreen = require(script.Parent.Parent.UI.Screens.Results)
local SettingsScreen = require(script.Parent.Parent.UI.Screens.Settings)
local StoreScreen = require(script.Parent.Parent.UI.Screens.Store)
local ClaimPopup = require(script.Parent.Parent.UI.Screens.ClaimPopup)
local DecisionStudioController = require(script.Parent.DecisionStudioController)
local SettingsController = require(script.Parent.SettingsController)
local UIScaleController = require(script.Parent.UIScaleController)

local source = vide.source
local create = vide.create

local selfId = Players.LocalPlayer.UserId

-- Round states with a screen of their own, when the launcher stays away.
local IN_PLAY: { [string]: boolean } = {
	Loading = true,
	Intro = true,
	Race = true,
	Qualified = true,
	DecisionStudio = true,
}

local FLOW_TICK = 0.5
-- How often the store's view of the server clock moves on. Sale windows
-- are to the minute, and the server refuses anything that just ended.
local OFFER_TICK = 30
local STUDIO_POLL = 0.25

-- ===== static config =========================================================

local items: { StoreScreenLogic.Item } = {}
local byAssetId: { [number]: string } = {}
for _, entry in StoreConfig do
	table.insert(items, entry.def :: any)
	if entry.def.assetId ~= 0 then
		byAssetId[entry.def.assetId] = entry.def.key
	end
end

-- ===== offers ================================================================
-- What's on sale right now (design-decisions.md Q1, "the featured
-- plinths"), on the server's clock: a player's own clock never decides
-- what shows. StoreService runs the same StoreOffers checks on os.time(),
-- and its answer is the one that counts.

local serverNow = source(Workspace:GetServerTimeNow())
local livePrices = source({} :: { [string]: number })
local priceAsked: { [string]: boolean } = {}

local function isOffered(item: StoreScreenLogic.Item): boolean
	return StoreOffers.isOffered(StoreConfig :: any, item :: any, serverNow())
end

-- What Roblox really charges for a Robux item with a "was" price: the
-- sale tag shows only if that's lower (Q1, "the featured plinths").
-- Asked once per key; config's robuxPrice stands in until it answers.
local function fetchLivePrice(item: StoreScreenLogic.Item)
	local assetId = (item :: any).assetId :: number
	if item.kind == "CoinOffer" or item.wasPrice == nil or assetId == 0 or priceAsked[item.key] then
		return
	end
	priceAsked[item.key] = true
	task.spawn(function()
		local infoType = if item.kind == "GamePass" then Enum.InfoType.GamePass else Enum.InfoType.Product
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfoAsync(assetId, infoType)
		end)
		local price = if ok and type(info) == "table" then (info :: any).PriceInRobux else nil
		if type(price) == "number" then
			local nextPrices = table.clone(livePrices())
			nextPrices[item.key] = price
			livePrices(nextPrices)
		else
			priceAsked[item.key] = false -- try again next time it's shown
		end
	end)
end

local function priceOf(item: StoreScreenLogic.Item): StoreScreenLogic.Price
	if item.kind == "CoinOffer" then
		return { now = item.coinPrice or 0, was = StoreOffers.wasPrice(item :: any, nil) }
	end
	fetchLivePrice(item)
	local live = livePrices()[item.key]
	return { now = live or item.robuxPrice, was = StoreOffers.wasPrice(item :: any, live) }
end

local cosmeticDefs: { [string]: any } = {}
for _, entry in Cosmetics do
	cosmeticDefs[entry.def.id] = entry.def
end
local powerUpDefs: { [string]: any } = {}
local powerUpIds: { string } = {}
for _, entry in PowerUps do
	powerUpDefs[entry.def.id] = entry.def
	table.insert(powerUpIds, entry.def.id)
end

-- The Locker's Style tab groups cosmetics in this order: what you wear
-- first, then what shows in the Studio.
local COSMETIC_CATEGORY_ORDER = {
	"Skin",
	"Hat",
	"BackItem",
	"Trail",
	"Nameplate",
	"StreakFlair",
	"Emote",
	"Projectile",
	"Podium",
	"Reveal",
	"CallingCard",
}
local titleNames: { [string]: string } = {}
local titleColors: { [string]: Color3 } = {}
local titleLadder: { { id: string, minStreak: number } } = {}
for _, entry in Titles do
	titleNames[entry.def.id] = entry.def.displayName
	titleColors[entry.def.id] = Color3.fromHex(entry.def.colorHex)
	table.insert(titleLadder, { id = entry.def.id, minStreak = entry.def.minStreak })
end

local seasonDefs: { [string]: SeasonTrackLogic.SeasonDef } = {}
for _, entry in Seasons do
	seasonDefs[entry.def.id] = entry.def :: any
end

local function rarityOf(grant: StoreScreenLogic.Grant): string?
	if grant.kind == "Cosmetic" and grant.cosmeticId then
		local def = cosmeticDefs[grant.cosmeticId]
		return def and def.rarity
	elseif grant.kind == "PowerUpStock" and grant.powerUpId then
		local def = powerUpDefs[grant.powerUpId]
		return def and def.rarity
	end
	return nil
end

-- A season reward's own picture: a cosmetic's preview icon, once it has
-- one. Anything else shows its icon (SeasonTrackLogic.iconFor).
local function grantImage(grant: SeasonTrackLogic.Grant): number?
	local def = if grant.kind == "Cosmetic" and grant.cosmeticId then cosmeticDefs[grant.cosmeticId] else nil
	local id = if def then def.previewIconAssetId else nil
	return if type(id) == "number" and id > 0 then id else nil
end

local function cosmeticName(id: string): string
	local def = cosmeticDefs[id]
	return if def then def.displayName else id
end

local function grantText(grant: StoreScreenLogic.Grant): string
	if grant.kind == "Currency" then
		return string.format("%d coins", grant.amount or 0)
	elseif grant.kind == "PowerUpStock" and grant.powerUpId then
		local def = powerUpDefs[grant.powerUpId]
		return string.format("%dx %s", grant.amount or 1, if def then def.displayName else grant.powerUpId)
	elseif grant.kind == "Cosmetic" and grant.cosmeticId then
		return cosmeticName(grant.cosmeticId)
	elseif grant.kind == "Title" and grant.titleId then
		return string.format("Title: %s", titleNames[grant.titleId] or grant.titleId)
	end
	return grant.kind
end

-- ===== state =================================================================

local storeState = source(nil :: StoreScreenLogic.StoreState?)
local flow = source(StoreScreenLogic.idle())
local boards = source({} :: { [string]: BoardLogic.Payload })
local recap = source(nil :: ResultsLogic.Recap?)
local tally = source({ placement = nil, fieldSize = 0, tasksCompleted = 0, powerUpsUsed = 0 } :: ResultsLogic.RaceTally)
local roundState = source(nil :: string?)

-- step hands back the same table when nothing changed; only a real
-- change is written, so the twice-a-second Tick doesn't re-run the store
-- screen's derives for nothing.
local function stepFlow(event: StoreScreenLogic.FlowEvent)
	local current = flow()
	local nextFlow = StoreScreenLogic.step(current, event, os.clock())
	if nextFlow ~= current then
		flow(nextFlow)
	end
end

-- "Same as last round", from the Locker or the queue strip. The server
-- picks what goes in, from the profile.
local function repeatLastLoadout()
	Net.fireServer("StoreLoadoutRepeatIntent", {})
end

local function setBoard(tab: string, payload: any)
	if type(payload) ~= "table" or type(payload.entries) ~= "table" then
		return
	end
	local nextBoards = table.clone(boards())
	nextBoards[tab] = {
		entries = payload.entries,
		status = if type(payload.status) == "string" then payload.status else "Fresh",
		periodKey = payload.periodKey,
	}
	boards(nextBoards)
end

-- ===== screens ===============================================================

type Menu = "Store" | "Locker" | "Leaderboards" | "Results" | "Settings"

local openMenu: Menu? = nil
local unmountMenu: (() -> ())? = nil
local syncLauncher: () -> () = function() end

local function closeMenu()
	if unmountMenu ~= nil then
		(unmountMenu :: () -> ())()
		unmountMenu = nil
	end
	openMenu = nil
	syncLauncher()
end

local function open(menu: Menu, storeCategory: StoreScreenLogic.Category?, storeKey: string?)
	closeMenu()
	openMenu = menu
	if menu == "Store" then
		unmountMenu = StoreScreen.mount(UIScaleController, {
			items = items,
			initialCategory = storeCategory,
			initialKey = storeKey,
			isOffered = isOffered,
			priceOf = priceOf,
			rarityOf = rarityOf,
			grantText = grantText,
			cosmeticName = cosmeticName,
			state = storeState,
			flow = flow,
			buy = function(key: string)
				local before = flow()
				stepFlow({ type = "Tap", key = key, state = storeState() })
				if flow() ~= before then
					Net.fireServer("StorePurchaseIntent", { key = key })
				end
			end,
			dismiss = function()
				stepFlow({ type = "Dismiss" })
			end,
			equip = function(cosmeticId: string, wear: boolean)
				local def = cosmeticDefs[cosmeticId]
				local slot = def and StoreScreenLogic.slotFor(def.category)
				if slot then
					Net.fireServer("StoreEquipIntent", { slot = slot, itemId = if wear then cosmeticId else nil })
				end
			end,
			close = closeMenu,
			seasonView = function(): SeasonTrackLogic.View?
				local s = storeState()
				local season = if s then s.season else nil
				local def = if season then seasonDefs[season.id] else nil
				if season == nil or def == nil then
					return nil
				end
				return SeasonTrackLogic.view(def, season :: any, grantText :: any, grantImage)
			end,
			claim = function(track: ("Free" | "Premium")?, upTo: number?)
				Net.fireServer("SeasonClaimIntent", { track = track, upTo = upTo })
			end,
			passKeyOf = function(seasonId: string): string?
				local def = seasonDefs[seasonId]
				return if def then def.passKey else nil
			end,
		})
	elseif menu == "Locker" then
		unmountMenu = LockerScreen.mount(UIScaleController, {
			state = storeState,
			powerUpIds = powerUpIds,
			powerUpName = function(id: string): string
				local def = powerUpDefs[id]
				return if def then def.displayName else id
			end,
			powerUpRarity = function(id: string): string?
				local def = powerUpDefs[id]
				return def and def.rarity
			end,
			cosmeticName = cosmeticName,
			cosmeticCategory = function(id: string): string?
				local def = cosmeticDefs[id]
				return def and def.category
			end,
			cosmeticRarity = function(id: string): string?
				local def = cosmeticDefs[id]
				return def and def.rarity
			end,
			categoryOrder = COSMETIC_CATEGORY_ORDER,
			setSlot = function(slotIndex: number, powerUpId: string?)
				Net.fireServer("StoreLoadoutIntent", { slotIndex = slotIndex, powerUpId = powerUpId })
			end,
			repeatLast = repeatLastLoadout,
			equip = function(cosmeticId: string, slot: string, wear: boolean)
				Net.fireServer("StoreEquipIntent", { slot = slot, itemId = if wear then cosmeticId else nil })
			end,
			titleLadder = titleLadder,
			titleName = function(id: string): string
				return titleNames[id] or id
			end,
			titleColor = function(id: string): Color3
				return titleColors[id] or Theme.color.ink
			end,
			equipTitle = function(titleId: string?)
				Net.fireServer("TitleEquipIntent", { titleId = titleId })
			end,
			close = closeMenu,
		})
	elseif menu == "Leaderboards" then
		unmountMenu =
			LeaderboardsScreen.mount(UIScaleController, { selfId = selfId, boards = boards, close = closeMenu })
	elseif menu == "Results" then
		unmountMenu = ResultsScreen.mount(UIScaleController, {
			recap = recap,
			tally = tally,
			close = closeMenu,
			nameOf = DropNames,
		})
	else
		unmountMenu = SettingsScreen.mount(UIScaleController, {
			settings = SettingsController.settings,
			loaded = SettingsController.loaded,
			change = SettingsController.change,
			reset = SettingsController.reset,
			close = closeMenu,
		})
	end
	syncLauncher()
end

-- ===== launcher ==============================================================

-- Same check as QueueController's: the hub place, or in Studio a place
-- with a Hub model when no hub place id is configured.
local function isHubServer(): boolean
	local hubPlaceId = GameConfig.matchmaking.hubPlaceId
	if hubPlaceId == 0 then
		return RunService:IsStudio() and Workspace:FindFirstChild("Hub") ~= nil
	end
	return game.PlaceId == hubPlaceId
end

local function mountLauncher()
	local gui = UIScaleController.createScreen("MenuLauncher", { displayOrder = Theme.displayOrder.hud })
	local visible = source(true)
	local coinsVisible = source(false)
	local inHub = isHubServer()
	syncLauncher = function()
		local free = openMenu == nil and not IN_PLAY[roundState() or ""]
		visible(free)
		coinsVisible(free and inHub)
	end

	vide.root(function()
		local coins = C.CurrencyPill({
			amount = function()
				local s = storeState()
				return if s then s.currency else 0
			end,
			onActivate = function()
				open("Store", "Currency")
			end,
			order = 0,
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.new(1, -Theme.spacing.md, 0, Theme.spacing.md),
		})
		UIScaleController.attachScale(coins)
		create("Frame")({
			Name = "CoinBalance",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Visible = coinsVisible,
			coins,
			Parent = gui,
		})
	end)

	vide.root(function()
		local column = create("Frame")({
			Name = "Launcher",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -Theme.spacing.sm, 0.45, 0),
			Size = UDim2.fromOffset(Theme.touch.iconButton, 4 * Theme.touch.iconButton + 3 * Theme.spacing.md),
			BackgroundTransparency = 1,
			Visible = visible,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Theme.spacing.md),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			C.IconButton({
				icon = "locker",
				label = "Locker",
				variant = "secondary",
				onActivate = function()
					open("Locker")
				end,
				order = 1,
				layoutOrder = 1,
			}),
			C.IconButton({
				icon = "shop",
				label = "Store",
				variant = "secondary",
				onActivate = function()
					open("Store")
				end,
				order = 2,
				layoutOrder = 2,
			}),
			C.IconButton({
				icon = "trophy",
				label = "Leaderboards",
				variant = "secondary",
				onActivate = function()
					open("Leaderboards")
				end,
				order = 3,
				layoutOrder = 3,
			}),
			C.IconButton({
				icon = "settings",
				label = "Settings",
				variant = "secondary",
				onActivate = function()
					open("Settings")
				end,
				order = 4,
				layoutOrder = 4,
			}),
			Parent = gui,
		}) :: Frame
		UIScaleController.attachScale(column)
	end)
end

-- ===== round lifecycle =======================================================

local resultsToken = 0

local function onRoundState(state: string)
	roundState(state)
	if state == "Loading" or state == "Intro" then
		recap(nil)
		tally({ placement = nil, fieldSize = 0, tasksCompleted = 0, powerUpsUsed = 0 })
	end
	if IN_PLAY[state] and openMenu ~= nil then
		closeMenu()
	end
	if state == "Results" then
		-- Wait out the Studio's reveal, then show the recap - unless the
		-- round has moved on or the player opened something else first.
		resultsToken += 1
		local token = resultsToken
		task.spawn(function()
			while DecisionStudioController.isActive() do
				task.wait(STUDIO_POLL)
				if token ~= resultsToken or roundState() ~= "Results" then
					return
				end
			end
			if openMenu == nil then
				open("Results")
			end
		end)
	else
		resultsToken += 1
	end
	syncLauncher()
end

local MenuController: Loader.Controller = {
	name = "MenuController",
	dependencies = { "UIScaleController", "SettingsController", "DecisionStudioController" },

	-- For QueueController's loadout strip, which shows the same
	-- StoreState and opens the Locker.
	storeState = storeState,
	openLocker = function()
		open("Locker")
	end,
	-- For StorePlinthController: a plinth opens the store on its item,
	-- and draws it with the same offers and prices the store uses.
	openStoreOn = function(key: string)
		open("Store", nil, key)
	end,
	featured = function(): { [number]: StoreScreenLogic.Item }
		return StoreOffers.featured(StoreConfig :: any, serverNow()) :: any
	end,
	priceOf = priceOf,
	repeatLastLoadout = repeatLastLoadout,
	-- For BuyBackController: which menu is up (nil = none), and the
	-- round state as this controller last heard it.
	currentMenu = function(): string?
		return openMenu
	end,
	roundState = roundState,
	isHubServer = isHubServer,
}

function MenuController:init()
	Net.onClientEvent("RoundState", function(payload: any)
		if type(payload.state) == "string" then
			onRoundState(payload.state)
		end
	end)

	-- Store.
	Net.onClientEvent("StoreState", function(payload: any)
		-- A season-pass claim lands as higher paid counts: celebrate what
		-- it paid with the pop-up and its sound.
		local before = storeState()
		local beforeSeason = if before then before.season else nil
		local afterSeason = if type(payload) == "table" then payload.season else nil
		local def = if type(afterSeason) == "table" then seasonDefs[afterSeason.id] else nil
		if def ~= nil then
			local rewards = SeasonTrackLogic.claimedBetween(def, beforeSeason :: any, afterSeason)
			if #rewards > 0 then
				local shown: { ClaimPopup.Reward } = {}
				for _, reward in rewards do
					table.insert(shown, {
						premium = reward.premium,
						text = grantText(reward.grant :: any),
						icon = SeasonTrackLogic.iconFor(reward.grant),
						image = grantImage(reward.grant),
					})
				end
				ClaimPopup.open(shown)
				Loader.get("AudioController").play("SeasonClaim")
			end
		end
		storeState(payload)
		stepFlow({ type = "State", state = payload })
	end)
	Net.onClientEvent("StorePurchaseResult", function(payload: any)
		if type(payload.key) == "string" and type(payload.status) == "string" then
			stepFlow({
				type = "Result",
				key = payload.key,
				status = payload.status,
				message = if type(payload.message) == "string" then payload.message else "",
			})
		end
	end)
	-- The prompt-closed signals only move the spinner; ownership still
	-- comes from StoreState alone. Note the two disagree on their first
	-- argument (a Player vs a user id) - see StoreService.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			local key = byAssetId[passId]
			if player == Players.LocalPlayer and key then
				stepFlow({ type = "PromptClosed", key = key, purchased = purchased })
			end
		end
	)
	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, purchased: boolean)
			local key = byAssetId[productId]
			if userId == selfId and key then
				stepFlow({ type = "PromptClosed", key = key, purchased = purchased })
			end
		end
	)

	-- Boards.
	Net.onClientEvent("LeaderboardState", function(payload: any)
		setBoard("AllTime", payload)
	end)
	Net.onClientEvent("PeriodBoardState", function(payload: any)
		if payload.kind == "Daily" or payload.kind == "Weekly" then
			setBoard(payload.kind, payload)
		end
	end)

	-- Results: the recap, and the tally from what this client already saw.
	Net.onClientEvent("RoundRecap", function(payload: any)
		if type(payload) == "table" and type(payload.reason) == "string" then
			recap(payload)
		end
	end)
	Net.onClientEvent("TaskQualificationResult", function(payload: any)
		local ranked = if type(payload) == "table" then payload.ranked else nil
		if type(ranked) ~= "table" then
			return
		end
		local nextTally = table.clone(tally())
		nextTally.fieldSize = #ranked
		for _, entry in ranked do
			if entry.playerId == selfId then
				nextTally.placement = entry.rank
				nextTally.tasksCompleted = entry.tasksCompleted
			end
		end
		tally(nextTally)
	end)
	Net.onClientEvent("PowerUpUseResult", function(payload: any)
		if type(payload) == "table" and payload.success == true then
			local nextTally = table.clone(tally())
			nextTally.powerUpsUsed += 1
			tally(nextTally)
		end
	end)
end

function MenuController:start()
	mountLauncher()
	syncLauncher()

	-- The flow's timeouts (REQUEST_TIMEOUT, GRANT_WAIT). A tick while
	-- idle is a no-op in the reducer, so this doesn't check the phase.
	task.spawn(function()
		while true do
			task.wait(FLOW_TICK)
			stepFlow({ type = "Tick" })
		end
	end)
	task.spawn(function()
		while true do
			task.wait(OFFER_TICK)
			serverNow(Workspace:GetServerTimeNow())
		end
	end)
end

return MenuController
