--!strict
-- The client half of P4-2's title display: a BillboardGui nametag above
-- each character, and the chat prefix. Both render whatever the server
-- said in TitleState and nothing else - which is also what enforces
-- design-decisions.md Q7 condition 1, because mid-round the server
-- simply doesn't send other players' titles, so there is nothing here
-- to un-hide (see TitleService's own header).
--
-- ===== NAMETAG PERFORMANCE: SIX OF THESE, ON A PHONE ====================
--
-- P4-2 asks for this note specifically, and perf-budget.md's device
-- matrix is a cheap Android phone. Six nametags is six more things the
-- renderer has to composite every frame, above six already-animating
-- characters. What matters, in the order it matters:
--
-- 1. AlwaysOnTop = false, and that IS the performance decision, not a
--    visual one. A BillboardGui drawn on top of everything forces the
--    renderer to break batching to composite it last. Titles are
--    flavour, not gameplay-critical information - nobody needs to read
--    one through a wall.
--
-- 2. ONE TextLabel per tag, not a frame with a stroke child and a
--    shadow child. A UIStroke on the label costs nothing extra to
--    batch; three stacked transparent frames cost three draws each.
--    Readability at distance comes from the stroke, not from layering.
--
-- 3. MaxDistance, set here to 60 studs. This is the single biggest
--    win available: beyond it Roblox culls the gui entirely rather
--    than drawing text too small to read. On a 6-player map most
--    nametags are out of range most of the time.
--
-- 4. LightInfluence = 0. A billboard that responds to lighting is
--    re-shaded as the character moves through the map's lights; a flat
--    one is not, and title text is meant to be legible anyway.
--
-- 5. Never a per-frame size update. `Size` is in scale-with-distance
--    offset units, so Roblox handles the distance scaling itself -
--    a RunService.Heartbeat connection that recomputes six nametag
--    sizes every frame is the classic version of this feature and it
--    is exactly what to avoid on a phone.
--
-- 6. The Rainbow effect is ONE TweenService tween per tag, not a
--    Heartbeat loop, and only the top rung has it - so at most a
--    handful ever run, and the engine steps them off the main script
--    thread.
--
-- WHAT TO CUT FIRST if a device is still struggling: MaxDistance to 40,
-- then drop the effect tweens entirely (they're the only moving part),
-- then hide nametags for everyone but the local player.

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

local LocalPlayer = Players.LocalPlayer

local NAMETAG_NAME = "DSBTitleNametag"
local MAX_DISTANCE_STUDS = 60
-- First-person hiding threshold. Roblox's own default character scripts
-- treat anything under 1 stud of camera-to-head distance as first
-- person; matching that number rather than inventing one keeps the
-- nametag's behaviour consistent with the rest of the character UI.
local FIRST_PERSON_DISTANCE_STUDS = 1

type TitleInfo = {
	id: string,
	displayName: string,
	colorHex: string,
	effect: string?,
}

local titlesByRacerId: { [number]: TitleInfo } = {}
local activeTweens: { [Instance]: Tween } = {}

local function colorFromHex(hex: string): Color3
	-- Config stores "#rrggbb" as a plain string so Validate.luau stays
	-- Lune-pure (no Color3 datatype); this is the one place it becomes
	-- a real colour.
	local ok, color = pcall(function()
		return Color3.fromHex(hex)
	end)
	return if ok then color else Color3.fromRGB(255, 255, 255)
end

local function clearTween(instance: Instance)
	-- Cast to the honest optional type: a map access is declared as
	-- returning the value type, not `T?`, so comparing it to nil trips
	-- the same Instance/nil metatable gap StudioChatController.luau
	-- documents.
	local tween = activeTweens[instance] :: Tween?
	if tween ~= nil then
		tween:Cancel()
		activeTweens[instance] = nil
	end
end

local function applyEffect(label: TextLabel, effect: string?)
	clearTween(label)
	if effect == nil then
		return
	end

	if effect == "Glow" then
		-- Static, no tween at all: a brighter stroke reads as a glow at
		-- nametag size and costs nothing to animate, because it doesn't.
		label.TextStrokeTransparency = 0.2
	elseif effect == "Pulse" then
		local tween = TweenService:Create(
			label,
			TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ TextTransparency = 0.35 }
		)
		tween:Play()
		activeTweens[label] = tween
	elseif effect == "Rainbow" then
		-- One tween that walks the hue via the label's own colour. Top
		-- rung only, so at most a couple exist in a whole server.
		local tween = TweenService:Create(
			label,
			TweenInfo.new(3, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, true),
			{ TextColor3 = Color3.fromHSV(0.85, 0.8, 1) }
		)
		tween:Play()
		activeTweens[label] = tween
	end
end

local function removeNametag(character: Model)
	local head = character:FindFirstChild("Head")
	local existing = if head ~= nil then head:FindFirstChild(NAMETAG_NAME) else nil
	if existing ~= nil then
		local label = existing:FindFirstChildOfClass("TextLabel")
		if label ~= nil then
			clearTween(label)
		end
		existing:Destroy()
	end
end

local function buildNametag(character: Model, info: TitleInfo)
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return
	end

	removeNametag(character)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = NAMETAG_NAME
	billboard.Size = UDim2.fromOffset(200, 32)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0)
	-- See this file's header, point 1: drawing on top breaks batching,
	-- and a title is flavour rather than something worth reading
	-- through geometry.
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = MAX_DISTANCE_STUDS
	billboard.LightInfluence = 0
	billboard.ResetOnSpawn = false
	billboard.Adornee = head
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Name = "TitleLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = info.displayName
	label.TextColor3 = colorFromHex(info.colorHex)
	-- Readability at distance comes from the stroke, not from stacked
	-- frames - one label, one stroke, one draw.
	label.TextStrokeTransparency = 0.4
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Parent = billboard

	applyEffect(label, info.effect)
