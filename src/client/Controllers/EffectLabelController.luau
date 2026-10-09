--!strict
-- A word over the head of anyone a debuff is on ("STUNNED", "SLOWED"),
-- from the StatusEffectsVisual broadcast. Without it a Blind or a Slow
-- on a rival - or on a hub training dummy - is invisible, and a spent
-- power-up reads as one that did nothing. Your own effects already show
-- on your HUD, so you get no label.
--
-- A debuff with a victim look (PowerUpDef.victimLook) gets that instead
-- of a word - VictimLookController.
--
-- One label, the strongest effect only: a stack of words over a head is
-- unreadable at race distance on a phone.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Base = require(script.Parent.Parent.UI.Components.Base)
local Theme = require(script.Parent.Parent.UI.Theme)

local LABEL_NAME = "EffectLabel"
local MAX_DISTANCE = 90

type Label = { text: string, color: Color3 }

-- Strongest first. Buffs other than Ward get no word: a sprinting
-- rival is already visibly fast.
local function labelFor(categories: { string }, slowed: boolean): Label?
	local has: { [string]: boolean } = {}
	for _, category in categories do
		has[category] = true
	end
	if has.HardControl then
		return { text = "STUNNED", color = Theme.color.danger }
	elseif has.Vision then
		return { text = "BLINDED", color = Theme.color.danger }
	elseif slowed then
		return { text = "SLOWED", color = Theme.color.warning }
	elseif has.Ward then
		return { text = "SHIELDED", color = Theme.color.brand }
	end
	return nil
end

local function characterFor(id: number): Model?
	if id > 0 then
		local player = Players:GetPlayerByUserId(id)
		return if player ~= nil then player.Character else nil
	end
	for _, instance in CollectionService:GetTagged("PracticeDummy") do
		if instance:IsA("Model") and instance:GetAttribute("ParticipantId") == id then
			return instance
		end
	end
	local name = (Loader.get("NPCBubbleController") :: any).getNPCName(id) :: string?
	local folder = Workspace:FindFirstChild("NPCs")
	local rig = if folder ~= nil and name ~= nil then folder:FindFirstChild(name) else nil
	return if rig ~= nil and rig:IsA("Model") then rig else nil
end

local function show(character: Model, label: Label?)
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return
	end
	local existing = head:FindFirstChild(LABEL_NAME)
	if label == nil then
		if existing ~= nil then
			existing:Destroy()
		end
		return
	end

	local gui: BillboardGui
	if existing ~= nil and existing:IsA("BillboardGui") then
		gui = existing
	else
		gui = Instance.new("BillboardGui")
		gui.Name = LABEL_NAME
		gui.Size = UDim2.fromOffset(120, 28)
		gui.StudsOffset = Vector3.new(0, 2.5, 0)
		gui.MaxDistance = MAX_DISTANCE
		gui.LightInfluence = 0
		local text = Base.text("body", {
			Name = "Text",
			Size = UDim2.fromScale(1, 1),
			TextStrokeTransparency = 0.3,
		})
		text.Parent = gui
		gui.Adornee = head
		gui.Parent = head
	end
	local text = gui:FindFirstChild("Text") :: TextLabel
	text.Text = label.text
	text.TextColor3 = label.color
end

local EffectLabelController: Loader.Controller = {
	name = "EffectLabelController",
	dependencies = { "NPCBubbleController" },
	-- Participant id (player, NPC or practice dummy) -> its rig. ThrowController reuses it.
	characterFor = characterFor,
}

function EffectLabelController:init()
	Net.onClientEvent("StatusEffectsVisual", function(payload: any)
		if type(payload.playerId) ~= "number" or payload.playerId == Players.LocalPlayer.UserId then
			return
		end
		local character = characterFor(payload.playerId)
		if character == nil then
			return
		end
		-- A racer with a victim look (iced, ragdolled, inked) needs no
		-- word: VictimLookController draws them instead.
		if type(payload.look) == "string" then
			show(character, nil)
			return
		end
		local categories = if type(payload.categories) == "table" then payload.categories else {}
		show(character, labelFor(categories, payload.slowed == true))
	end)
end

return EffectLabelController
