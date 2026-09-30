--!strict
-- The win-streak counter over each player's head in the Hub, dressed by
-- their StreakFlair cosmetic if they wear one. Draws exactly what
-- StreakTagState says - and the server only sends that on the Hub, so
-- on a match server this controller never has anything to draw (see
-- StreakTagService / design-decisions.md Q7 condition 1).
--
-- Built the NametagController way (see its performance header):
-- AlwaysOnTop off, LightInfluence 0, MaxDistance, no per-frame work.
-- It sits just above the title nametag: SizeOffset lifts it by its own
-- height in SCREEN space, so the two never overlap at any distance.
--
-- The number is always the real streak. Flair changes the text colour
-- and puts its texture behind the number - nothing else.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

local LocalPlayer = Players.LocalPlayer

local TAG_NAME = "DSBStreakTag"
local MAX_DISTANCE_STUDS = 60
local OFFSET_STUDS = 2.4 -- the nametag's own anchor
local TAG_PIXELS = Vector2.new(160, 24)
-- Half the 32px nametag, half this tag, and a small gap - in units of
-- this tag's height, which is what SizeOffset measures in.
local LIFT = (16 + 12 + 2) / 24
-- Matches NametagController's first-person threshold.
local FIRST_PERSON_DISTANCE_STUDS = 1

type Flair = { textureAssetId: number, colorHex: string }
type Tag = { streak: number, flair: Flair? }

-- Flair id -> how to draw it. Enabled items only, so a disabled or
-- unknown id draws the plain counter.
local flairDefs: { [string]: Flair } = {}
for _, entry in Cosmetics do
	local def = entry.def
	if def.category == "StreakFlair" and def.enabled then
		flairDefs[def.id] = {
			textureAssetId = def.flairTextureAssetId :: number,
			colorHex = def.flairColorHex :: string,
		}
	end
end

local tagsByUserId: { [number]: Tag } = {}

local function colorFromHex(hex: string): Color3
	local ok, color = pcall(function()
		return Color3.fromHex(hex)
	end)
	return if ok then color else Color3.fromRGB(255, 255, 255)
end

local function removeTag(character: Model)
	local head = character:FindFirstChild("Head")
	local existing = if head ~= nil then head:FindFirstChild(TAG_NAME) else nil
	if existing ~= nil then
		existing:Destroy()
	end
end

local function buildTag(character: Model, tag: Tag)
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return
	end
	removeTag(character)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = TAG_NAME
	billboard.Size = UDim2.fromOffset(TAG_PIXELS.X, TAG_PIXELS.Y)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, OFFSET_STUDS, 0)
	billboard.SizeOffset = Vector2.new(0, LIFT)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = MAX_DISTANCE_STUDS
	billboard.LightInfluence = 0
	billboard.ResetOnSpawn = false
	billboard.Adornee = head
	billboard.Parent = head

	local flair = tag.flair
	if flair ~= nil then
		local texture = Instance.new("ImageLabel")
		texture.Name = "Flair"
		texture.Size = UDim2.fromScale(1, 1)
		texture.BackgroundTransparency = 1
		texture.Image = string.format("rbxassetid://%d", flair.textureAssetId)
		texture.ZIndex = 1
		texture.Parent = billboard
	end

	local label = Instance.new("TextLabel")
	label.Name = "Streak"
	label.Size = UDim2.fromScale(1, 1)
	label.ZIndex = 2
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = string.format("%d WIN STREAK", tag.streak)
	label.TextColor3 = if flair ~= nil then colorFromHex(flair.colorHex) else Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Parent = billboard
end

local function refreshAll()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character ~= nil then
			local tag = tagsByUserId[player.UserId]
			if tag ~= nil then
				buildTag(character, tag)
			else
				removeTag(character)
			end
		end
	end
end

-- Own tag hidden in first person, as the nametag is: from inside the
-- head it's a bar across the screen. Polled at 5 Hz, not per frame.
local function updateFirstPersonVisibility()
	local character = LocalPlayer.Character
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	local billboard = if head ~= nil then head:FindFirstChild(TAG_NAME) else nil
	local camera = workspace.CurrentCamera
	if head == nil or not head:IsA("BasePart") or billboard == nil or not billboard:IsA("BillboardGui") then
		return
	end
	if camera ~= nil then
		billboard.Enabled = (camera.CFrame.Position - head.Position).Magnitude > FIRST_PERSON_DISTANCE_STUDS
	end
end

local StreakTagController: Loader.Controller = {
	name = "StreakTagController",
	dependencies = {},
}

function StreakTagController:init()
	Net.onClientEvent("StreakTagState", function(payload: any)
		tagsByUserId = {}
		local tags = if type(payload) == "table" and type(payload.tags) == "table" then payload.tags else {}
		for _, entry in tags :: { any } do
			if type(entry) == "table" and type(entry.racerId) == "number" and type(entry.streak) == "number" then
				local flair = if type(entry.flairId) == "string" then flairDefs[entry.flairId] else nil
				tagsByUserId[entry.racerId] = { streak = entry.streak, flair = flair }
			end
		end
		refreshAll()
	end)

	-- A fresh character has no tag (it hung off the old head).
	local function watch(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(refreshAll)
		end)
	end
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)

	task.spawn(function()
		while true do
			task.wait(0.2)
			updateFirstPersonVisibility()
		end
	end)
end

return StreakTagController
