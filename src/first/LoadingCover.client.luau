--!strict
-- The loading cover. Runs from ReplicatedFirst, so it is on screen from
-- the first frame and replaces Roblox's default loading screen.
--
-- WHY. A player reaches the Match place before the round's map exists:
-- they stand on Workspace.ArrivalPad (scripts/assemble-match-place.luau)
-- while the round waits for everyone, and only at Loading does the
-- server clone the map in and move each player onto its SpawnPoints.
-- None of that should be seen. The cover stays up until the round
-- reaches Intro, by which point everyone is standing on the map.
--
-- In the Hub there is no round, so it is just a "Loading lobby" screen:
-- it lifts once the game has loaded and the character exists. The Hub
-- is recognised before game.Loaded (GameConfig replicates ahead of the
-- Workspace), so a Hub player never sees the match's round texts.
--
-- It never traps anyone. If the round hasn't reached Intro within
-- FALLBACK_SECONDS of the game loading (studioTest disabled, a stalled
-- server), it lifts anyway.
--
-- The round state comes from Workspace's "RoundState" attribute
-- (RoundService.broadcastState), not the RoundState remote: this script
-- starts before every controller, and listening on the remote would
-- take the queued first event from whichever controller connects next.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local FALLBACK_SECONDS = 30
local FADE_SECONDS = 0.4
-- States in which every player has already been placed on the map.
local ON_MAP: { [string]: boolean } = {
	Intro = true,
	Race = true,
	Qualified = true,
	DecisionStudio = true,
	Results = true,
}
local STATUS: { [string]: string } = {
	WaitingForPlayers = "Waiting for players",
	Loading = "Loading the map",
}

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "LoadingCover"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 10000
gui.Parent = player:WaitForChild("PlayerGui")

local backdrop = Instance.new("Frame")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
backdrop.BorderSizePixel = 0
backdrop.Parent = gui

-- Sized by scale, not offset: a portrait phone and a desktop window
-- both get a centred title that fits (mobile-first, CLAUDE.md rule 3).
local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.45)
title.Size = UDim2.fromScale(0.8, 0.12)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack
title.Text = "DON'T STEAL BRO!"
title.TextColor3 = Color3.fromRGB(255, 214, 64)
title.TextScaled = true
title.Parent = backdrop

local status = Instance.new("TextLabel")
status.AnchorPoint = Vector2.new(0.5, 0)
status.Position = UDim2.fromScale(0.5, 0.53)
status.Size = UDim2.fromScale(0.7, 0.05)
status.BackgroundTransparency = 1
status.Font = Enum.Font.GothamMedium
status.Text = "Loading"
status.TextColor3 = Color3.fromRGB(220, 224, 235)
status.TextScaled = true
status.Parent = backdrop

local lifted = false
local baseText = "Loading"
task.spawn(function()
	local dots = 0
	while not lifted do
		dots = (dots + 1) % 4
		status.Text = baseText .. string.rep(".", dots)
		task.wait(0.35)
	end
end)

-- Snap the camera behind the character before fading, so the first
-- thing seen is the map from the player's own spot, not the camera
-- sweeping in from wherever it was while the cover was up.
local function settleCamera()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local camera = Workspace.CurrentCamera
	if root == nil or humanoid == nil or camera == nil then
		return
	end
	local look = root.CFrame.LookVector
	local focus = root.Position + Vector3.new(0, 2, 0)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(focus - look * 10 + Vector3.new(0, 4, 0), focus)
	RunService.RenderStepped:Wait()
	camera.CameraSubject = humanoid
	camera.CameraType = Enum.CameraType.Custom
end

local function lift(placed: boolean)
	if lifted then
		return
	end
	lifted = true
	if placed then
		settleCamera()
	end
	local info = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(backdrop, info, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(title, info, { TextTransparency = 1 }):Play()
	local fade = TweenService:Create(status, info, { TextTransparency = 1 })
	fade:Play()
	fade.Completed:Wait()
	gui:Destroy()
end

-- Same test as QueueController/RaceHUDController's isHubServer. With the
-- id set it is just the place id, so it is known before the game has
-- loaded; the Studio-only fallback needs Workspace.Hub, so it waits.
local GameConfig =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig")) :: any
local hubPlaceId = GameConfig.matchmaking.hubPlaceId
if hubPlaceId ~= 0 and game.PlaceId == hubPlaceId then
	baseText = "Loading lobby"
end

if not game:IsLoaded() then
	game.Loaded:Wait()
end
task.delay(FALLBACK_SECONDS, lift, false)

local isHub = if hubPlaceId == 0
	then RunService:IsStudio() and Workspace:FindFirstChild("Hub") ~= nil
	else game.PlaceId == hubPlaceId
if isHub then
	if player.Character == nil then
		player.CharacterAdded:Wait()
	end
	lift(true)
	return
end

local function check()
	local state = Workspace:GetAttribute("RoundState")
	if typeof(state) ~= "string" then
		return
	end
	if ON_MAP[state] then
		-- Placement happens at Loading, but the character's new position
		-- can land a frame or two after the attribute does.
		task.wait(0.2)
		lift(true)
	elseif STATUS[state] then
		baseText = STATUS[state]
	end
end

Workspace:GetAttributeChangedSignal("RoundState"):Connect(check)
check()
