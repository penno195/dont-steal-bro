--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The menu screens (P6-6): store, leaderboards, results and settings.
-- Owns their data (remotes -> Vide sources), the store's purchase flow,
-- the launcher that opens them, and which one is up. The screens never
-- touch a remote.
--
-- ONE MENU AT A TIME. Opening one closes whichever was open.
--
-- THE LAUNCHER: three buttons (store, boards, settings) stacked on the
-- right edge at mid-height, where a right thumb rests in portrait and
-- clear of Roblox's jump button below. Hidden while a round is in play
-- (RaceHUD and the Decision Studio own the screen then), and while a
-- menu is open.
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

local vide = require(ReplicatedStorage.Packages.Vide)

local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local StoreConfig = require(ReplicatedStorage.Shared.Config.Store)
local Titles = require(ReplicatedStorage.Shared.Config.Titles)
local BoardLogic = require(script.Parent.Parent.UI.BoardLogic)
local C = require(script.Parent.Parent.UI.Components)
local ResultsLogic = require(script.Parent.Parent.UI.ResultsLogic)
local StoreScreenLogic = require(script.Parent.Parent.UI.StoreScreenLogic)
local Theme = require(script.Parent.Parent.UI.Theme)
local LeaderboardsScreen = require(script.Parent.Parent.UI.Screens.Leaderboards)
local ResultsScreen = require(script.Parent.Parent.UI.Screens.Results)
local SettingsScreen = require(script.Parent.Parent.UI.Screens.Settings)
local StoreScreen = require(script.Parent.Parent.UI.Screens.Store)
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

local cosmeticDefs: { [string]: any } = {}
for _, entry in Cosmetics do
	cosmeticDefs[entry.def.id] = entry.def
end
local powerUpDefs: { [string]: any } = {}
for _, entry in PowerUps do
	powerUpDefs[entry.def.id] = entry.def
end
local titleNames: { [string]: string } = {}
for _, entry in Titles do
	titleNames[entry.def.id] = entry.def.displayName
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

type Menu = "Store" | "Leaderboards" | "Results" | "Settings"

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

local function open(menu: Menu)
	closeMenu()
	openMenu = menu
	if menu == "Store" then
		unmountMenu = StoreScreen.mount(UIScaleController, {
			items = items,
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
		})
	elseif menu == "Leaderboards" then
		unmountMenu =
			LeaderboardsScreen.mount(UIScaleController, { selfId = selfId, boards = boards, close = closeMenu })
	elseif menu == "Results" then
		unmountMenu = ResultsScreen.mount(UIScaleController, { recap = recap, tally = tally, close = closeMenu })
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

local function mountLauncher()
	local gui = UIScaleController.createScreen("MenuLauncher", { displayOrder = Theme.displayOrder.hud })
	local visible = source(true)
	syncLauncher = function()
		visible(openMenu == nil and not IN_PLAY[roundState() or ""])
	end

	vide.root(function()
		local column = create("Frame")({
			Name = "Launcher",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -Theme.spacing.sm, 0.45, 0),
			Size = UDim2.fromOffset(Theme.touch.iconButton, 3 * Theme.touch.iconButton + 2 * Theme.spacing.md),
			BackgroundTransparency = 1,
			Visible = visible,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Theme.spacing.md),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			C.IconButton({
				icon = "shop",
				label = "Store",
				variant = "secondary",
				onActivate = function()
					open("Store")
				end,
				order = 1,
				layoutOrder = 1,
			}),
			C.IconButton({
				icon = "trophy",
				label = "Leaderboards",
				variant = "secondary",
				onActivate = function()
					open("Leaderboards")
				end,
				order = 2,
				layoutOrder = 2,
			}),
			C.IconButton({
				icon = "settings",
				label = "Settings",
				variant = "secondary",
				onActivate = function()
					open("Settings")
				end,
				order = 3,
				layoutOrder = 3,
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
}

function MenuController:init()
	Net.onClientEvent("RoundState", function(payload: any)
		if type(payload.state) == "string" then
			onRoundState(payload.state)
		end
	end)

	-- Store.
	Net.onClientEvent("StoreState", function(payload: any)
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
end

return MenuController
