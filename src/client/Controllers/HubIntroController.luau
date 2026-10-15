--!strict
-- The hub tutorial (tutorial v2, docs/onboarding.md "Tutorial v2"): on
-- a player's first visit to the Hub, OnboardingLogic.HUB_STEPS in order.
-- The welcome card first (with Skip), then the practice area: a
-- personal power-up to grab (TutorialPickupController) and fire at a
-- dummy, then the practice task station. Last "press Play", with the
-- screen dimmed and only Play lit (C.Spotlight). That Play tap queues
-- the guided round (QueueController.armTutorial).
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
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local C = require(script.Parent.Parent.UI.Components)
local OnboardingLogic = require(script.Parent.Parent.UI.OnboardingLogic)

-- How often to check whether the intro is due, and how long to let the
-- Hub settle (character in, loading screen gone) before it opens.
local POLL = 1
local SETTLE = 1.5
-- How often a waiting step checks whether it's done.
local WAIT_POLL = 0.2
-- With no pickup from the server by then (no practice area on this
-- server), the power-up steps are skipped rather than left hanging.
local PICKUP_TIMEOUT = 8
local PRACTICE_TAG = "HubPracticeTask"

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
-- and atStation follow the live state; used and solved latch, and are
-- reset as the step that waits on them begins.
local facts: OnboardingLogic.HubFacts = { holdsAimed = false, used = false, atStation = false, solved = false }
local pickupOffered = false -- the server sent this player a pickup

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
-- it's done, then the next one opens.
local function awaitStep(index: number, step: OnboardingLogic.HubStep)
	onboarding.remind(step.title, step.body)
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
		if open then
			onboarding.remind(nil, nil)
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
		facts.solved = false
	end
	local actions = {
		{
			label = OnboardingLogic.HUB_BUTTONS.next,
			onActivate = function()
				closeStep()
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

local function isPracticeStation(stationId: any): boolean
	for _, part in CollectionService:GetTagged(PRACTICE_TAG) do
		if part:GetAttribute("StationId") == stationId then
			return true
		end
	end
	return false
end

local function isPracticePrompt(prompt: ProximityPrompt): boolean
	local parent = prompt.Parent
	return prompt.Name == "TaskInteractPrompt" and parent ~= nil and CollectionService:HasTag(parent, PRACTICE_TAG)
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
	Net.onClientEvent("TutorialPickupState", function(payload: any)
		if type(payload) == "table" and payload.position ~= nil then
			pickupOffered = true
		end
	end)
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if isPracticePrompt(prompt) then
			facts.atStation = true
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		if isPracticePrompt(prompt) then
			facts.atStation = false
		end
	end)
	-- Opening it counts as getting there; solving it is the task step.
	Net.onClientEvent("TaskChallenge", function(payload: any)
		if isPracticeStation(payload.stationId) then
			facts.atStation = true
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
