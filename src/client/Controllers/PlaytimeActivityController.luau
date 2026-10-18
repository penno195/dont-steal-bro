--!strict
-- Tells the server this player is at the controls (payoff-loop step 5b).
-- Hub and practice time only counts toward the free season pass with
-- input in the last couple of minutes (PlaytimeLogic.isActive), and the
-- server only knows about input it's told of. So every SEND_EVERY
-- seconds, if there was any input since the last send (a key, a tap, a
-- mouse move, a thumbstick, or a held key still walking the character),
-- one empty PlaytimeActivityIntent goes up. The server stamps its own
-- clock on it; nothing here decides what counts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

local SEND_EVERY = 30 -- inside Net's rate limit, and well inside the 120s idle window

local PlaytimeActivityController: Loader.Controller = {
	name = "PlaytimeActivityController",
}

local sawInput = false

local function walking(): boolean
	local character = Players.LocalPlayer.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	return humanoid ~= nil and humanoid.MoveDirection.Magnitude > 0
end

function PlaytimeActivityController:start()
	UserInputService.InputBegan:Connect(function()
		sawInput = true
	end)
	UserInputService.InputChanged:Connect(function()
		sawInput = true
	end)
	task.spawn(function()
		while true do
			task.wait(SEND_EVERY)
			if sawInput or walking() then
				sawInput = false
				Net.fireServer("PlaytimeActivityIntent", {})
			end
		end
	end)
end

return PlaytimeActivityController
