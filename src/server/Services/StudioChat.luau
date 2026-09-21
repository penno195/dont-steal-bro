--!strict
-- Proximity communication for the Decision Studio's Negotiate phase
-- (P3-3): text and voice, both scoped to exactly the round's 3
-- qualifiers, open only while Negotiate is live.
--
-- ===== VERIFIED AGAINST CURRENT ROBLOX DOCS, NOT RECALLED FROM TRAINING =====
-- CLAUDE.md specifically flags TextChatService and the Audio API as
-- APIs to verify rather than assume - both are load-bearing in this
-- file, so here's what was actually confirmed (create.roblox.com, Sept
-- 2026) rather than guessed:
--
--   TEXT: a custom TextChannel is a real Instance you create and parent
--   under TextChatService; TextChannel:AddUserAsync(userId) adds a
--   member. There is NO documented per-user removal method - the
--   pattern for a temporary, round-scoped channel like this one is to
--   Destroy() the whole channel when it should close, not remove users
--   one at a time. ShouldDeliverCallback(message, textSource) is a
--   server-only callback fired once per POTENTIAL RECIPIENT TextSource,
--   returning whether that message should reach them - the confirmed,
--   documented use case for it is exactly this: "proximity-based chat
--   where users can only send messages to those close to them."
--   TextChatService filters chat automatically; nothing here calls
--   TextService:FilterStringAsync itself. Bubble chat is integrated
--   into TextChatService and shows messages from ANY channel (custom
--   ones included) once BubbleChatConfiguration.Enabled is true - no
--   per-channel bubble setup exists or is needed.
--
--   VOICE: AudioDeviceInput, AudioEmitter and AudioListener are NOT
--   manually constructed by this file. They're auto-provisioned by
--   Roblox itself - AudioDeviceInput under each voice-eligible Player,
--   AudioEmitter under their Character, AudioListener under Workspace.
--   CurrentCamera - the instant experience-level voice chat is enabled
--   (an "outside code" setting - see docs/studio-chat-notes.md) and
--   that specific player is voice-eligible (13+, ID/phone verified).
--   `player:FindFirstChild("AudioDeviceInput")` returning nil is the
--   real, confirmed signal for "this player has no voice access right
--   now," for any reason - too young, unverified, voice disabled
--   experience-wide, or simply declined the mic permission prompt. This
--   file's whole job for voice is restricting WHO can hear an existing
--   AudioDeviceInput, via AudioDeviceInput.AccessType +
--   :SetUserIdAccessList(userIds) - the exact mechanism Roblox's own
--   "team chat" tutorial example uses for scoping voice to a team,
--   applied here to "the other 2 qualifiers" instead. Distance falloff
--   for voice is a separate, already-functioning AudioEmitter curve
--   this file does not touch - P3-4's own podium spacing is what keeps
--   that comfortably inside range, the same way it does for text.

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local CHANNEL_NAME = "DecisionStudioNegotiate"

local activeChannel: TextChannel? = nil

local function characterPosition(player: Player): Vector3?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	return root.Position
end

