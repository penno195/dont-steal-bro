--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- First-round tips (P6-8, docs/onboarding.md). Listens to the same round
-- events the HUD and the Studio do, feeds them to OnboardingLogic, and
-- draws the one tip it says is showing. Nothing here touches gameplay:
-- tips are display-only, so a client that spoofs or hides them changes
-- nothing but its own screen.
--
-- THE CARD: top-right corner (below the info bar in portrait), out of
-- the middle of the view where it used to sit in the way of play (moved
-- after a 2026-09-25 playtest). Clear of the bottom thumb zone, so it
-- never covers a control and never blocks movement (only the card
-- itself takes input). Tap it to close
-- it, or it leaves on its own after OnboardingLogic.readSeconds. It
-- never takes gamepad focus: mid-race the stick is steering.
--
-- ON / OFF: the `tips` setting (SettingsLogic). Once the player has seen
-- the whole loop, the tips switch themselves off at the end of the
-- round. Turning them back on in Settings replays them from the start.
--
-- THE GUIDED ROUND (tutorial seam 4): in the tutorial round (Workspace
-- TutorialMatch, set by TutorialService) the tips stand down, so a
-- first real round still gets them. Each step (OnboardingLogic.STEPS)
-- first opens as a pop-up in the middle of a dimmed screen, with its
-- picture, and the round is frozen until "Got it" (TutorialPause;
-- TutorialService stops the bots and holds the player). Then the same
-- corner card keeps the step up as a reminder until the player has done
-- it, whatever the tips setting says (owner, 2026-10-15). A finalist
-- gets How it works on their own as the Studio's talking starts, before
-- they pick.
--
-- Tutorial v2 (owner, 2026-10-15): the "Use your Freeze" step waits for
-- a bot in reach after the first task, then keeps the round frozen
-- past "Got it" until the Freeze is fired (a player holding no Freeze
-- by then skips it). In the Studio, How it works and the Negotiate and
-- Choose cards pause its clock while up, and their button glows after
-- GameConfig.tutorial.explainerGlowSeconds. Every reason to pause is a
-- `hold`; TutorialPause goes out when the first starts and the last
-- ends, and the server applies it to whichever part of the round it is.
--
-- THE HUB TUTORIAL borrows the same corner card (`remind`): after one of
-- its step cards, the step stays up there until the player has done it.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local vide = require(ReplicatedStorage.Packages.Vide)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local C = require(script.Parent.Parent.UI.Components)
local Base = require(script.Parent.Parent.UI.Components.Base)
local HudLogic = require(script.Parent.Parent.UI.HudLogic)
local Layout = require(script.Parent.Parent.UI.Layout)
local OnboardingLogic = require(script.Parent.Parent.UI.OnboardingLogic)
local PayoffExplainer = require(script.Parent.Parent.UI.Screens.PayoffExplainer)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIScaleController = require(script.Parent.UIScaleController)

local create = vide.create
local derive = vide.derive
local source = vide.source

local Env = C.Env
local selfId = Players.LocalPlayer.UserId

local CARD_WIDTH = 200 -- was 260; cut after the 2026-09-29 playtest, it covered too much of the view
local CARD_PAD = Theme.spacing.sm
-- Portrait's top-centre info bar spans the full width, so there the
-- card drops below it (Layout.THUMB_ZONES: Info is the top 16%).
local PORTRAIT_TOP = 0.16

local portrait: Base.Source<boolean> & ((boolean) -> boolean) = source(false) :: any

-- Round state -> OnboardingLogic.Stage. States not listed have no tips.
local STAGE_OF_ROUND: { [string]: string } = {
	Race = "Race",
	Qualified = "Studio",
	DecisionStudio = "Studio",
	Results = "Results",
}

local state = OnboardingLogic.new()
local showing = source(nil :: OnboardingLogic.Tip?)
local enabled = false
-- nil until this round's DecisionParticipants arrives.
local isFinalist: boolean? = nil
local seats = 3
local timerToken = 0