end

local function characterFor(racerId: number): Model?
	if racerId < 0 then
		-- An NPC: no Player to ask, so the rig is found by the name
		-- NPCService gave it, under Workspace.NPCs - the same route
		-- NPCBubbleController takes.
		local folder = workspace:FindFirstChild("NPCs")
		if folder == nil then
			return nil
		end
		local controller = Loader.get("NPCBubbleController") :: any
		local name = controller.getNPCName(racerId) :: string?
		if name == nil then
			return nil
		end
		local rig = folder:FindFirstChild(name)
		return if rig ~= nil and rig:IsA("Model") then rig else nil
	end

	local player = Players:GetPlayerByUserId(racerId)
	return if player ~= nil then player.Character else nil
end

local function refreshAllNametags()
	-- Clear every existing tag first, so a title that disappeared from
	-- the payload (a round going live, someone unequipping) actually
	-- comes off rather than lingering.
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character ~= nil then
			removeNametag(character)
		end
	end
	local npcFolder = workspace:FindFirstChild("NPCs")
	if npcFolder ~= nil then
		for _, rig in npcFolder:GetChildren() do
			if rig:IsA("Model") then
				removeNametag(rig)
			end
		end
	end

	for racerId, info in titlesByRacerId do
		local character = characterFor(racerId)
		if character ~= nil then
			buildNametag(character, info)
		end
	end
end

-- ===== first person =========================================================

-- Hidden in first person (P4-2's own requirement): at that camera
-- distance the local player's own nametag is a rectangle across the
-- middle of the screen. Checked against the head's real distance from
-- the camera rather than against a CameraMode enum, because a player
-- can zoom into first person without the game ever setting that mode.
local function updateFirstPersonVisibility()
	local character = LocalPlayer.Character
	if character == nil then
		return
	end
	local head = character:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return
	end
	local billboard = head:FindFirstChild(NAMETAG_NAME)
	if billboard == nil or not billboard:IsA("BillboardGui") then
		return
	end

	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end

	billboard.Enabled = (camera.CFrame.Position - head.Position).Magnitude > FIRST_PERSON_DISTANCE_STUDS
end

-- ===== chat prefix ==========================================================

-- TextChatService.OnIncomingMessage runs on the RECEIVING client and
-- decorates a message before it's displayed, which is why the prefix
-- lives here rather than on the server. It reads the same
-- `titlesByRacerId` the nametags do, so mid-round - when the server
-- sent no titles - there is simply nothing to prefix with, and Q7's
-- suppression covers both surfaces from one decision.
local function installChatPrefix()
	TextChatService.OnIncomingMessage = function(message: TextChatMessage)
		local properties = Instance.new("TextChatMessageProperties")

		-- Declared non-optional in Roblox's own defs, but genuinely nil
		-- for a system message - the same gap StudioChatController.luau
		-- notes for ChatInputBarConfiguration.TargetTextChannel.
		local source = message.TextSource :: TextSource?
		if source == nil then
			return properties
		end

		local info = titlesByRacerId[source.UserId]
		if info == nil then
			return properties
		end

		properties.PrefixText =
			string.format('<font color="%s">[%s]</font> %s', info.colorHex, info.displayName, message.PrefixText)
		return properties
	end
end

local NametagController: Loader.Controller = {
	name = "NametagController",
	dependencies = {},

	getTitleFor = function(racerId: number): TitleInfo?
		return titlesByRacerId[racerId]
	end,
}

function NametagController:init()
	installChatPrefix()

	Net.onClientEvent("TitleState", function(payload: any)
		titlesByRacerId = {}
		for _, entry in payload.titles do
			titlesByRacerId[entry.racerId] = entry.title
		end
		refreshAllNametags()
	end)

	Net.onClientEvent("TitleUnlocked", function(payload: any)
		-- No UI yet (P6-6 owns the notification toast); printing keeps
		-- the unlock moment observable in Studio until there is one,
		-- rather than the event silently going nowhere.
		print(string.format("Title unlocked: %s (streak %d)", payload.title.displayName, payload.minStreak))
	end)

	-- Re-applied on respawn: a fresh character has no nametag, and
	-- ResetOnSpawn doesn't help because the gui is parented to the head
	-- that just got replaced.
	LocalPlayer.CharacterAdded:Connect(function()
		task.defer(refreshAllNametags)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(refreshAllNametags)
		end)
	end)

	-- Polled at 5 Hz rather than on Heartbeat: this only has to notice a
	-- camera zoom, which is a human-speed action, and per-frame work in
	-- a nametag controller is exactly what this file's header warns
	-- against.
	task.spawn(function()
		while true do
			task.wait(0.2)
			updateFirstPersonVisibility()
		end
	end)
end

return NametagController
