--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The streak buy-back offer (design-decisions.md Q7, "buying back a
-- streak"): a card that opens over the end screen, and a "Save streak"
-- button in the Hub that reopens it until the player's next race. When
-- and what to show is BuyBackLogic's; this file draws it and buys.
--
-- The offer comes from StoreState (MenuController.storeState), which the
-- server only fills in for the player who lost, and on a match server
-- only from that round's Results. Buying goes through the same
-- StorePurchaseIntent as the store, with the key the server picked; the
-- streak comes back when the receipt lands and StoreState drops the offer.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local StoreConfig = require(ReplicatedStorage.Shared.Config.Store)
local BuyBackLogic = require(script.Parent.Parent.UI.BuyBackLogic)
local C = require(script.Parent.Parent.UI.Components)
local Modal = require(script.Parent.Parent.UI.Components.Modal)
local Theme = require(script.Parent.Parent.UI.Theme)
local MenuController = require(script.Parent.MenuController)
local UIScaleController = require(script.Parent.UIScaleController)

local source = vide.source
local create = vide.create

local TICK = 0.25
local PURCHASE_TIMEOUT = 30
local BUTTON_WIDTH = 176

-- ===== static config =========================================================

local assetIdByKey: { [string]: number } = {}
local keyByAssetId: { [number]: string } = {}
for _, entry in StoreConfig do
	local def = entry.def :: any
	for _, grant in def.grants do
		if grant.kind == "StreakBuyBack" and def.assetId ~= 0 then
			assetIdByKey[def.key] = def.assetId
			keyByAssetId[def.assetId] = def.key
		end
	end
end

-- ===== state =================================================================

local offer = source(nil :: BuyBackLogic.Offer?)
local buyingKey = source(nil :: string?)
local buyToken = 0
local closeCard: (() -> ())? = nil
local livePrices: { [string]: number } = {}
local priceAsked: { [string]: boolean } = {}

-- What Roblox charges for this tier right now (managed pricing can move
-- it). Asked once per key; the card shows the config price until then.
local function fetchPrice(key: string)
	local assetId = assetIdByKey[key]
	if assetId == nil or priceAsked[key] then
		return
	end
	priceAsked[key] = true
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(assetId, Enum.InfoType.Product)
		end)
		local price = if ok and type(info) == "table" then (info :: any).PriceInRobux else nil
		if type(price) == "number" then
			livePrices[key] = price
		else
			priceAsked[key] = false -- try again next time the card opens
		end
	end)
end

local function stopBuying()
	buyToken += 1
	buyingKey(nil)
end

local function hideCard()
	if closeCard ~= nil then
		local close = closeCard :: () -> ()
		closeCard = nil
		close()
	end
end

local function buy(key: string)
	if buyingKey() ~= nil then
		return
	end
	buyingKey(key)
	buyToken += 1
	local token = buyToken
	Net.fireServer("StorePurchaseIntent", { key = key })
	-- A receipt that never lands mustn't leave the button spinning. If it
	-- lands later, the offer still drops and the toast still shows.
	task.delay(PURCHASE_TIMEOUT, function()
		if buyToken == token then
			buyingKey(nil)
		end
	end)
end

local function openCard()
	local current = offer()
	if closeCard ~= nil or current == nil then
		return
	end
	local shown = current :: BuyBackLogic.Offer
	fetchPrice(shown.key)

	closeCard = Modal.open({
		title = BuyBackLogic.title(shown),
		body = BuyBackLogic.body(shown),
		actions = {
			{
				label = BuyBackLogic.buyLabel(shown, livePrices[shown.key]),
				variant = "primary",
				loading = function(): boolean
					return buyingKey() == shown.key
				end,
				onActivate = function()
					buy(shown.key)
				end,
			},
			{
				label = "No thanks",
				variant = "secondary",
				disabled = function(): boolean
					return buyingKey() ~= nil
				end,
				onActivate = hideCard,
			},
		},
		dismissible = true,
		onDismiss = function()
			-- Mid-purchase the Roblox prompt is open on top; the card
			-- stays until it settles.
			if buyingKey() == nil then
				hideCard()
			end
		end,
	})
end

-- ===== the Hub button ========================================================

local function mountButton()
	local gui = UIScaleController.createScreen("BuyBackButton", { displayOrder = Theme.displayOrder.hud })
	local visible = source(false)
	local isHub = MenuController.isHubServer()

	vide.root(function()
		local button = C.Button({
			label = function(): string
				local current = offer()
				return if current then BuyBackLogic.buttonLabel(current) else ""
			end,
			icon = "flame",
			variant = "primary",
			width = BUTTON_WIDTH,
			onActivate = openCard,
			order = 0,
			-- Top centre, clear of the coin balance (top right) and the
			-- launcher (right edge).
			anchorPoint = Vector2.new(0.5, 0),
			position = UDim2.new(0.5, 0, 0, Theme.spacing.md),
		})
		UIScaleController.attachScale(button)
		create("Frame")({
			Name = "BuyBack",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Visible = visible,
			button,
			Parent = gui,
		})
	end)

	-- Re-read twice a second rather than wiring a signal into every
	-- menu and round change: four cheap comparisons.
	local shownFor: string? = nil
	local resultsSince: number? = nil
	task.spawn(function()
		while true do
			local nextOffer = BuyBackLogic.read(MenuController.storeState())
			local before = offer()
			local landed = BuyBackLogic.landed(buyingKey(), before, nextOffer)
			if landed ~= nil then
				stopBuying()
				hideCard()
				C.Toast.show(landed, "success")
			elseif nextOffer == nil and before ~= nil then
				hideCard() -- expired, or replaced by nothing
			end
			if (nextOffer and BuyBackLogic.id(nextOffer)) ~= (before and BuyBackLogic.id(before)) then
				offer(nextOffer)
				if nextOffer ~= nil then
					fetchPrice(nextOffer.key)
				end
			end

			local menu = MenuController.currentMenu()
			if menu == "Results" then
				resultsSince = resultsSince or os.clock()
			else
				resultsSince = nil
			end
			local openFor = if resultsSince then os.clock() - resultsSince else 0
			if BuyBackLogic.shouldAutoOpen(nextOffer, menu, openFor, shownFor) then
				shownFor = BuyBackLogic.id(nextOffer :: BuyBackLogic.Offer)
				openCard()
			end

			visible(
				BuyBackLogic.buttonVisible(nextOffer, isHub, menu, MenuController.roundState()) and closeCard == nil
			)
			task.wait(TICK)
		end
	end)
end

-- ===== controller ============================================================

local BuyBackController: Loader.Controller = {
	name = "BuyBackController",
	dependencies = { "UIScaleController", "MenuController" },
}

function BuyBackController:init()
	Net.onClientEvent("StorePurchaseResult", function(payload: any)
		if type(payload) ~= "table" or payload.key ~= buyingKey() then
			return
		end
		if payload.status ~= "Prompted" then
			stopBuying()
			if type(payload.message) == "string" and payload.message ~= "" then
				C.Toast.show(payload.message, "warning")
			end
		end
	end)
	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, purchased: boolean)
			if userId == Players.LocalPlayer.UserId and keyByAssetId[productId] == buyingKey() and not purchased then
				stopBuying()
			end
		end
	)
end

function BuyBackController:start()
	mountButton()
end

return BuyBackController