-- The guided round's steps. Shown only during its race.
local steps = OnboardingLogic.newSteps()
local step = source(nil :: OnboardingLogic.Step?)
local racing = false
local explained = false -- How it works has opened by itself this round
-- Steps whose pop-up has been read ("Got it") this round, and the one up.
local acked: { [string]: boolean } = {}
local popupId = source(nil :: string?)
-- The hub tutorial's current step, set by HubIntroController.
local hubReminder = source(nil :: { title: string, body: string }?)
local closePopup: (() -> ())? = nil
-- Gated steps (OnboardingLogic.Step.gate) whose gate has opened.
local opened: { [string]: boolean } = {}
local holdsFreeze = false
-- A bot this close (studs) opens the Freeze step: a little inside the
-- power-up's reach, so the lock-on still finds it.
local BOT_REACH = GameConfig.powerUpUseRangeStuds - GameConfig.powerUpLockOnSlackStuds
local GATE_POLL_SECONDS = 0.25
-- After the Freeze is fired the round runs this long before the next
-- pop-up, so the player sees it land (the hub tutorial's pause after
-- firing, owner 2026-10-15).
local FIRE_DELAY = 3
local firedAt: number? = nil
-- The Studio cards: the one up, and the phases already shown this round.
local closeStudioCard: (() -> ())? = nil
local studioCardsShown: { [string]: boolean } = {}

local function isTutorial(): boolean
	return Workspace:GetAttribute("TutorialMatch") == true
end

-- Why the round is paused right now (tutorial only), by reason.
local holds: { [string]: boolean } = {}

local function anyHold(): boolean
	return next(holds) ~= nil
end

local function setHold(reason: string, on: boolean)
	if (holds[reason] == true) == on then
		return
	end
	local before = anyHold()
	if on then
		holds[reason] = true
	else
		holds[reason] = nil
	end
	if anyHold() ~= before then
		Net.fireServer("TutorialPause", { paused = on })
	end
end

local dismiss: () -> ()

local function hidePopup()
	if closePopup ~= nil then
		closePopup()
		closePopup = nil
	end
	if popupId() ~= nil then
		popupId(nil)
	end
	setHold("popup", false)
end

-- A step not yet read gets its pop-up, and the round freezes under it.
-- One that's done or read by other means (it latched) just closes.
local function syncPopup(current: OnboardingLogic.Step?)
	if current ~= nil and acked[current.id] then
		current = nil
	end
	if current == nil then
		hidePopup()
		return
	end
	if popupId() == current.id then
		return
	end
	if closePopup ~= nil then
		closePopup()
	end
	local id = current.id
	local function gotIt()
		if popupId() == id then
			acked[id] = true
			hidePopup()
		end
	end
	local picture = current.picture
	closePopup = C.Modal.open({
		title = current.title,
		body = current.body,
		lead = true,
		content = if picture ~= 0
			then function()
				return C.Modal.picture(picture)
			end
			else nil,
		actions = { { label = "Got it", onActivate = gotIt } },
		dismissible = true,
		onDismiss = gotIt,
	})
	setHold("popup", true)
	popupId(id)
end

local function sync()
	local tutorial = isTutorial()
	local current = if tutorial and racing then OnboardingLogic.currentStep(steps) else nil
	-- A gated step shows nothing, not even the corner card, until its
	-- gate opens.
	if current ~= nil and current.gate ~= nil and not opened[current.id] then
		current = nil
	end
	if firedAt ~= nil and os.clock() - firedAt < FIRE_DELAY then
		current = nil
	end
	step(current)
	syncPopup(current)
	setHold("step", current ~= nil and current.holdUntilDone == true)
	local id = if enabled and not tutorial then state.showing else nil
	local tip = if id then OnboardingLogic.tip(id) else nil
	showing(tip)
	timerToken += 1
	if tip ~= nil then
		local mine = timerToken
		task.delay(OnboardingLogic.readSeconds(tip), function()
			if mine == timerToken then
				dismiss()
			end
		end)
	end
end

dismiss = function()
	OnboardingLogic.dismiss(state)
	sync()
end

local function trigger(id: OnboardingLogic.TipId)
	if not enabled or isTutorial() then
		return
	end
	OnboardingLogic.trigger(state, id)
	sync()
