--!strict
-- The player's settings on the client (P6-6): holds them as a Vide
-- source for the settings screen, applies each one to the thing it
-- controls, and sends changes to SettingsService to be saved.
--
-- APPLIED LOCALLY FIRST. A slider has to move under the thumb, not a
-- round trip later, so `change` applies the patch through the same
-- SettingsLogic.apply the server runs and renders that. The server's
-- SettingsState then replaces it; the two only differ if the server
-- refused something, and then the server's copy is the one that sticks.
--
-- Sends are throttled (SEND_INTERVAL, trailing): a slider drag becomes
-- one intent per interval carrying the latest values, well under
-- SettingsIntent's rate limit.
--
-- What each setting drives:
--   reducedMotion  -> Env.setReducedMotion (ORs with Roblox's toggle)
--   hudScale       -> UIScaleController.setUserMultiplier
--   colorBlindMode -> Env.colorBlindMode
--   musicVolume,
--   sfxVolume      -> the "Music" and "SFX" SoundGroups in SoundService.
--                     AudioController (P8-3) routes every Sound through
--                     one of them; ducking is on the Sound, not the group.
--   voiceEnabled   -> Muted on the player's own AudioDeviceInput, the
--                     mic the Decision Studio uses (StudioChatController).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local SettingsLogic = require(ReplicatedStorage.Shared.SettingsLogic)
local Env = require(script.Parent.Parent.UI.Components.Env)
local UIScaleController = require(script.Parent.UIScaleController)

local SEND_INTERVAL = 0.3

local settings = vide.source(SettingsLogic.defaults())
-- Nothing is saved until the server's copy has arrived: a change made
-- before then would be applied over defaults and could overwrite the
-- real saved values with them.
local loaded = vide.source(false)

local function soundGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing ~= nil and existing:IsA("SoundGroup") then
		return existing
	end
	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Parent = SoundService
	return group
end

local function applyVoice(enabled: boolean)
	local device = Players.LocalPlayer:FindFirstChild("AudioDeviceInput")
	if device ~= nil and device:IsA("AudioDeviceInput") then
		-- pcall: whether a client may write its own device's Muted has
		-- to be confirmed on device (docs/menu-screens.md). If it can't,
		-- the setting is saved and nothing else breaks.
		pcall(function()
			device.Muted = not enabled
		end)
	end
end

local function applyAll(value: SettingsLogic.PlayerSettings)
	Env.setReducedMotion(value.reducedMotion)
	Env.colorBlindMode(value.colorBlindMode)
	UIScaleController.setUserMultiplier(value.hudScale)
	soundGroup("Music").Volume = value.musicVolume
	soundGroup("SFX").Volume = value.sfxVolume
	applyVoice(value.voiceEnabled)
end

local pending: { [string]: any } = {}
local sendScheduled = false

local function flush()
	sendScheduled = false
	if next(pending) == nil then
		return
	end
	Net.fireServer("SettingsIntent", pending)
	pending = {}
end

local SettingsController: Loader.Controller = {
	name = "SettingsController",
	dependencies = { "UIScaleController" },

	settings = settings :: () -> SettingsLogic.PlayerSettings,
	loaded = loaded :: () -> boolean,
}

-- Apply `patch` (any subset of PlayerSettings) now, and queue it to be
-- saved. Ignored until the saved settings have loaded.
function SettingsController.change(patch: { [string]: any })
	if not loaded() then
		return
	end
	local nextValue = SettingsLogic.apply(settings(), patch)
	settings(nextValue)
	applyAll(nextValue)
	for key in patch do
		pending[key] = (nextValue :: any)[key]
	end
	if not sendScheduled then
		sendScheduled = true
		task.delay(SEND_INTERVAL, flush)
	end
end

function SettingsController.reset()
	SettingsController.change(SettingsLogic.defaults() :: any)
end

function SettingsController:init()
	Net.onClientEvent("SettingsState", function(payload: any)
		local value = SettingsLogic.sanitize(payload)
		-- A change still waiting to be sent is newer than this echo; keep
		-- it on screen rather than flicking back for a frame.
		if next(pending) ~= nil then
			value = SettingsLogic.apply(value, pending)
		end
		if not SettingsLogic.equal(value, settings()) then
			settings(value)
		end
		applyAll(value)
		loaded(true)
	end)

	-- The mic device can appear after this runs (voice chat enables
	-- late), so re-apply the voice setting when it does.
	Players.LocalPlayer.ChildAdded:Connect(function(child: Instance)
		if child:IsA("AudioDeviceInput") then
			applyVoice(settings().voiceEnabled)
		end
	end)
end

return SettingsController
