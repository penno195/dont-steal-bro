--!strict
-- Freezes camera and character input while something (a task view)
-- owns the screen, and restores them exactly on release (P6-4).
--
-- WHAT IT TOUCHES, AND WHAT IT MUST NOT:
--   - Character: the PlayerModule's ControlModule (Disable/Enable).
--     That stops the thumbstick, jump button, WASD and left stick at
--     the INPUT layer and hides the touch controls. It never writes
--     Humanoid.WalkSpeed/JumpPower: StatusEffects.luau is the one place
--     those are ever set (server-side). A lock that saved and restored
--     WalkSpeed would put a Freeze'd player's speed back to 16 when the
--     view closed mid-freeze, or restore a stale 0 after the freeze had
--     ended. Staying off the Humanoid makes the two compose for free: a
--     frozen player whose task view closes is still frozen, by the
--     server, for exactly as long as the server says.
--   - Camera: CameraType -> Scriptable, which stops the default camera
--     script answering drags without moving the camera. On release it
--     goes back to what it was before the FIRST lock - unless something
--     else changed it meanwhile (it's no longer Scriptable), in which
--     case that owner's value is left alone.
--
-- Reference-counted by token (TaskViewLogic lock set) so overlapping
-- owners and overlapping close paths (abort + death + round end all
-- firing for one view) can't restore early or twice.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local TaskViewLogic = require(script.Parent.TaskViewLogic)

type Controls = { Enable: (any, boolean?) -> (), Disable: (any) -> () }

local set = TaskViewLogic.newLockSet()
local savedCameraType: Enum.CameraType? = nil

-- The ControlModule, or nil if this place forked/removed PlayerModule.
-- Resolved lazily (PlayerScripts fills in after the client script
-- starts) and cached once found.
local controls: Controls? = nil
local function getControls(): Controls?
	if controls ~= nil then
		return controls
	end
	local playerScripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
	local module = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(function()
		return (require(module) :: any):GetControls()
	end)
	if ok and result ~= nil then
		controls = result :: Controls
	end
	return controls
end

local InputLock = {}

function InputLock.acquire(token: any)
	if not TaskViewLogic.acquire(set, token) then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		savedCameraType = camera.CameraType
		camera.CameraType = Enum.CameraType.Scriptable
	end
	local c = getControls()
	if c ~= nil then
		c:Disable()
	end
end

function InputLock.release(token: any)
	if not TaskViewLogic.release(set, token) then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera ~= nil and camera.CameraType == Enum.CameraType.Scriptable then
		camera.CameraType = savedCameraType or Enum.CameraType.Custom
	end
	savedCameraType = nil
	local c = getControls()
	if c ~= nil then
		c:Enable()
	end
end

function InputLock.isLocked(): boolean
	return set.count > 0
end

return InputLock