end

local function openExplainer()
	dismiss()
	PayoffExplainer.open(seats)
end

local function completeStep(id: OnboardingLogic.StepId)
	if isTutorial() and not steps[id] then
		OnboardingLogic.completeStep(steps, id)
		sync()
	end
end

-- Is any bot within BOT_REACH of the player?
local function botNear(): boolean
	local character = Players.LocalPlayer.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local folder = Workspace:FindFirstChild("NPCs")
	if root == nil or not root:IsA("BasePart") or folder == nil then
		return false
	end
	local distances: { number } = {}
	for _, bot in folder:GetChildren() do
		if bot:IsA("Model") then
			table.insert(distances, (bot:GetPivot().Position - root.Position).Magnitude)
		end
	end
	return OnboardingLogic.botInReach(distances, BOT_REACH)
end

-- The Freeze step's gate. Its pop-up opens when a bot is in reach; a
-- player with no Freeze left by then (or after) skips it, so the round
-- is never held for an item they can't fire.
local function pollGate()
	if not (isTutorial() and racing) then
		return
	end
	local current = OnboardingLogic.currentStep(steps)
	if current == nil or current.gate ~= "botNear" then
		return
	end
	if not holdsFreeze then
		if opened[current.id] or botNear() then
			completeStep(current.id)
		end
	elseif not opened[current.id] and botNear() then
		opened[current.id] = true
		sync()
	end
end

-- The guided round's Negotiate and Choose cards, once each, with the
-- clock paused while up. At Negotiate it follows How it works.
local function showStudioCard(phase: string)
	local cardCopy = OnboardingLogic.STUDIO_CARDS[phase]
	if cardCopy == nil or studioCardsShown[phase] then
		return
	end
	studioCardsShown[phase] = true
	if closeStudioCard ~= nil then
		closeStudioCard()
	end
	local close: () -> ()
	local function gotIt()
		close()
	end
	local modalClose = C.Modal.open({
		title = cardCopy.title,
		body = cardCopy.body,
		lead = true,
		actions = {
			{ label = "Got it", onActivate = gotIt, glowAfter = GameConfig.tutorial.explainerGlowSeconds },
		},
		dismissible = true,
		onDismiss = gotIt,
	})
	close = function()
		modalClose()
		if closeStudioCard == close then
			closeStudioCard = nil
			setHold("studioCard", false)
		end
	end
	closeStudioCard = close
	setHold("studioCard", true)
end

-- The whole card is the close button: one big target, no hunting for an
-- X. The inner "How it works" button sits on top and takes its own taps.
-- Not Selectable: a gamepad player's tip just times out. A step prompt
-- uses the same card but ignores taps: it waits for the player.
local function card(): TextButton
	local tip = derive(function(): { title: string, body: string, action: "explainer"? }?
		local tipShown, stepShown = showing(), step()
		if tipShown ~= nil then
			return tipShown
		end
		local reminder = hubReminder()
		if reminder ~= nil then
			return { title = reminder.title, body = reminder.body }
		end
		-- The corner reminder waits until the step's pop-up is read.
		if popupId() ~= nil then
			return nil
		end
		return if stepShown then { title = stepShown.title, body = stepShown.body } else nil
	end)
	return create("TextButton")({
		Name = "TipCard",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		Activated = function()
			if showing() ~= nil then
				dismiss()
			end
		end,
		AnchorPoint = Vector2.new(1, 0),
		Position = function()
			return UDim2.new(1, -Theme.spacing.md, if portrait() then PORTRAIT_TOP else 0, Theme.spacing.md)
		end,
		Size = UDim2.fromOffset(CARD_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Base.STAGE_BACKGROUND,
		Visible = function()
			return tip() ~= nil
		end,
		Base.corner(Theme.radius.lg),
		Base.stage({ rim = Theme.color.brand, thickness = 3 }),
		Base.padding(CARD_PAD),
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.xxs),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
		Base.text("label", {
			Name = "Title",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.type.label.size + Theme.spacing.xxs),
			Text = function()
				local t = tip()
				return if t then t.title else ""
			end,
		}),
		Base.text("body", {
			Name = "Body",
			LayoutOrder = 2,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextScaled = false,
			TextSize = Theme.type.caption.size,
			TextColor3 = Theme.color.inkMuted,
			Text = function()
				local t = tip()
				return if t then t.body else ""
			end,
		}),
		create("Frame")({
			Name = "ActionSlot",
			LayoutOrder = 3,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, Theme.touch.primaryHeight),
			Visible = function()
				local t = tip()
				return t ~= nil and t.action == "explainer"
			end,
			C.Button({
				label = "How it works",
				icon = "info",
				variant = "secondary",
				width = CARD_WIDTH - 2 * CARD_PAD,
				onActivate = openExplainer,
				anchorPoint = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(0.5, 0.5),
			}),
		}),
	}) :: TextButton
