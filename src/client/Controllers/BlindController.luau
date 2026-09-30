--!strict
-- What Blind actually does to the victim: blurs the world and dims it,
-- so you can still walk (Blind never touches movement - powerups.md #8)
-- but can't pick out rivals, stations or pickups clearly. Before this
-- the only trace was a thin HUD edge band, and in the hub - which
-- mounts no race HUD - nothing at all.
--
-- Driven by the StatusEffectsVisual broadcast for your own id, which
-- fires on every change including expiry, so it works the same in a
-- race and in the hub practice area.
--
-- Client-side on purpose: it's your own screen. An exploiter can delete
-- it, as they could any screen effect; what they can't do is dodge the
-- server-side effect itself (Phase Step / immunity rules still apply).
--
-- The blur only touches the 3D world, and the tint sits below every
-- other ScreenGui, so the HUD - your task list, your slots - stays
-- readable. The tint also carries the effect on a phone whose graphics
-- level drops post-processing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

local BLUR_SIZE = 24 -- BlurEffect.Size, 0-56
local TINT_TRANSPARENCY = 0.45 -- 1 = no tint
local IN_SECONDS = 0.25
local OUT_SECONDS = 0.5

local blur: BlurEffect? = nil
local tint: Frame? = nil
local blinded = false

local function ensureVisuals(): (BlurEffect, Frame)
	local camera = Workspace.CurrentCamera
	local currentBlur = blur
	if currentBlur == nil or currentBlur.Parent ~= camera then
		local created = Instance.new("BlurEffect")
		created.Name = "BlindBlur"
		created.Size = 0
		created.Parent = camera
		currentBlur = created
		blur = created
	end

	local currentTint = tint
	if currentTint == nil or currentTint.Parent == nil then
		local gui = Instance.new("ScreenGui")
		gui.Name = "BlindTint"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = -10 -- under the HUD
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Parent = gui
		gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		currentTint = frame
		tint = frame
	end

	return currentBlur :: BlurEffect, currentTint :: Frame
end

local function setBlinded(on: boolean)
	if on == blinded then
		return
	end
	blinded = on
	local blurEffect, frame = ensureVisuals()
	local info = TweenInfo.new(if on then IN_SECONDS else OUT_SECONDS, Enum.EasingStyle.Quad)
	TweenService:Create(blurEffect, info, { Size = if on then BLUR_SIZE else 0 }):Play()
	TweenService:Create(frame, info, { BackgroundTransparency = if on then TINT_TRANSPARENCY else 1 }):Play()
end

local BlindController: Loader.Controller = {
	name = "BlindController",
}

function BlindController:init()
	Net.onClientEvent("StatusEffectsVisual", function(payload: any)
		if payload.playerId ~= Players.LocalPlayer.UserId then
			return
		end
		local categories = if type(payload.categories) == "table" then payload.categories else {}
		setBlinded(table.find(categories, "Vision") ~= nil)
	end)
	-- A respawn clears every effect server-side; don't leave the screen
	-- blurred waiting for a broadcast about a character that's gone.
	Players.LocalPlayer.CharacterAdded:Connect(function()
		setBlinded(false)
	end)
end

return BlindController
