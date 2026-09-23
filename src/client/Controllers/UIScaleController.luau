--!strict
-- The UI foundation's runtime half (P6-1). Owns three live values every
-- screen binds to, and the one way screens get created:
--
--   scale      - the global UI scale (Layout.computeScale), applied
--                through a UIScale that attachScale() puts on a root.
--   usableRect - the screen area clear of notches, the Roblox top bar
--                and home indicators, in absolute screen pixels.
--   inputMode  - UserInputService.PreferredInput: Touch, Gamepad or
--                KeyboardAndMouse.
--
-- Each is exposed as get*() plus observe*(fn), which calls fn right away
-- and on every change and returns a disconnect function. That's the
-- whole reactive surface - deliberately framework-agnostic, because the
-- UI framework (architecture.md §1: React-lua, Fusion or Vide) is P6-2's
-- call; any of them can wrap an observe function in a few lines.
--
-- WHY PreferredInput AND NOT TouchEnabled: TouchEnabled is a hardware
-- fact - it's true on a touchscreen laptop being used with a mouse, and
-- stays true on a phone with a paired controller. PreferredInput tracks
-- what the player is actually USING (the most recently used input type,
-- or Touch when there is nothing else), and changes at runtime when
-- they switch. Button prompts and focus rings follow that, not the
-- hardware list.
--
-- Presentation only: nothing here reaches the server or changes what
-- the player is allowed to do (Ground Rule 1).

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local SettingsLogic = require(ReplicatedStorage.Shared.SettingsLogic)
local Layout = require(script.Parent.Parent.UI.Layout)
local Tokens = require(script.Parent.Parent.UI.Tokens)

-- Set true (in Studio, or from the server console on a live test
-- server) to show the layout harness on every client. Harmless if a
-- client sets it locally: it only draws debug overlays for that client.
local HARNESS_ATTRIBUTE = "UILayoutHarness"
-- Same, for the component gallery (P6-2, docs/components.md).
local GALLERY_ATTRIBUTE = "UIComponentGallery"
-- Same, for the race HUD on scripted fake data (P6-3, docs/race-hud.md).
local RACE_HUD_ATTRIBUTE = "UIRaceHUDPreview"
-- Same, for the Decision Studio (P6-5, docs/decision-studio.md).
local STUDIO_ATTRIBUTE = "UIDecisionStudioPreview"

type Observable<T> = {
	get: () -> T,
	set: (T) -> (),
	observe: ((T) -> ()) -> () -> (),
}

-- A value plus listeners. `set` only notifies on an actual change, so a
-- ViewportSize event that doesn't move the scale doesn't re-layout.
local function observable<T>(initial: T): Observable<T>
	local value = initial
	local listeners: { [number]: (T) -> () } = {}
	local nextId = 0

	return {
		get = function(): T
			return value
		end,
		set = function(new: T)
			if new == value then
				return
			end
			value = new
			for _, fn in table.clone(listeners) do
				task.spawn(fn, new)
			end
		end,
		observe = function(fn: (T) -> ()): () -> ()
			nextId += 1
			local id = nextId
			listeners[id] = fn
			task.spawn(fn, value)
			return function()
				listeners[id] = nil
			end
		end,
	}
end

-- Rects are tables, so compare by content or every recompute would look
-- like a change.
local function sameRect(a: Layout.Rect, b: Layout.Rect): boolean
	return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

local scaleValue = observable(1)
local rectValue = observable({ x = 0, y = 0, width = 0, height = 0 } :: Layout.Rect)
local inputValue = observable(UserInputService.PreferredInput)

-- The player's HUD-scale setting (SettingsLogic.hudScale, P6-6), applied
-- on top of the computed scale. SettingsLogic keeps it >= 1, so every
-- touch target still renders at >= 44pt; it's clamped again here so a
-- caller that skipped the sanitiser can't shrink them either.
local userMultiplier = 1

-- Roblox's own text-size setting (GuiService.PreferredTextSize). It can
-- raise the multiplier but never lower it (P6-8). See
-- SettingsLogic.SYSTEM_TEXT_SCALE for why text scales through here.
local function systemTextSize(): string
	return GuiService.PreferredTextSize.Name
end

-- The usable rect in absolute screen pixels. GetInsetArea gives the
-- CoreUISafeInsets region directly - the same one a ScreenGui with
-- ScreenInsets = CoreUISafeInsets lays out in. Falls back to the
-- viewport minus GetGuiInset if it reports an empty rect, which it
-- can for the first frame before the core UI has measured itself.
local function readUsableRect(viewport: Vector2): Layout.Rect
	local area = GuiService:GetInsetArea(Enum.ScreenInsets.CoreUISafeInsets)
	local size = area.Max - area.Min
	if size.X > 0 and size.Y > 0 then
		return { x = area.Min.X, y = area.Min.Y, width = size.X, height = size.Y }
	end

	local topLeft, bottomRight = GuiService:GetGuiInset()
	return Layout.insetRect(viewport.X, viewport.Y, topLeft.X, topLeft.Y, bottomRight.X, bottomRight.Y)
end

