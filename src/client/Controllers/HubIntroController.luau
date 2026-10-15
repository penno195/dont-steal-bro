--!strict
-- The hub tutorial (tutorial v2, docs/onboarding.md "Tutorial v2"): on
-- a player's first visit to the Hub, OnboardingLogic.HUB_STEPS in order.
-- The welcome card first (with Skip), then the practice area: a
-- personal power-up to grab (TutorialPickupController) and fire at a
-- dummy, then the practice task station. Then the Locker: its button
-- lit (C.Spotlight), a free power-up given as it opens
-- (TutorialGiftIntent), its tile lit until it's in the loadout, then
-- the close button. Last "press Play", with only Play lit. That Play
-- tap queues the guided round (QueueController.armTutorial).
--
-- A card with `waitFor` is read and closed, then stays up in the corner
-- card (OnboardingController.remind) until the player has done it. What
-- counts as done is OnboardingLogic.hubWaitDone, fed from the same
-- events the HUD hears.
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

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local C = require(script.Parent.Parent.UI.Components)
local OnboardingLogic = require(script.Parent.Parent.UI.OnboardingLogic)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)

-- How often to check whether the intro is due, and how long to let the
-- Hub settle (character in, loading screen gone) before it opens.
local POLL = 1
local SETTLE = 1.5
-- How often a waiting step checks whether it's done.
local WAIT_POLL = 0.2
-- With no pickup from the server by then (no practice area on this
-- server), the power-up steps are skipped rather than left hanging.
local PICKUP_TIMEOUT = 8
-- A done step's pause before the next pop-up (owner, 2026-10-15).
local NEXT_DELAY = 2
-- How long the Locker's gift card waits for the server's answer (and
-- the stock it brings) before skipping itself.
local GIFT_TIMEOUT = 6
local SPOTLIGHT_POLL = 0.1
local PRACTICE_TAG = "HubPracticeTask"
local GIFT_ID = GameConfig.tutorial.lockerGiftPowerUpId

local settings: any
local menu: any
local queue: any
local onboarding: any
local pickups: any

local aimedIds: { [string]: boolean } = {}
for _, entry in PowerUps do
	if entry.def.target == "Aimed" then
		aimedIds[entry.def.id] = true
	end
end

-- What the waiting steps check (OnboardingLogic.HubFacts). holdsAimed
-- follows the live state; used, opened and solved latch, and are reset
-- as the step that waits on them begins.
local facts: OnboardingLogic.HubFacts = { holdsAimed = false, used = false, opened = false, solved = false }
local pickupOffered = false -- the server sent this player a pickup
-- What the step in the corner card is waiting for, if any.
local waiting: OnboardingLogic.HubWait? = nil
-- The server's answer to this flow's TutorialGiftIntent: nil = none yet.
local giftGranted: boolean? = nil

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
	waiting = nil
	TaskViewBase.hold(false)
	onboarding.remind(nil, nil)
	pickups.clear()
	queue.armTutorial(false)
	settings.change({ introSeen = true })
	if not played then
		queue.pointAtPlay()
	end
end

local showStep: (number) -> ()

-- After a waiting card is read: the step sits in the corner card until
-- it's done, then the next one opens NEXT_DELAY later, so the player
-- sees what they did (a power-up landing) before the next pop-up.
local function awaitStep(index: number, step: OnboardingLogic.HubStep)
	onboarding.remind(step.title, step.body)
	waiting = step.waitFor
	local started = os.clock()
	task.spawn(function()
		local nextIndex = index + 1
		while open do
			if OnboardingLogic.hubWaitDone(step.waitFor, facts) then
				break
			end
			-- No practice area answered: the power-up steps can't happen.
			if step.waitFor == "pickup" and not pickupOffered and os.clock() - started > PICKUP_TIMEOUT then
				nextIndex = index + 2 -- skips "aim" too
				break
			end
			task.wait(WAIT_POLL)
		end
		waiting = nil
		if open then
			onboarding.remind(nil, nil)
			task.wait(NEXT_DELAY)
		end
		if open then
			showStep(nextIndex)
		end
	end)
