--!strict
-- Banking a streak in the Hub (payoff-loop step 4; design-decisions.md
-- Q7's cash-out case): the card the launcher's Bank streak button opens,
-- its confirm step, and the result toast. What to say is
-- CashOutViewLogic's; what it pays is the server's (CashOutLogic).
--
-- The card comes from StoreState.cashOut (MenuController.storeState),
-- which the server fills in on the Hub only, for its owner. Banking
-- sends StreakCashOutIntent with the streak the confirm step named, so
-- a restore landing in between is refused rather than banked unseen.
-- The coins, the 0 streak and the new best banked come back in the next
-- StoreState, and StreakCashOutResult toasts how it went.
--
-- Two dialogs chained, never stacked (Modal's own rule): the card, then
-- "Bank your 5-win streak?". Banking can't be undone, so it always asks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local C = require(script.Parent.Parent.UI.Components)
local CashOutViewLogic = require(script.Parent.Parent.UI.CashOutViewLogic)
local Modal = require(script.Parent.Parent.UI.Components.Modal)
local MenuController = require(script.Parent.MenuController)

-- Seconds to wait for StreakCashOutResult before saying so.
local RESULT_TIMEOUT = 10

local closeDialog: (() -> ())? = nil
local pendingToken = 0
local pending = false

local function hideDialog()
	if closeDialog ~= nil then
		local close = closeDialog :: () -> ()
		closeDialog = nil
		close()
	end
end

local function currentCard(): CashOutViewLogic.Card?
	local state = MenuController.storeState()
	return CashOutViewLogic.parse(if state then state.cashOut else nil)
end

local function bank(card: CashOutViewLogic.Card)
	hideDialog()
	if pending then
		return
	end
	pending = true
	pendingToken += 1
	local token = pendingToken
	Net.fireServer("StreakCashOutIntent", { streak = card.streak })
	task.delay(RESULT_TIMEOUT, function()
		if pending and pendingToken == token then
			pending = false
			C.Toast.show(CashOutViewLogic.TIMEOUT_TOAST, "warning")
		end
	end)
end

local openCard: () -> ()

-- "Bank your 5-win streak?" The numbers are the card's at the moment
-- Bank was tapped, and the intent carries that streak.
local function openConfirm(card: CashOutViewLogic.Card)
	hideDialog()
	closeDialog = Modal.open({
		title = CashOutViewLogic.confirmTitle(card),
		body = CashOutViewLogic.CONFIRM_BODY,
		actions = {
			{
				label = CashOutViewLogic.confirmLabel(card),
				variant = "primary",
				onActivate = function()
					bank(card)
				end,
			},
			{
				label = CashOutViewLogic.KEEP_LABEL,
				variant = "secondary",
				onActivate = function()
					openCard()
				end,
			},
		},
		dismissible = true,
		onDismiss = hideDialog,
	})
end

openCard = function()
	hideDialog()
	local card = currentCard()
	if card == nil then
		return
	end
	local shown = card :: CashOutViewLogic.Card
	closeDialog = Modal.open({
		title = CashOutViewLogic.TITLE,
		body = CashOutViewLogic.body(shown),
		bodyLines = 4,
		actions = {
			{
				label = CashOutViewLogic.bankLabel(shown),
				variant = "primary",
				disabled = not shown.available,
				onActivate = function()
					if shown.available then
						openConfirm(shown)
					end
				end,
			},
			{
				label = "Close",
				variant = "secondary",
				onActivate = hideDialog,
			},
		},
		dismissible = true,
		onDismiss = hideDialog,
	})
end

local CashOutController: Loader.Controller = {
	name = "CashOutController",
	dependencies = { "UIScaleController", "MenuController" },

	-- The launcher's Bank streak button (MenuController).
	open = function()
		openCard()
	end,
}

function CashOutController:init()
	Net.onClientEvent("StreakCashOutResult", function(payload: any)
		pending = false
		pendingToken += 1
		local text, ok = CashOutViewLogic.resultToast(payload)
		C.Toast.show(text, if ok then "success" else "warning")
		if ok then
			Loader.get("AudioController").play("SeasonClaim")
		end
	end)
end

return CashOutController
