--!strict
-- Each finalist's steal/share record, over their head in the world:
-- "Steal 60%  40% Share", Steal in red and Share in green (2026-09-26,
-- moved off the Decision Studio's seat cards to free the screen). The
-- words carry the meaning too, so the red/green pair never has to.
--
-- Same data, same scope as before: design-decisions.md Q5's lifetime
-- counts, from DecisionParticipants only, so it exists for the Studio
-- and nowhere else. Never a streak (Q7). A first-timer's 0/0 reads "No
-- history yet"; an NPC sends a small rolled history like a light player's.
--
-- Built the NametagController way (see its performance header): one
-- TextLabel per tag, AlwaysOnTop off, LightInfluence 0, no per-frame
-- work. There are at most three. A 1 Hz check re-attaches a tag to a
-- rig that streamed in late or respawned.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local DecisionLogic = require(script.Parent.Parent.UI.DecisionLogic)
local Theme = require(script.Parent.Parent.UI.Theme)

local TAG_NAME = "DSBFinalistRecord"
-- Just over the head, where Roblox draws a name. Sized in studs, so it
-- shrinks with distance like the rig it labels instead of staying a
-- fixed slab of screen.
local OFFSET_STUDS = 2.1
local TAG_STUDS = Vector2.new(5, 0.75)
-- Chat bubbles start just over the head too, where they sat on top of
-- the tag (2026-09-26 playtest). While the tags are up, bubbles are
-- lifted clear of them, and put back after.
local BUBBLE_LIFT_STUDS = 1.2
-- Spectators watch from lookouts behind the fence, well back from the
-- podiums, so further than a nametag's 60.
local MAX_DISTANCE_STUDS = 150
local CHECK_INTERVAL = 1

local STEAL_HEX = "#" .. Theme.color.danger:ToHex()
local SHARE_HEX = "#" .. Theme.color.success:ToHex()

local records: { [number]: string } = {} -- racer id -> rich text; empty = no tags
local checkThread: thread? = nil
local bubbleOffsetBefore: number? = nil -- set while bubbles are lifted

local function liftBubbles(lift: boolean)
	local config = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
	if config == nil then
		return
	end
	if lift and bubbleOffsetBefore == nil then
		bubbleOffsetBefore = config.VerticalStudsOffset
		config.VerticalStudsOffset += BUBBLE_LIFT_STUDS
	elseif not lift and bubbleOffsetBefore ~= nil then
		config.VerticalStudsOffset = bubbleOffsetBefore :: number
		bubbleOffsetBefore = nil
	end
end

local function textFor(rep: DecisionLogic.Reputation?): string
	local split = DecisionLogic.reputationSplit(rep)
	if split == nil then
		return DecisionLogic.NO_HISTORY
	end
	return string.format(
		'<font color="%s">Steal %d%%</font>   <font color="%s">%d%% Share</font>',
		STEAL_HEX,
		split.steal,
		SHARE_HEX,
		split.share
	)
end

local function tagOn(character: Model): BillboardGui?
	local head = character:FindFirstChild("Head")
	local existing = if head ~= nil then head:FindFirstChild(TAG_NAME) else nil
	return if existing ~= nil and existing:IsA("BillboardGui") then existing else nil
end

local function attach(character: Model, text: string)
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return
	end
	local billboard = tagOn(character)
	if billboard == nil then
		local created = Instance.new("BillboardGui")
		created.Name = TAG_NAME
		created.Size = UDim2.fromScale(TAG_STUDS.X, TAG_STUDS.Y)
		created.StudsOffsetWorldSpace = Vector3.new(0, OFFSET_STUDS, 0)
		created.AlwaysOnTop = false
		created.MaxDistance = MAX_DISTANCE_STUDS
		created.LightInfluence = 0
		created.ResetOnSpawn = false
		created.Adornee = head

		local label = Instance.new("TextLabel")
		label.Name = "Record"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.RichText = true
		label.TextColor3 = Theme.color.inkMuted -- the "No history yet" colour; the split colours itself
		label.TextStrokeTransparency = 0.4
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.Parent = created

		created.Parent = head
		billboard = created
	end
	local label = (billboard :: BillboardGui):FindFirstChild("Record")
	if label ~= nil and label:IsA("TextLabel") and label.Text ~= text then
		label.Text = text
	end
end

local function ensureAll()
	local nametags = Loader.get("NametagController") :: any
	for id, text in records do
		local character = nametags.characterFor(id) :: Model?
		if character ~= nil then
			attach(character, text)
		end
	end
end

local function clearAll()
	if checkThread ~= nil then
		task.cancel(checkThread)
		checkThread = nil
	end
	local nametags = Loader.get("NametagController") :: any
	for id in records do
		local character = nametags.characterFor(id) :: Model?
		local tag = if character ~= nil then tagOn(character) else nil
		if tag ~= nil then
			tag:Destroy()
		end
	end
	records = {}
	liftBubbles(false)
end

local FinalistTagController: Loader.Controller = {
	name = "FinalistTagController",
	dependencies = { "NametagController" },
}

function FinalistTagController:init()
	Net.onClientEvent("DecisionParticipants", function(payload: any)
		clearAll()
		local reps = DecisionLogic.parseReputation(payload.reputation)
		for _, raw in (payload.qualifierIds or {}) :: { any } do
			if type(raw) == "number" then
				records[raw] = textFor(reps[raw])
			end
		end
		liftBubbles(true)
		ensureAll()
		checkThread = task.spawn(function()
			while true do
				task.wait(CHECK_INTERVAL)
				ensureAll()
			end
		end)
	end)

	-- Up through the reveal and Results, gone once the round moves on.
	Net.onClientEvent("RoundState", function(payload: any)
		if payload.state ~= "DecisionStudio" and payload.state ~= "Results" then
			clearAll()
		end
	end)

	-- A player who leaves takes their rig; drop their entry too.
	Players.PlayerRemoving:Connect(function(player: Player)
		records[player.UserId] = nil
	end)
end

return FinalistTagController