end

local function showCard(index: number, step: OnboardingLogic.HubStep)
	local picture = step.picture
	if step.waitFor == "pickup" then
		pickups.request()
	elseif step.waitFor == "use" then
		facts.used = false
	elseif step.waitFor == "station" then
		facts.opened = false
		facts.solved = false
	end
	local actions = {
		{
			label = OnboardingLogic.HUB_BUTTONS.next,
			onActivate = function()
				closeStep()
				-- The task under this card starts now (see listen).
				TaskViewBase.hold(false)
				if step.waitFor ~= nil then
					awaitStep(index, step)
				else
					showStep(index + 1)
				end
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
		-- Short copy gives a line back to the picture.
		bodyLines = if #step.body > 90 then 3 else 2,
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

-- How the spotlight steps stand right now (OnboardingLogic.SpotlightFacts).
local function spotlightFacts(): OnboardingLogic.SpotlightFacts
	local s = menu.storeState()
	local stock, loaded, full = 0, false, false
	if s ~= nil then
		stock = s.powerUpStock[GIFT_ID] or 0
		loaded = table.find(s.loadout, GIFT_ID) ~= nil
		full = #s.loadout >= s.loadoutSlots
	end
	return {
		lockerOpen = menu.currentMenu() == "Locker",
		giftStock = stock,
		giftLoaded = loaded,
		loadoutFull = full,
		queued = queue.queued(),
	}
end

-- Drawn, and not inside something hidden: a GuiObject in a hidden
-- frame keeps its AbsoluteSize, and the spotlight would ring nothing.
local function onScreen(gui: GuiObject?): GuiObject?
	local node: Instance? = gui
	while node ~= nil do
		if node:IsA("GuiObject") and not node.Visible then
			return nil
		elseif node:IsA("LayerCollector") then
			return if node.Enabled then gui else nil
		end
		node = node.Parent
	end
	return nil
end

local function lockerScreen(): Instance?
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	return if playerGui then playerGui:FindFirstChild("LockerScreen") else nil
end

-- The GuiObject a spotlight lights. The Locker's own parts are found by
-- name: the gift's tile by its PowerUpId attribute (Locker.stockCard),
-- the close button in MenuShell's header.
local function targetGui(target: OnboardingLogic.HubTarget): GuiObject?
	if target == "play" then
		return queue.playButton()
	elseif target == "locker" then
		return onScreen(menu.lockerButton())
	end
	local screen = lockerScreen()
	if screen == nil then
		return nil
	end
	if target == "gift" then
		for _, gui in screen:GetDescendants() do
			if gui:IsA("GuiObject") and gui:GetAttribute("PowerUpId") == GIFT_ID then
				return onScreen(gui)
			end
		end
		return nil
	end
	local header = screen:FindFirstChild("Header", true)
	local close = if header then header:FindFirstChild("IconButton") else nil
	return if close and close:IsA("GuiObject") then onScreen(close) else nil
end

-- A spotlight step: ends when OnboardingLogic.spotlightDone says so.
-- "press Play" ends the flow, its tap having gone to the real Play
-- button, armed to queue the guided round. The others go on to the
-- next step NEXT_DELAY later.
local function showSpotlight(index: number, step: OnboardingLogic.HubStep)
	-- (Cast: the frozen step table widens its literals to string.)
	local target: OnboardingLogic.HubTarget = step.target :: any
	if target == "play" then
		queue.armTutorial(true)
	end
	closeCurrent = C.Spotlight.open({
		target = function()
			return targetGui(OnboardingLogic.spotlightAim(target, spotlightFacts()))
		end,
		title = step.title,
		body = step.body,
	})
	task.spawn(function()
		while open and not OnboardingLogic.spotlightDone(target, spotlightFacts()) do
			task.wait(SPOTLIGHT_POLL)
		end
		if not open then
			return
		elseif target == "play" then
			finish(true)
			return
		end
		closeStep()
		task.wait(NEXT_DELAY)
		if open then
			showStep(index + 1)
		end
	end)
end

-- The Locker's gift card: asks the server for the free power-up, and
-- shows only if it was given just now, once the stock it brings has
-- arrived (else the next step would see none and skip itself). Not
-- given (already had it, a replay): straight on.
local function showGift(index: number, step: OnboardingLogic.HubStep)
	giftGranted = nil
	Net.fireServer("TutorialGiftIntent", {})
	task.spawn(function()
		local started = os.clock()
		while open and os.clock() - started < GIFT_TIMEOUT do
			if giftGranted == false or (giftGranted == true and spotlightFacts().giftStock > 0) then
				break
			end
			task.wait(WAIT_POLL)
		end
		if not open then
			return
		elseif giftGranted == true then
			showCard(index, step)
		else
			showStep(index + 1)
		end
	end)
end

function showStep(index: number)
	local step = OnboardingLogic.HUB_STEPS[index]
	if step == nil then
		finish(false)
	elseif step.gift then
		showGift(index, step)
	elseif step.kind == "card" then
		showCard(index, step)
	else
		showSpotlight(index, step)
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

local function isPracticeStation(stationId: any): boolean
	for _, part in CollectionService:GetTagged(PRACTICE_TAG) do
		if part:GetAttribute("StationId") == stationId then
			return true
		end
	end
	return false
end

-- Feeds `facts` from the same events the HUD and tips hear. Cheap, and
-- harmless outside the tutorial: nothing reads them then.
local function listen()
	Net.onClientEvent("PowerUpInventoryChanged", function(payload: any)
		local held = false
		for _, item in (if type(payload.inventory) == "table" then payload.inventory else {}) :: { any } do
			held = held or aimedIds[item.powerUpId] == true
		end
		facts.holdsAimed = held
	end)
	Net.onClientEvent("PowerUpUseResult", function(payload: any)
		if payload.success == true then
			facts.used = true
		end
	end)
	-- Firing is what the step teaches, landed or not: a Task Scramble
	-- thrown at a dummy (which has no task) is spent but not "applied".
	Net.onClientEvent("PowerUpThrown", function(payload: any)
		if payload.casterId == Players.LocalPlayer.UserId then
			facts.used = true
		end
	end)
	Net.onClientEvent("TutorialGiftResult", function(payload: any)
		if type(payload) == "table" then
			giftGranted = payload.granted == true
		end
	end)
	Net.onClientEvent("TutorialPickupState", function(payload: any)
		if type(payload) == "table" and payload.position ~= nil then
			pickupOffered = true
		end
	end)
	-- Opening the task ends the station step, and "Do the task" then
	-- pops up over it (owner, 2026-10-15). Until that card is read the
	-- task holds its start, so Code Playback's flash isn't hidden.
	Net.onClientEvent("TaskChallenge", function(payload: any)
		if isPracticeStation(payload.stationId) then
			facts.opened = true
			if open and waiting == "station" then
				TaskViewBase.hold(true)
			end
		end
	end)
	Net.onClientEvent("TaskResult", function(payload: any)
		if payload.success == true and isPracticeStation(payload.stationId) then
			facts.solved = true
		end
	end)
end

local HubIntroController: Loader.Controller = {
	name = "HubIntroController",
	dependencies = {
		"SettingsController",
		"MenuController",
		"QueueController",
		"UIScaleController",
		"OnboardingController",
		"TutorialPickupController",
	},
}

function HubIntroController:init()
	settings = Loader.get("SettingsController")
	menu = Loader.get("MenuController")
	queue = Loader.get("QueueController")
	onboarding = Loader.get("OnboardingController")
	pickups = Loader.get("TutorialPickupController")
end

function HubIntroController:start()
	if not menu.isHubServer() then
		return
	end
	listen()
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
