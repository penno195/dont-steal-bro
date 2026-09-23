--!strict
-- The live values every component reads, as Vide sources (P6-2):
-- scale, input mode and reduced motion. UIScaleController (P6-1) owns
-- scale and input mode behind a plain observe(fn) surface; this module
-- is the one bridge from that surface into Vide, so no component
-- subscribes to the controller itself.
--
-- The sources are module-level and live for the whole session (they
-- mirror session-long controller state), so they're created outside any
-- Vide root and never cleaned up.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local ComponentLogic = require(script.Parent.ComponentLogic)
local Layout = require(script.Parent.Parent.Layout)
local Theme = require(script.Parent.Parent.Theme)
local UIScaleController = require(script.Parent.Parent.Parent.Controllers.UIScaleController)

local Env = {}

Env.scale = vide.source(UIScaleController.getScale())
UIScaleController.observeScale(Env.scale)

Env.inputMode = vide.source(UIScaleController.getInputMode())
UIScaleController.observeInputMode(Env.inputMode)

-- REDUCED MOTION. Two inputs, either one turns it on:
--   - the OS/Roblox accessibility toggle (GuiService.ReducedMotionEnabled)
--   - the player's own in-game setting. There is no settings store yet
--     (nothing persists player preferences), so this is a plain source
--     for that store to write when it exists: `Env.setReducedMotion`.
--     Until then it's false and the Roblox toggle alone decides.
local systemReduced = vide.source(GuiService.ReducedMotionEnabled)
GuiService:GetPropertyChangedSignal("ReducedMotionEnabled"):Connect(function()
	systemReduced(GuiService.ReducedMotionEnabled)
end)
local playerReduced = vide.source(false)

Env.reducedMotion = function(): boolean
	return systemReduced() or playerReduced()
end

function Env.setReducedMotion(on: boolean)
	playerReduced(on)
end

-- Seconds for a motion token (Theme.motion.fast/base/slow), 0 under
-- reduced motion. Reads a source, so call it inside a derive/effect to
-- track changes.
function Env.duration(seconds: number): number
	return ComponentLogic.duration(seconds, Env.reducedMotion())
end

-- A value that animates toward `target` (via vide.spring) normally, and
-- snaps to it under reduced motion. `period` is the spring's settle
-- time; pass a Theme.motion token. Must be called inside a Vide scope.
function Env.animate<T>(target: () -> T, period: number): () -> T
	local sprung = vide.spring(target, period)
	return function(): T
		return if Env.reducedMotion() then target() else sprung()
	end
end

-- Minimum hit-area edge in reference pixels for the current scale:
-- renders at Theme.touch.minTargetPoints (44) after the UIScale.
function Env.minTouchRef(): number
	return Layout.minTouchRef(Env.scale(), Theme.touch.minTargetPoints)
end

-- True when the player is on a gamepad, where focus drives everything
-- and focus rings must always be visible.
function Env.isGamepad(): boolean
	return Env.inputMode() == Enum.PreferredInput.Gamepad
end

return Env