local function recompute()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	local rect = readUsableRect(camera.ViewportSize)
	if not sameRect(rect, rectValue.get()) then
		rectValue.set(rect)
	end
	local multiplier = SettingsLogic.effectiveHudScale(userMultiplier, systemTextSize())
	scaleValue.set(Layout.computeScale(rect.width, rect.height, Tokens.scale) * multiplier)
end

local UIScaleController: Loader.Controller = {
	name = "UIScaleController",
	dependencies = {},
}

function UIScaleController.getScale(): number
	return scaleValue.get()
end

function UIScaleController.observeScale(fn: (number) -> ()): () -> ()
	return scaleValue.observe(fn)
end

-- Sets the player's HUD-scale multiplier (SettingsController) and
-- recomputes. Never below 1: see `userMultiplier`.
function UIScaleController.setUserMultiplier(multiplier: number)
	local clamped = math.max(1, multiplier)
	if clamped ~= userMultiplier then
		userMultiplier = clamped
		recompute()
	end
end

-- The usable rect for layout code: absolute screen pixels, clear of
-- notches, the top bar and home indicators.
function UIScaleController.getUsableRect(): Layout.Rect
	return rectValue.get()
end

function UIScaleController.observeUsableRect(fn: (Layout.Rect) -> ()): () -> ()
	return rectValue.observe(fn)
end

function UIScaleController.getInputMode(): Enum.PreferredInput
	return inputValue.get()
end

function UIScaleController.observeInputMode(fn: (Enum.PreferredInput) -> ()): () -> ()
	return inputValue.observe(fn)
end

-- Puts the global UIScale on `root` and keeps it current. Call it once
-- per screen root; everything under that root is then authored in
-- reference pixels (Tokens.luau "UNITS"). Returns the disconnect.
function UIScaleController.attachScale(root: GuiObject): () -> ()
	local uiScale = root:FindFirstChild("GlobalScale") :: UIScale?
	if uiScale == nil then
		local created = Instance.new("UIScale")
		created.Name = "GlobalScale"
		created.Parent = root
		uiScale = created
	end
	local target = uiScale :: UIScale
	return scaleValue.observe(function(scale: number)
		target.Scale = scale
	end)
end

export type ScreenOptions = {
	displayOrder: number,
	-- Backdrops, scrims and debug overlays that must reach the physical
	-- screen edges (under the notch too). Nothing interactive should
	-- ever be full-bleed: a button there can sit under a camera cutout.
	fullBleed: boolean?,
}

-- The one way to create a ScreenGui, so no screen forgets its insets.
--   Interactive UI: ScreenInsets = CoreUISafeInsets - clear of notches,
--   the top bar and home indicators. (That's also Roblox's default;
--   it's set explicitly so a Studio-authored ScreenGui with different
--   settings can't be copied in by mistake and silently differ.)
--   Full-bleed: ScreenInsets = None and ClipToDeviceSafeArea = false,
--   so a dimmed backdrop covers the cutout areas too instead of leaving
--   a bright strip around a modal.
function UIScaleController.createScreen(name: string, options: ScreenOptions): ScreenGui
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local existing = playerGui:FindFirstChild(name)
	if existing ~= nil then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = options.displayOrder
	if options.fullBleed then
		gui.ScreenInsets = Enum.ScreenInsets.None
		gui.ClipToDeviceSafeArea = false
	else
		gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end
	gui.Parent = playerGui
	return gui
end

function UIScaleController:init()
	local cameraConnection: RBXScriptConnection? = nil
	local function watchCamera()
		if cameraConnection ~= nil then
			cameraConnection:Disconnect()
			cameraConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera ~= nil then
			cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(recompute)
		end
		recompute()
	end

	-- CurrentCamera can be replaced (respawn, a cutscene camera), and the
	-- old one's signal would then go quiet.
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()

	-- Insets can move without the viewport changing: the top bar
	-- resizing, or the OS reporting new safe-zone offsets on rotation.
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(recompute)
	GuiService.SafeZoneOffsetsChanged:Connect(recompute)
	GuiService:GetPropertyChangedSignal("PreferredTextSize"):Connect(recompute)

	UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(function()
		inputValue.set(UserInputService.PreferredInput)
	end)
end

function UIScaleController:start()
	-- Each debug screen toggles on its own ReplicatedStorage attribute.
	-- Required on first show, not at the top, so their code isn't loaded
	-- on a normal client that never shows them.
	local screens = script.Parent.Parent.UI.Screens
	local debugScreens: { [string]: ModuleScript } = {
		[HARNESS_ATTRIBUTE] = screens.LayoutHarness,
		[GALLERY_ATTRIBUTE] = screens.ComponentGallery,
		[RACE_HUD_ATTRIBUTE] = screens.RaceHUDPreview,
		[STUDIO_ATTRIBUTE] = screens.DecisionStudioPreview,
	}
	for attribute, module in debugScreens do
		local unmount: (() -> ())? = nil
		local function sync()
			local wanted = ReplicatedStorage:GetAttribute(attribute) == true
			if wanted and unmount == nil then
				unmount = (require(module) :: any).mount(UIScaleController)
			elseif not wanted and unmount ~= nil then
				unmount()
				unmount = nil
			end
		end
		ReplicatedStorage:GetAttributeChangedSignal(attribute):Connect(sync)
		sync()
	end
end

return UIScaleController
