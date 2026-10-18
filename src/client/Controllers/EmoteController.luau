--!strict
-- Plays the local player's equipped Emote cosmetic: on demand, anywhere
-- (G, D-pad up, or a touch button beside jump), and once on the
-- Decision Studio podium when they win (2026-10-18, owner).
--
-- WHY THE CLIENT PLAYS IT, NOT THE SERVER: Roblox replicates any
-- animation a client plays on its own character's Animator to every
-- other client - that is how the default emotes work. So a server
-- round-trip couldn't stop a modified client from playing whatever it
-- likes on itself anyway, and would only add latency and make
-- "stop when you move" (a client-side input) awkward. Nothing here
-- touches a remote or anything another player owns; the only thing a
-- compromised client gains by skipping the ownership check is a look.
--
-- WHICH EMOTE: whatever is in the profile's "emote" slot, read from
-- StoreState (MenuController.storeState). The Locker is the selector -
-- one slot, one key. No emote equipped = no key action and no button.
--
-- STOPS when the player moves or jumps, so it can never pin anyone in
-- place mid-race.
--
-- THE PODIUM: when the outcome lands on screen (the last card's turn +
-- DecisionLogic.TIMING.outcomeAfter, the same instant on every screen),
-- a winning finalist's own client plays it - never before, or a flex
-- would leak the result. Their client playing it replicates it to
-- everyone else's view of the podium.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Clock = require(ReplicatedStorage.Shared.Clock)
local CosmeticLogic = require(ReplicatedStorage.Shared.CosmeticLogic)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local DecisionLogic = require(script.Parent.Parent.UI.DecisionLogic)

local effect = vide.effect

local player = Players.LocalPlayer

local ACTION = "DSBEmote"
local EMOTE_KEY = Enum.KeyCode.G
local EMOTE_PAD = Enum.KeyCode.DPadUp
local EMOTE_SLOT = CosmeticLogic.slotFor("Emote") :: string
-- A reveal packet that lands this late past the outcome still flexes.
local LATE_TOLERANCE = 0.25

type EmoteItem = { animationAssetId: number, iconAssetId: number?, displayName: string }

-- Emote id -> what to play. Enabled items only.
local emoteDefs: { [string]: EmoteItem } = {}
for _, entry in Cosmetics do
	local def = entry.def
	if def.category == "Emote" and def.enabled and def.animationAssetId ~= nil then
		local icon = def.previewIconAssetId
		emoteDefs[def.id] = {
			animationAssetId = def.animationAssetId :: number,
			iconAssetId = if icon ~= nil and icon > 0 then icon else nil,
			displayName = def.displayName,
		}
	end
end

local equippedId: string? = nil
local current: AnimationTrack? = nil
local stopConnections: { RBXScriptConnection } = {}

-- Bumped when the round leaves the Studio, so a podium flex still
-- scheduled from a reveal that's over never fires into the next round.
local roundToken = 0

local function stop()
	for _, c in stopConnections do
		c:Disconnect()
	end
	table.clear(stopConnections)
	if current ~= nil then
		current:Stop(0.2)
		current = nil
	end
end

local function play()
	local item = if equippedId ~= nil then emoteDefs[equippedId] else nil
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if item == nil or humanoid == nil or humanoid.Health <= 0 then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		return
	end

	stop()
	local animation = Instance.new("Animation")
	animation.AnimationId = string.format("rbxassetid://%d", item.animationAssetId)
	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	track:Play(0.2)
	current = track

	table.insert(
		stopConnections,
		humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
			if humanoid.MoveDirection.Magnitude > 0.1 then
				stop()
			end
		end)
	)
	table.insert(
		stopConnections,
		humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
			if humanoid.Jump then
				stop()
			end
		end)
	)
	table.insert(
		stopConnections,
		track.Stopped:Connect(function()
			if current == track then
				stop()
			end
		end)
	)
end

local function unbind()
	ContextActionService:UnbindAction(ACTION)
end

local function bind(item: EmoteItem)
	ContextActionService:BindAction(ACTION, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			play()
		end
		return Enum.ContextActionResult.Sink
	end, true, EMOTE_KEY, EMOTE_PAD)
	-- The touch button CAS makes for us sits in the arc beside jump: one
	-- thumb, and only on touch.
	if item.iconAssetId ~= nil then
		ContextActionService:SetImage(ACTION, string.format("rbxassetid://%d", item.iconAssetId :: number))
	else
		ContextActionService:SetTitle(ACTION, "Emote")
	end
	ContextActionService:SetDescription(ACTION, item.displayName)
end

local function setEquipped(id: string?)
	if id == equippedId then
		return
	end
	equippedId = id
	stop()
	local item = if id ~= nil then emoteDefs[id] else nil
	if item ~= nil then
		bind(item)
	else
		unbind()
	end
end

local function onReveal(payload: any)
	local reveal = DecisionLogic.parseReveal(payload)
	if reveal == nil or not table.find(reveal.winnerIds, player.UserId) then
		return
	end
	local seats = #((Loader.get("DecisionStudioController") :: any).getSeatIds() :: { number })
	local outcomeAt = DecisionLogic.cardTurnAt(math.max(1, seats), seats) + DecisionLogic.TIMING.outcomeAfter
	local delay = reveal.revealAt + outcomeAt - Clock.now()
	if delay < -LATE_TOLERANCE then
		return
	end
	local token = roundToken
	task.delay(math.max(0, delay), function()
		if token == roundToken then
			play()
		end
	end)
end

local EmoteController: Loader.Controller = {
	name = "EmoteController",
	dependencies = { "MenuController", "DecisionStudioController" },
}

function EmoteController:init()
	Net.onClientEvent("RoundState", function(payload: any)
		local state = if type(payload) == "table" then payload.state else nil
		if state == "Loading" or state == "Cleanup" or state == "WaitingForPlayers" then
			roundToken += 1
		end
	end)
	Net.onClientEvent("DecisionReveal", onReveal)
	player.CharacterAdded:Connect(function()
		stop()
	end)
end

function EmoteController:start()
	local MenuController = Loader.get("MenuController") :: any
	vide.root(function()
		effect(function()
			local state = MenuController.storeState()
			local id = if state ~= nil then state.equipped[EMOTE_SLOT] else nil
			setEquipped(id)
		end)
	end)
end

return EmoteController