-- "No client may learn another player's choice before the reveal"
-- (P3-2's own absolute requirement) has nothing to do with THIS file -
-- Negotiate happens entirely before anyone has chosen anything. This
-- callback's only job is proximity: can `recipientSource`'s player
-- actually hear `message`'s sender right now.
local function shouldDeliver(message: TextChatMessage, recipientSource: TextSource): boolean
	-- message.TextSource is declared non-optional (TextChatMessage always
	-- has a sender) - no nil check needed or, per luau-lsp, even legal
	-- (comparing it to nil hits the same Instance/nil metatable gap
	-- PowerUpService.luau's own header comment documents for
	-- Players:GetPlayerFromCharacter).
	local sender = Players:GetPlayerByUserId(message.TextSource.UserId)
	local recipient = Players:GetPlayerByUserId(recipientSource.UserId)
	if sender == nil or recipient == nil then
		return false
	end
	if sender == recipient then
		return true -- always see your own message echoed back
	end

	local senderPosition = characterPosition(sender)
	local recipientPosition = characterPosition(recipient)
	if senderPosition == nil or recipientPosition == nil then
		return false
	end

	return (senderPosition - recipientPosition).Magnitude <= GameConfig.decisionStudioChatRangeStuds
end

local function closeTextChannel()
	if activeChannel ~= nil then
		activeChannel:Destroy()
		activeChannel = nil
	end
end

local function openTextChannel(qualifierIds: { number })
	closeTextChannel() -- idempotent guard - see other Studio-debug-replay comments in this codebase for why

	local channel = Instance.new("TextChannel")
	channel.Name = CHANNEL_NAME
	channel.ShouldDeliverCallback = shouldDeliver
	channel.Parent = TextChatService

	for _, id in qualifierIds do
		local player = Players:GetPlayerByUserId(id)
		if player ~= nil then
			channel:AddUserAsync(player.UserId)
		end
	end

	activeChannel = channel
end

local function audioDeviceFor(player: Player): AudioDeviceInput?
	local device = player:FindFirstChild("AudioDeviceInput")
	if device ~= nil and device:IsA("AudioDeviceInput") then
		return device
	end
	return nil -- no voice access for this player - text-only, fully supported
end

local function openVoiceAccess(qualifierIds: { number })
	for _, id in qualifierIds do
		local player = Players:GetPlayerByUserId(id)
		if player == nil then
			continue
		end
		local device = audioDeviceFor(player)
		if device == nil then
			continue
		end

		local others: { number } = {}
		for _, otherId in qualifierIds do
			if otherId ~= id then
				table.insert(others, otherId)
			end
		end

		device.AccessType = Enum.AccessModifierType.Allow
		device:SetUserIdAccessList(others)
	end
end

-- "Channels open exactly with the Negotiate phase and close when Choose
-- begins. After that, no communication at all" (the task's own
-- requirement, verbatim) - an empty allow-list under AccessType.Allow
-- means nobody at all can hear this device, the same mechanism used to
-- open it, just pointed at nothing.
local function closeVoiceAccess(qualifierIds: { number })
	for _, id in qualifierIds do
		local player = Players:GetPlayerByUserId(id)
		if player == nil then
			continue
		end
		local device = audioDeviceFor(player)
		if device == nil then
			continue
		end
		device:SetUserIdAccessList({})
	end
end

-- ===== typing status =========================================================

local function handleTypingIntent(player: Player)
	local DecisionService = Loader.get("DecisionService") :: any
	if DecisionService.getPhase() ~= "Negotiate" then
		return
	end

	local qualifierIds = DecisionService.getQualifierIds()
	if table.find(qualifierIds, player.UserId) == nil then
		return
	end

	for _, id in qualifierIds do
		if id == player.UserId then
			continue
		end
		local recipient = Players:GetPlayerByUserId(id)
		if recipient ~= nil then
			Net.fireClient("StudioChatTypingStatus", recipient, { playerId = player.UserId })
		end
	end
end

-- ===== service =============================================================

local StudioChat: Loader.Service = {
	name = "StudioChat",
	dependencies = { "NetGuard", "ConfigValidator", "DecisionService" },
}

function StudioChat:init()
	local NetGuard = Loader.get("NetGuard") :: any
	local DecisionService = Loader.get("DecisionService") :: any

	DecisionService.onPhaseEnter("Negotiate", function()
		local qualifierIds = DecisionService.getQualifierIds()
		openTextChannel(qualifierIds)
		openVoiceAccess(qualifierIds)
	end)

	DecisionService.onPhaseExit("Negotiate", function()
		closeTextChannel()
		closeVoiceAccess(DecisionService.getQualifierIds())
	end)

	NetGuard.on("StudioChatTypingIntent", function(player: Player, _payload: any)
		handleTypingIntent(player)
	end)
end

return StudioChat
