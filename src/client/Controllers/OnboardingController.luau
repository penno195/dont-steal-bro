--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- First-round tips (P6-8, docs/onboarding.md). Listens to the same round
-- events the HUD and the Studio do, feeds them to OnboardingLogic, and
-- draws the one tip it says is showing. Nothing here touches gameplay:
-- tips are display-only, so a client that spoofs or hides them changes
-- nothing but its own screen.
--
-- THE CARD: upper-middle of the screen, clear of the top-centre info bar
-- and the bottom thumb zone, so it never covers a control and never
-- blocks movement (only the card itself takes input). Tap it to close
-- it, or it leaves on its own after OnboardingLogic.readSeconds. It
-- never takes gamepad focus: mid-race the stick is steering.
--
-- ON / OFF: the `tips` setting (SettingsLogic). Once the player has seen
-- the whole loop, the tips switch themselves off at the end of the
-- round. Turning them back on in Settings replays them from the start.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local C = require(script.Parent.Parent.UI.Components)
local Base = require(script.Parent.Parent.UI.Components.Base)
local HudLogic = require(script.Parent.Parent.UI.HudLogic)
local OnboardingLogic = require(script.Parent.Parent.UI.OnboardingLogic)
local PayoffExplainer = require(script.Parent.Parent.UI.Screens.PayoffExplainer)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIScaleController = require(script.Parent.UIScaleController)

local create = vide.create
local source = vide.source

local Env = C.Env
local selfId = Players.LocalPlayer.UserId

local CARD_WIDTH = 320

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

local dismiss: () -> ()

local function sync()
	local id = if enabled then state.showing else nil
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
	if not enabled then
		return
	end
	OnboardingLogic.trigger(state, id)
	sync()
end

local function openExplainer()
	dismiss()
	PayoffExplainer.open(seats)
end

-- The whole card is the close button: one big target, no hunting for an
-- X. The inner "How it works" button sits on top and takes its own taps.
-- Not Selectable: a gamepad player's tip just times out.
local function card(): TextButton
	local tip = showing
	return create("TextButton")({
		Name = "TipCard",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		Activated = dismiss,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.2),
		Size = UDim2.fromOffset(CARD_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.elevation[3].surface,
		Visible = function()
			return tip() ~= nil
		end,
		Base.corner(Theme.radius.lg),
		create("UIStroke")({ Color = Theme.color.brand, Thickness = 2 }),
		Base.padding(Theme.spacing.md),
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.xs),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
		Base.text("title", {
			Name = "Title",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.type.title.size + Theme.spacing.xxs),
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
			TextSize = Theme.type.body.size,
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
				width = CARD_WIDTH - 2 * Theme.spacing.md,
				onActivate = openExplainer,
				anchorPoint = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(0.5, 0.5),
			}),
		}),
	}) :: TextButton
end

local function mount()
	local gui = UIScaleController.createScreen("Tips", { displayOrder = Theme.displayOrder.hud + 5 })
	vide.root(function()
		local root = card()
		root.Parent = gui
		UIScaleController.attachScale(root)
	end)
end

local function onRoundState(payload: any)
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
		if payload.phase == "Negotiate" then
			trigger("negotiate")
		elseif payload.phase == "Choose" then
			trigger("choose")
		end
	end)
end

function OnboardingController:start()
	mount()
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
