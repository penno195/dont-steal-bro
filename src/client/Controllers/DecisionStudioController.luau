--!strict
-- Feeds the Decision Studio screen (P6-5, UI/Screens/DecisionStudio.luau)
-- and mounts it for the DecisionStudio round state. The screen never
-- touches a remote: every DecisionService payload lands here, is parsed
-- by DecisionLogic, and is written into a Vide source.
--
-- WHAT THIS CLIENT EVER HOLDS, AND WHEN (the P6-5 secrecy audit; the
-- full version is docs/decision-studio.md):
--   - its OWN choice, from the moment its own hold completes. Nobody
--     else's: `locked` is a set of ids, because DecisionLockedIn is only
--     ever {playerId}.
--   - everyone's choices from DecisionReveal, the first and only packet
--     that carries them.
--   - its own streak before/after from DecisionPersonalResult, which the
--     server fires to this player alone, after the reveal.
-- Nothing is written to an Attribute, a ValueObject or anything else
-- that replicates; it's all Lua locals and Vide sources.
--
-- The screen outlives the phase machine on purpose: DecisionService
-- moves the round to Results about a second after the reveal packet, but
-- the reveal plays for DecisionLogic.revealLength seconds. The screen
-- stays up through Results until the player dismisses it or the round
-- leaves Results. A results screen (P6-6) should wait on isActive().

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local vide = require(ReplicatedStorage.Packages.Vide)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local DecisionLogic = require(script.Parent.Parent.UI.DecisionLogic)
local DecisionStudio = require(script.Parent.Parent.UI.Screens.DecisionStudio)
local NPCBubbleController = require(script.Parent.NPCBubbleController)
local StudioChatController = require(script.Parent.StudioChatController)
local UIScaleController = require(script.Parent.UIScaleController)

local source = vide.source

-- Speaking and typing are polled getters (StudioChatController), so they
-- are sampled a few times a second while the screen is up, and written
-- only when something changed.
local TALK_INTERVAL = 0.25

local selfId = Players.LocalPlayer.UserId
local T = DecisionLogic.TIMING

-- Annotated, not inferred: luau-lsp widens a string-literal union
-- inside source() back to `string`, and the Store wants the union.
local phase: DecisionStudio.Settable<DecisionLogic.Phase?> = source(nil)
local endsAt = source(nil :: number?)
local seats = source({} :: { DecisionStudio.Seat })
local isFinalist = source(false)
local locked = source({} :: { [number]: boolean })
local talk: DecisionStudio.Settable<{ [number]: DecisionStudio.Talk }> = source({})
local acked = source(false)
local reveal = source(nil :: DecisionLogic.Reveal?)
local personal = source(nil :: DecisionLogic.Personal?)
local chat = source(nil :: DecisionLogic.Rect?)

local ids: { number } = {}
local reputations: { [number]: DecisionLogic.Reputation } = {}
local leftIds: { [number]: boolean } = {}

local function nameOf(id: number): string
	if id < 0 then
		return NPCBubbleController.getNPCName(id) or "Finalist"
	end
	local player = Players:GetPlayerByUserId(id)
	return if player then player.DisplayName else "Finalist"
end

local function rebuildSeats()
	local list: { DecisionStudio.Seat } = {}
	for _, id in ids do
		table.insert(
			list,
			table.freeze({
				id = id,
				name = nameOf(id),
				isSelf = id == selfId,
				isNPC = id < 0,
				reputation = DecisionLogic.reputationLabel(reputations[id]),
				left = leftIds[id] == true,
			})
		)
	end
	seats(list)
	isFinalist(table.find(ids, selfId) ~= nil)
end

-- Sending: the one intent, then the SAME choice again if the server's
-- echo doesn't come back (a dropped remote). The server keeps the first
-- and silently drops repeats, so a resend can never change anything.
local sendToken = 0
local function send(choice: DecisionLogic.Choice)
	acked(false)
	sendToken += 1
	local token = sendToken
	Net.fireServer("DecisionChooseIntent", { choice = choice })
	task.spawn(function()
		for _ = 1, T.ackRetries do
			task.wait(T.ackTimeout)
			if sendToken ~= token or acked() or phase() ~= "Choose" then
				return
			end
			Net.fireServer("DecisionChooseIntent", { choice = choice })
		end
	end)
end

local function chooseOpen(): boolean
	return phase() == "Choose" and isFinalist() and reveal() == nil
end

local confirm, press, release, _stopConfirm = DecisionStudio.confirmer(send, chooseOpen)

local unmount: (() -> ())? = nil
local talkThread: thread? = nil

local function stopTalk()
	if talkThread ~= nil then
		task.cancel(talkThread)
		talkThread = nil
	end
	talk({})
end

