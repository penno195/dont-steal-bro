--!strict
-- Client half of P3-6's NPC negotiation chatter: renders the bubble the
-- server already decided on. Every decision - which bot speaks, when,
-- and what it says - is made server-side in NPCBrain.luau; this file
-- does nothing but display, so a compromised client can change what it
-- personally sees and nothing else.
--
-- WHY THE SERVER CAN'T JUST DO THIS ITSELF:
-- TextChatService:DisplayBubble(partOrCharacter, message) is a client
-- method - confirmed against the pinned Roblox type definitions this
-- repo checks against (globalTypes.d.luau, luau-lsp 1.69.0), where it's
-- declared as `DisplayBubble(self, partOrCharacter: Instance, message:
-- string): nil`. So the split is forced, and it happens to be the split
-- we'd want anyway (Ground Rule 1).
--
-- WHY IT RESOLVES THE RIG BY NAME: an NPC has no Player, so there's no
-- Players:GetPlayerByUserId route to its character. NPCService names
-- each rig with the bot's own displayName and parents it under
-- Workspace.NPCs, and the roster broadcast (NPCRoster) maps the
-- negative id to that name - so this controller keeps the roster and
-- looks the rig up in that folder. A bubble for a bot that has already
-- been despawned is dropped silently rather than warned about: the
-- race ending mid-flight is ordinary, not an error.

local TextChatService = game:GetService("TextChatService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

local npcNames: { [number]: string } = {}

local function findRig(npcId: number): Model?
	local name = npcNames[npcId]
	if name == nil then
		return nil
	end

	local folder = Workspace:FindFirstChild("NPCs")
	if folder == nil then
		return nil
	end

	local rig = folder:FindFirstChild(name)
	return if rig ~= nil and rig:IsA("Model") then rig else nil
end

local NPCBubbleController: Loader.Controller = {
	name = "NPCBubbleController",
	dependencies = {},

	-- Exposed for a future HUD (P6-3) that wants to label a negative id
	-- appearing in TaskProgress or the qualification result.
	getNPCName = function(npcId: number): string?
		return npcNames[npcId]
	end,
}

function NPCBubbleController:init()
	Net.onClientEvent("NPCRoster", function(payload: any)
		npcNames = {}
		for _, entry in payload.npcs do
			npcNames[entry.id] = entry.displayName
		end
	end)

	Net.onClientEvent("NPCChatBubble", function(payload: any)
		local rig = findRig(payload.npcId)
		if rig == nil then
			return
		end

		local head = rig:FindFirstChild("Head")
		local adornee: Instance = if head ~= nil then head else rig
		TextChatService:DisplayBubble(adornee, payload.message)
	end)
end

return NPCBubbleController
