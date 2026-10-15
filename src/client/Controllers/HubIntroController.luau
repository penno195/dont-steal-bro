--!strict
-- The hub intro (tutorial seam 2, docs/onboarding.md "The hub intro"):
-- on a player's first visit to the Hub, four cards (Race your tasks,
-- Mess with rivals, Steal or Share, Your streak), then the offer: "Try a
-- practice round" or Skip. Skip points at the Play button.
--
-- Display-only, like the tips. `introSeen` is a saved setting so the
-- intro doesn't come back on the next join; a client that fakes it only
-- changes its own screen. The tutorial's reward is the server's call
-- (DataService.claimTutorialReward, on finishing the guided round).
--
-- One Modal per card: Next closes this one and opens the next, so each
-- card reads as a fresh page. Any way out (Skip, Try, the close button,
-- B, tapping outside) marks it seen. Settings' "Show the intro" sets
-- introSeen back to false, and it opens again from the first card.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local C = require(script.Parent.Parent.UI.Components)
local OnboardingLogic = require(script.Parent.Parent.UI.OnboardingLogic)

-- How often to check whether the intro is due, and how long to let the
-- Hub settle (character in, loading screen gone) before it opens.
local POLL = 1
local SETTLE = 1.5

local settings: any
local menu: any
local queue: any

local roundState: string? = nil
local open = false
local closeCurrent: (() -> ())? = nil

local function finish(try: boolean)
	if closeCurrent then
		closeCurrent()
		closeCurrent = nil
	end
	open = false
	settings.change({ introSeen = true })
	if try then
		queue.startPractice()
	else
		queue.pointAtPlay()
	end
end

local function showOffer()
	local O = OnboardingLogic.INTRO_OFFER
	closeCurrent = C.Modal.open({
		title = O.title,
		body = O.body,
		actions = {
			{
				label = O.try,
				onActivate = function()
					finish(true)
				end,
			},
			{
				label = O.skip,
				variant = "secondary",
				onActivate = function()
					finish(false)
				end,
			},
		},
		dismissible = true,
		onDismiss = function()
			finish(false)
		end,
	})
end

local function showCard(index: number)
	local card = OnboardingLogic.INTRO[index]
	if card == nil then
		showOffer()
		return
	end
	closeCurrent = C.Modal.open({
		title = string.format("%s  %d/%d", card.title, index, #OnboardingLogic.INTRO),
		body = card.body,
		actions = {
			{
				label = "Next",
				onActivate = function()
					if closeCurrent then
						closeCurrent()
					end
					showCard(index + 1)
				end,
			},
			{
				label = OnboardingLogic.INTRO_OFFER.skip,
				variant = "secondary",
				onActivate = function()
					finish(false)
				end,
			},
		},
		dismissible = true,
		onDismiss = function()
			finish(false)
		end,
	})
end

local function due(): boolean
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	return OnboardingLogic.introDue({
		isHub = menu.isHubServer(),
		settingsLoaded = settings.loaded(),
		introSeen = settings.settings().introSeen,
		roundState = roundState,
		loading = playerGui ~= nil and playerGui:FindFirstChild("LoadingCover") ~= nil,
		menuOpen = menu.currentMenu() ~= nil,
		queued = queue.queued(),
	})
end

local HubIntroController: Loader.Controller = {
	name = "HubIntroController",
	dependencies = { "SettingsController", "MenuController", "QueueController", "UIScaleController" },
}

function HubIntroController:init()
	settings = Loader.get("SettingsController")
	menu = Loader.get("MenuController")
	queue = Loader.get("QueueController")
end

function HubIntroController:start()
	if not menu.isHubServer() then
		return
	end
	roundState = menu.roundState()
	task.spawn(function()
		local dueSince: number? = nil
		while true do
			task.wait(POLL)
			roundState = menu.roundState()
			if open or not due() then
				dueSince = nil
			elseif dueSince == nil then
				dueSince = os.clock()
			elseif os.clock() - dueSince >= SETTLE then
				dueSince = nil
				open = true
				showCard(1)
			end
		end
	end)
end

return HubIntroController