end

local function mount()
	local gui = UIScaleController.createScreen("Tips", { displayOrder = Theme.displayOrder.hud + 5 })
	local function setOrientation(usable: Layout.Rect)
		portrait(Layout.orientationOf(usable.width, usable.height) == "Portrait")
	end
	setOrientation(UIScaleController.getUsableRect())
	UIScaleController.observeUsableRect(setOrientation)
	vide.root(function()
		local root = card()
		root.Parent = gui
		UIScaleController.attachScale(root)
	end)
end

local function onRoundState(payload: any)
	-- Set before the stage's sync below, which shows the first step.
	racing = payload.state == "Race"
	if payload.state == "Loading" then
		steps = OnboardingLogic.newSteps()
		acked = {}
		opened = {}
		firedAt = nil
		explained = false
		studioCardsShown = {}
	end
	-- Studio pop-ups never outlive the Studio.
	if payload.state ~= "DecisionStudio" and payload.state ~= "Qualified" and closeStudioCard ~= nil then
		closeStudioCard()
	end
	local stage = STAGE_OF_ROUND[payload.state]
	if stage ~= state.stage then
		OnboardingLogic.enterStage(state, stage)
		sync()
	end
	if payload.state == "Race" then
		isFinalist = nil
		trigger("race")
	elseif stage == "Studio" and isFinalist ~= nil then
		-- DecisionParticipants can land before the Studio stage starts,
		-- when a trigger would still be ignored as out of stage.
		trigger(if isFinalist then "finale" else "missed")
	elseif payload.state == "Results" then
		trigger("streak")
	elseif stage == nil and enabled and state.seen.race then
		-- The round is over. Taught the loop: tips off for good (until
		-- the player turns them back on). Otherwise keep them, and start
		-- the next round fresh.
		if OnboardingLogic.loopTaught(state) then
			local settings = Loader.get("SettingsController") :: any
			settings.change({ tips = false })
		end
		state = OnboardingLogic.new()
		sync()
	end
end

local OnboardingController: Loader.Controller = {
	name = "OnboardingController",
	dependencies = { "SettingsController", "UIScaleController" },
}

