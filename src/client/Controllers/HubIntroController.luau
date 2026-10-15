--!strict
-- The hub tutorial (tutorial v2, docs/onboarding.md "Tutorial v2"): on
-- a player's first visit to the Hub, OnboardingLogic.HUB_STEPS in order.
-- The welcome card first (with Skip), and last "press Play", with the
-- screen dimmed and only Play lit (C.Spotlight). That Play tap queues
-- the guided round (QueueController.armTutorial).
--
-- Display-only, like the tips. `introSeen` is a saved setting so the
-- tutorial doesn't come back on the next join; a client that fakes it
-- only changes its own screen. The reward is the server's call
-- (DataService.claimTutorialReward, on finishing the guided round).
--
-- `introSeen` is set when the flow ends: Skip (or closing the welcome),
-- or Play. A player who leaves halfway sees it again next time.
-- Skip points at the Play button and gives nothing; Settings' "Show the
-- intro" sets introSeen back to false, and it opens again from the top.

local ContentProvider = game:GetService("ContentProvider")
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

local function closeStep()
	if closeCurrent then
		closeCurrent()
		closeCurrent = nil
	end
end

-- Ends the flow. `played`: the player pressed Play, and is queued for
-- the guided round. Otherwise they skipped.
local function finish(played: boolean)
	closeStep()
	open = false
	queue.armTutorial(false)
	settings.change({ introSeen = true })
	if not played then
		queue.pointAtPlay()
	end
end

local showStep: (number) -> ()

local function showCard(index: number, step: OnboardingLogic.HubStep)
	local picture = step.picture
	local actions = {
		{
			label = OnboardingLogic.HUB_BUTTONS.next,
			onActivate = function()
				closeStep()
				showStep(index + 1)
			end,
		},
	}
	closeCurrent = C.Modal.open({
		title = step.title,
		body = step.body,
		content = if picture ~= 0
			then function()
				return C.Modal.picture(picture)
			end
			else nil,
		bodyLines = 2,
		actions = actions,
		-- Skip is a small text link in the corner, Next centred (owner).
		corner = if step.skip
			then {
				label = OnboardingLogic.HUB_BUTTONS.skip,
				onActivate = function()
					finish(false)
				end,
			}
			else nil,
		-- Closing a card that can skip is a skip; one that can't just
		-- carries on, so there's no way to strand the flow halfway.
		dismissible = step.skip == true,
		onDismiss = function()
			finish(false)
		end,
	})
end

-- The "press Play" step: ends when the player is in the queue. The tap
-- itself goes to the real Play button, armed to queue the guided round.
local function showPlay(step: OnboardingLogic.HubStep)
	queue.armTutorial(true)
	closeCurrent = C.Spotlight.open({
		target = queue.playButton,
		title = step.title,
		body = step.body,
	})
	task.spawn(function()
		while open and not queue.queued() do
			task.wait(0.1)
		end
		if open then
			finish(true)
		end
	end)
end

function showStep(index: number)
	local step = OnboardingLogic.HUB_STEPS[index]
	if step == nil then
		finish(false)
	elseif step.kind == "card" then
		showCard(index, step)
	elseif step.target == "play" then
		showPlay(step)
	else
		-- A spotlight step this build can't draw yet: skip it.
		showStep(index + 1)
	end
end

-- Fetches the pictures while the Hub settles, so each card opens with
-- its picture already drawn rather than popping in a beat later.
local function preloadPictures()
	local ids: { string } = {}
	for _, step in OnboardingLogic.HUB_STEPS do
		if step.picture ~= 0 then
			table.insert(ids, string.format("rbxassetid://%d", step.picture))
		end
	end
	if #ids > 0 then
		pcall(ContentProvider.PreloadAsync, ContentProvider, ids)
	end
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
		local preloaded = false
		local dueSince: number? = nil
		while true do
			task.wait(POLL)
			roundState = menu.roundState()
			if open or not due() then
				dueSince = nil
			elseif dueSince == nil then
				dueSince = os.clock()
				if not preloaded then
					preloaded = true
					task.spawn(preloadPictures)
				end
			elseif os.clock() - dueSince >= SETTLE then
				dueSince = nil
				open = true
				showStep(1)
			end
		end
	end)
end

return HubIntroController
