--!strict
-- Client half of P3-3's Decision Studio proximity chat: sends a
-- throttled typing-intent while the local player is composing a message
-- INTO the Negotiate channel specifically, and exposes both typing and
-- speaking status for a future HUD to read - "a per-player indicator of
-- who is speaking or typing, for the UI to consume" (the task's own
-- requirement). No UI is built here; StudioChat.luau's own header
-- comment on scope applies the same way here - a HUD consuming these two
-- getters is future work, not built yet anywhere in this repo.
--
-- WHY ChatInputBarConfiguration.TextBox, NOT A GUESS AT THE DEFAULT CHAT
-- UI'S INTERNAL HIERARCHY: confirmed against current Roblox docs (Sept
-- 2026) that there is no dedicated "started typing" event anywhere on
-- TextChatService - it was on Roblox's own public wishlist, not a
-- shipped API. `TextChatService.ChatInputBarConfiguration` IS a real,
-- documented instance with its own `TextBox` and `TargetTextChannel`
-- properties, though - reading the live input box through THAT
-- documented seam, rather than reaching into the default chat UI's
-- undocumented internal structure, is what keeps this file from being a
-- guess dressed up as an integration.
--
-- WHY SPEAKING NEEDS NO REMOTE AT ALL: AudioDeviceInput.Active is a
-- normal replicated property (not documented as "Not Replicated" the
-- way the client-only IsReady is) - a client can read another player's
-- Active directly the same way it reads any other Instance property.
-- This is the one claim in this file not independently confirmed beyond
-- the reference doc's own property table (no explicit "replicates to
-- other clients" statement was found) - worth a quick Studio check with
-- two clients before trusting it blindly.

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

local CHANNEL_NAME = "DecisionStudioNegotiate"
local TYPING_SEND_THROTTLE_SECONDS = 1.5
local TYPING_DISPLAY_SECONDS = 3 -- how long a received "is typing" stays true before this client assumes it's stale

local LocalPlayer = Players.LocalPlayer

local lastTypingSentAt = 0
local typingUntil: { [number]: number } = {}

local function isPlayerTyping(userId: number): boolean
	local until_ = typingUntil[userId]
	return until_ ~= nil and os.clock() < until_
end

local function isPlayerSpeaking(userId: number): boolean
	local player = Players:GetPlayerByUserId(userId)
	if player == nil then
		return false
	end
	local device = player:FindFirstChild("AudioDeviceInput")
	if device == nil or not device:IsA("AudioDeviceInput") then
		return false
	end
	return device.Active
end

local function onTextBoxChanged(inputBar: ChatInputBarConfiguration, textBox: TextBox)
	if textBox.Text == "" then
		return
	end

	-- Declared non-optional in Roblox's own type defs even though it can
	-- genuinely be unset at runtime (no channel targeted yet) - cast to
	-- the honest optional type rather than comparing the declared type
	-- directly to nil (the same Instance/nil metatable gap noted
	-- elsewhere in this codebase, e.g. StudioChat.luau, PowerUpService.
	-- luau).
	local targetChannel = inputBar.TargetTextChannel :: TextChannel?
	if targetChannel == nil or targetChannel.Name ~= CHANNEL_NAME then
		return
	end

	local nowClock = os.clock()
	if nowClock - lastTypingSentAt < TYPING_SEND_THROTTLE_SECONDS then
		return
	end
	lastTypingSentAt = nowClock

	Net.fireServer("StudioChatTypingIntent", {})
end

local StudioChatController: Loader.Controller = {
	name = "StudioChatController",
	dependencies = {},

	isPlayerTyping = isPlayerTyping,
	isPlayerSpeaking = isPlayerSpeaking,
}

function StudioChatController:init()
	-- ChatInputBarConfiguration is a real child Instance of TextChatService
	-- (WaitForChild applies); its own `TextBox` is a PROPERTY, not a
	-- child, so it's read directly, not waited for the same way -
	-- confirmed present as soon as the config instance itself is.
	local inputBar = TextChatService:WaitForChild("ChatInputBarConfiguration") :: ChatInputBarConfiguration
	local textBox = inputBar.TextBox

	textBox:GetPropertyChangedSignal("Text"):Connect(function()
		onTextBoxChanged(inputBar, textBox)
	end)

	Net.onClientEvent("StudioChatTypingStatus", function(payload: any)
		if payload.playerId == LocalPlayer.UserId then
			return
		end
		typingUntil[payload.playerId] = os.clock() + TYPING_DISPLAY_SECONDS
	end)
end

return StudioChatController
