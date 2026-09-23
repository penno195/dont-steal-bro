--!strict
-- The player's saved preferences (P6-6's settings screen): accept a
-- change, bound it, store it in the profile, send it back. The shape,
-- defaults and bounds are SettingsLogic's (src/shared), tested
-- headlessly; this file only moves values between a client and
-- DataService.
--
-- Why a service at all for something this harmless: Roblox gives a
-- client no persistent local storage, so a preference kept only on the
-- client resets on every join. The profile is the only place it can
-- live. The server still treats the intent as hostile input (Ground
-- Rule 1) - not because a volume is worth attacking, but because an
-- unbounded value stored in a profile is a bug waiting for a reader.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local SettingsLogic = require(ReplicatedStorage.Shared.SettingsLogic)

local function push(player: Player)
	local DataService = Loader.get("DataService") :: any
	Net.fireClient("SettingsState", player, DataService.getSettings(player))
end

-- NetGuard has already checked types and rate. SettingsLogic.apply does
-- the bounds and step snapping, and keeps the current value for any
-- field it can't use. Always pushes back, even on no change: the
-- client shows its optimistic value until this arrives, so a rejected
-- or clamped change has to be answered or the screen would go on
-- showing a value the server never stored.
local function handleIntent(player: Player, patch: { [string]: any })
	local DataService = Loader.get("DataService") :: any
	if not DataService.isLoaded(player) then
		return -- the load's own push will send the real value
	end
	local current = DataService.getSettings(player)
	local nextSettings = SettingsLogic.apply(current, patch)
	if not SettingsLogic.equal(current, nextSettings) then
		DataService.setSettings(player, nextSettings)
	end
	push(player)
end

local SettingsService: Loader.Service = {
	name = "SettingsService",
	dependencies = { "NetGuard", "DataService" },
}

function SettingsService:init()
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("SettingsIntent", handleIntent)
end

function SettingsService:start()
	local DataService = Loader.get("DataService") :: any
	DataService.onLoaded(push)
end

return SettingsService