local function startTalk()
	stopTalk()
	talkThread = task.spawn(function()
		while true do
			local nextTalk: { [number]: DecisionStudio.Talk } = {}
			local changed = false
			local current = talk()
			for _, id in ids do
				local value: DecisionStudio.Talk? = nil
				if StudioChatController.isPlayerSpeaking(id) then
					value = "speaking"
				elseif StudioChatController.isPlayerTyping(id) then
					value = "typing"
				end
				if value ~= nil then
					nextTalk[id] = value
				end
				if current[id] ~= value then
					changed = true
				end
			end
			if changed then
				talk(nextTalk)
			end
			task.wait(TALK_INTERVAL)
		end
	end)
end

local function resetStudio()
	sendToken += 1
	locked({})
	acked(false)
	reveal(nil)
	personal(nil)
	confirm(DecisionLogic.OPEN)
end

local function hide()
	if unmount ~= nil then
		(unmount :: () -> ())()
		unmount = nil
	end
	stopTalk()
end

local store: DecisionStudio.Store = {
	selfId = selfId,
	isFinalist = isFinalist,
	seats = seats,
	phase = phase,
	endsAt = endsAt,
	phaseSeconds = {
		Intro = GameConfig.studioTimers.introSeconds,
		Negotiate = GameConfig.studioTimers.negotiateSeconds,
		Choose = GameConfig.studioTimers.chooseSeconds,
	},
	locked = locked,
	talk = talk,
	confirm = confirm,
	acked = acked,
	reveal = reveal,
	personal = personal,
	chat = chat,
	press = press,
	release = release,
	dismiss = hide,
}

local function show()
	if unmount == nil then
		unmount = DecisionStudio.mount(UIScaleController, store)
		startTalk()
	end
end

-- Roblox's chat window, so the seats can sit below it. Read through the
-- documented ChatWindowConfiguration (see StudioChatController for why
-- the documented seam and not the default chat UI's hierarchy).
local function watchChat()
	local config = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
	if config == nil then
		return
	end
	local function read()
		if not config.Enabled then
			chat(nil)
			return
		end
		local p, s = config.AbsolutePosition, config.AbsoluteSize
		chat({ x = p.X, y = p.Y, width = s.X, height = s.Y })
	end
	config:GetPropertyChangedSignal("AbsolutePosition"):Connect(read)
	config:GetPropertyChangedSignal("AbsoluteSize"):Connect(read)
	config:GetPropertyChangedSignal("Enabled"):Connect(read)
	read()
end

local DecisionStudioController: Loader.Controller = {
	name = "DecisionStudioController",
	dependencies = { "UIScaleController", "StudioChatController", "NPCBubbleController" },

	isActive = function(): boolean
		return unmount ~= nil
	end,
}

function DecisionStudioController:init()
	Net.onClientEvent("RoundState", function(payload: any)
		if payload.state == "DecisionStudio" then
			show()
		elseif payload.state ~= "Results" then
			hide()
		end
	end)

	Net.onClientEvent("DecisionParticipants", function(payload: any)
		resetStudio()
		ids = {}
		leftIds = {}
		for _, raw in (payload.qualifierIds or {}) :: { any } do
			if type(raw) == "number" then
				table.insert(ids, raw)
			end
		end
		reputations = DecisionLogic.parseReputation(payload.reputation)
		rebuildSeats()
	end)

	Net.onClientEvent("DecisionRosterChange", function(payload: any)
		local id = payload.racerId
		local index = table.find(ids, id)
		if index == nil then
			return
		end
		if payload.reason == "Withdrawn" then
			if type(payload.replacedById) == "number" then
				ids[index] = payload.replacedById
			else
				table.remove(ids, index)
			end
		elseif payload.reason == "Forfeited" then
			leftIds[id] = true
		end
		rebuildSeats()
	end)

	Net.onClientEvent("DecisionPhaseChanged", function(payload: any)
		phase(payload.phase)
		endsAt(payload.endsAt)
	end)

	Net.onClientEvent("DecisionLockedIn", function(payload: any)
		local id = payload.playerId
		if type(id) ~= "number" then
			return
		end
		local nextLocked = table.clone(locked())
		nextLocked[id] = true
		locked(nextLocked)
		if id == selfId then
			acked(true)
		end
	end)

	Net.onClientEvent("DecisionReveal", function(payload: any)
		local parsed = DecisionLogic.parseReveal(payload)
		if parsed ~= nil then
			reveal(parsed)
		end
	end)

	Net.onClientEvent("DecisionPersonalResult", function(payload: any)
		personal(DecisionLogic.parsePersonal(payload))
	end)
end

function DecisionStudioController:start()
	task.spawn(watchChat)
end

return DecisionStudioController
