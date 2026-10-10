--!strict
-- The daily hunt (design-decisions.md Q1, "the daily hunt"): one hidden
-- pickup per player per UTC day, at one of the hub's HubDailyHuntSpot
-- parts. The rules are DailyHuntLogic's; this file reads the facts and
-- acts.
--
-- ONLY ITS OWNER SEES IT: each player is sent their own spot's position
-- (DailyHuntState, targeted), and DailyHuntController draws the pickup
-- on that client alone. Nothing about it is in the shared DataModel.
--
-- CLAIMING: the client says "I'm at it" and nothing else. The server
-- works out today's spot, checks the character is within
-- GameConfig.dailyHunt.claimRadius of it, and DataService.claimDailyHunt
-- writes the day and the reward in one mutation, so it pays once a day
-- whatever the client sends.
--
-- WHEN: hub servers only (StreakTagLogic.isHub). The spots are read
-- fresh on each use, so moving or adding one in Studio needs no restart.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local DailyHuntLogic = require(ServerScriptService.Server.DailyHuntLogic)
local PeriodKeys = require(ServerScriptService.Server.PeriodKeys)
local StreakTagLogic = require(ServerScriptService.Server.StreakTagLogic)

-- How often the day is checked for a rollover, so a player in the hub at
-- UTC midnight gets the new day's pickup without rejoining.
local ROLLOVER_CHECK_SECONDS = 30

local active = false
local rng = Random.new()

local function today(): string
	return PeriodKeys.dayKey(os.time())
end

local function spotPosition(spot: Instance): Vector3?
	if spot:IsA("BasePart") then
		return spot.Position
	elseif spot:IsA("Model") then
		return spot:GetPivot().Position
	end
	return nil
end

-- Today's spot position for this player, or nil when the hub has none.
local function spotFor(player: Player, dayKey: string): Vector3?
	local positions: { Vector3 } = {}
	local keys: { DailyHuntLogic.SpotKey } = {}
	for _, spot in CollectionService:GetTagged(GameConfig.dailyHunt.spotTag) do
		local position = spotPosition(spot)
		if position ~= nil and spot:IsDescendantOf(Workspace) then
			table.insert(positions, position)
			table.insert(keys, { name = spot:GetFullName(), x = position.X, y = position.Y, z = position.Z })
		end
	end
	local index = DailyHuntLogic.spotIndex(player.UserId, dayKey, #keys)
	if index == nil then
		return nil
	end
	return positions[DailyHuntLogic.spotOrder(keys)[index]]
end

local function pushState(player: Player)
	local DataService = Loader.get("DataService") :: any
	if not DataService.isLoaded(player) then
		return
	end
	local dayKey = today()
	local position = if DailyHuntLogic.isOpen(DataService.getLastHuntDay(player), dayKey)
		then spotFor(player, dayKey)
		else nil
	Net.fireClient("DailyHuntState", player, { day = dayKey, position = position })
end

-- Rebuilt per claim, so a power-up LiveConfig has switched off stops
-- being given without a restart. Sorted so a roll means the same thing
-- on every server.
local function powerUpPool(): { string }
	local LiveConfig = Loader.get("LiveConfig") :: any
	local ids: { string } = {}
	for _, entry in PowerUps do
		local def = entry.def :: any
		local acquisition = def.acquisition
		if acquisition.freelyEarnable and acquisition.loadoutEligible and LiveConfig.isPowerUpEnabled(def.id) then
			table.insert(ids, def.id)
		end
	end
	table.sort(ids)
	return ids
end

local function claim(player: Player)
	local DataService = Loader.get("DataService") :: any
	if not DataService.isLoaded(player) then
		return
	end
	local dayKey = today()
	if not DailyHuntLogic.isOpen(DataService.getLastHuntDay(player), dayKey) then
		pushState(player) -- a stale client; tell it the pickup is gone
		return
	end
	local spot = spotFor(player, dayKey)
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	if spot == nil or root == nil or (root.Position - spot).Magnitude > GameConfig.dailyHunt.claimRadius then
		return
	end

	local grant = DailyHuntLogic.rollReward(GameConfig.dailyHunt, powerUpPool(), function(): number
		return rng:NextNumber()
	end)
	local changes = DataService.claimDailyHunt(player, dayKey, grant)
	if changes == nil then
		return
	end
	print(
		string.format(
			"DailyHuntService: %s (%d) claimed %s: %s",
			player.Name,
			player.UserId,
			dayKey,
			table.concat(changes, ", ")
		)
	)
	Loader.get("StoreService").pushState(player)
	Net.fireClient("DailyHuntResult", player, grant)
	pushState(player)
end

local DailyHuntService: Loader.Service = {
	name = "DailyHuntService",
	dependencies = { "NetGuard", "DataService", "LiveConfig", "StoreService" },
}

function DailyHuntService:init()
	active = StreakTagLogic.isHub(
		game.PlaceId,
		GameConfig.matchmaking.hubPlaceId,
		RunService:IsStudio(),
		Workspace:FindFirstChild("Hub") ~= nil
	)
	if not active then
		return
	end

	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("DailyHuntClaim", function(player: Player)
		claim(player)
	end)
end

function DailyHuntService:start()
	if not active then
		return
	end

	local DataService = Loader.get("DataService") :: any
	DataService.onLoaded(pushState)

	task.spawn(function()
		local lastDay = today()
		while true do
			task.wait(ROLLOVER_CHECK_SECONDS)
			local dayKey = today()
			if PeriodKeys.hasRolledOver(lastDay, dayKey) then
				lastDay = dayKey
				for _, player in Players:GetPlayers() do
					pushState(player)
				end
			end
		end
	end)
end

return DailyHuntService