function OnboardingController:init()
	Net.onClientEvent("RoundState", onRoundState)

	Net.onClientEvent("PowerUpInventoryChanged", function(payload: any)
		if type(payload.inventory) == "table" and payload.inventory[1] ~= nil then
			trigger("powerUp")
		end
		local held = false
		for _, item in (if type(payload.inventory) == "table" then payload.inventory else {}) :: { any } do
			held = held or item.powerUpId == GameConfig.tutorial.lockerGiftPowerUpId
		end
		holdsFreeze = held
		pollGate()
	end)

	-- The guided round's steps. A station's prompt showing means they
	-- reached it, so "Do the task" pops up before the mini-game opens,
	-- never over it. A task view opening says the same, as a backstop.
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if prompt.Name == "TaskInteractPrompt" then
			completeStep("station")
		end
	end)
	Net.onClientEvent("TaskChallenge", function()
		completeStep("station")
	end)
	Net.onClientEvent("TaskAssignmentState", function(payload: any)
		local assignments = (payload.assignments or {}) :: { any }
		local done = 0
		for _, entry in assignments do
			if entry.completed then
				done += 1
			end
		end
		if done > 0 then
			completeStep("task")
		end
		if done > 0 and done == #assignments then
			completeStep("finish")
		end
	end)
	-- Firing the Freeze counts, whether it lands or not (owner).
	Net.onClientEvent("PowerUpUseResult", function(payload: any)
		if payload.success == true and payload.powerUpId == GameConfig.tutorial.lockerGiftPowerUpId then
			if isTutorial() and racing and not steps.freeze then
				firedAt = os.clock()
				task.delay(FIRE_DELAY, sync)
			end
			completeStep("freeze")
		end
	end)

	-- Targeted at this player only (Net.luau), so any debuff is ours.
	Net.onClientEvent("StatusEffectsChanged", function(payload: any)
		for _, entry in (payload.effects or {}) :: { any } do
			if entry.kind ~= "Buff" then
				trigger("hit")
				return
			end
		end
	end)

	-- The line tip waits until someone has actually finished a task:
	-- at the start everyone is level on 0, which reads as "on the line".
	Net.onClientEvent("TaskProgress", function(payload: any)
		local progress = (payload.progress or {}) :: { HudLogic.ProgressEntry }
		local anyDone = false
		for _, entry in progress do
			anyDone = anyDone or entry.tasksCompleted > 0
		end
		local line = HudLogic.lineState(HudLogic.standing(progress, selfId, GameConfig.qualifierCount))
		if anyDone and (line == "edge" or line == "out") then
			trigger("line")
		end
	end)

	Net.onClientEvent("DecisionParticipants", function(payload: any)
		local ids = (payload.qualifierIds or {}) :: { any }
		local finalist = table.find(ids, selfId) ~= nil
		isFinalist = finalist
		seats = math.max(#ids, 1)
		trigger(if finalist then "finale" else "missed")
	end)

	Net.onClientEvent("DecisionPhaseChanged", function(payload: any)
		if isFinalist ~= true then
			return
		end
		local phase = payload.phase
		local running = phase == "Negotiate" or phase == "Choose"
		-- A pause asked for before the clock could stop (an explainer
		-- opened in the Intro) is asked again once it can.
		if isTutorial() and running and payload.endsAt ~= nil and anyHold() then
			Net.fireServer("TutorialPause", { paused = true })
		end
		-- The guided round: How it works opens by itself before they
		-- pick, then the phase's card.
		if isTutorial() and running then
			if not explained then
				explained = true
				PayoffExplainer.open(seats, function()
					showStudioCard(phase)
				end)
			elseif not studioCardsShown[phase] and not anyHold() then
				showStudioCard(phase)
			end
		end
		if payload.phase == "Negotiate" then
			trigger("negotiate")
		elseif payload.phase == "Choose" then
			trigger("choose")
		end
	end)
end

-- Keeps a hub tutorial step in the corner card, or clears it (nil).
function OnboardingController.remind(title: string?, body: string?)
	hubReminder(if title ~= nil and body ~= nil then { title = title, body = body } else nil)
end

local function syncTutorial()
	PayoffExplainer.setTutorial(if isTutorial()
		then {
			glowAfter = GameConfig.tutorial.explainerGlowSeconds,
			onOpen = function()
				setHold("explainer", true)
			end,
			onClose = function()
				setHold("explainer", false)
			end,
		}
		else nil)
	sync()
end

function OnboardingController:start()
	mount()
	Workspace:GetAttributeChangedSignal("TutorialMatch"):Connect(syncTutorial)
	syncTutorial()
	task.spawn(function()
		while true do
			task.wait(GATE_POLL_SECONDS)
			pollGate()
		end
	end)
	-- Follows the setting. Turning tips back on replays them.
	local settings = Loader.get("SettingsController") :: any
	Env.observe(function(): boolean
		return settings.loaded() and settings.settings().tips
	end, function(on: boolean)
		if on and not enabled then
			local stage = state.stage
			state = OnboardingLogic.new()
			OnboardingLogic.enterStage(state, stage)
		end
		enabled = on
		sync()
	end)
end

return OnboardingController
