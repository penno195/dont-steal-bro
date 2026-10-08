--!strict
-- Navigation (design-decisions.md Q8, "Navigation"): a toggle next to
-- the direction HUD. While it's on, a path line leads the player to their
-- nearest unfinished station until the race ends.
--
-- Paying: the Unlimited Navigation pass, or one round, bought from the
-- toggle itself for 99 R$ or coins (owner, 2026-10-08: in-match only).
-- A round lands in the profile's `navigationRounds` and is spent on the
-- first switch-on of a race; switching off and on again is then free.
-- The rules are NavigationLogic's; this file reads the facts and acts.
--
-- WHY THE SERVER DRAWS THE ROUTE: the NavNode graph is server-only
-- (MapStreaming), and so is which stations a player still has. The
-- client is sent waypoints for its own player only, never a broadcast,
-- so nobody else can tell who is using it (Q7's spirit, and the
-- decision's own "drawn only on the owner's client").

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local NavigationLogic = require(ServerScriptService.Server.NavigationLogic)
local StoreLogic = require(ServerScriptService.Server.StoreLogic)

-- How often a switched-on player's route is rebuilt. Rebuilding is a
-- BFS over a few dozen nodes, and a route is only sent when it changed.
local REFRESH_SECONDS = 0.5

local PERK: Validate.StorePerk = "UnlimitedNavigation"

type PlayerState = {
	on: boolean,
	chargedRoundId: string?, -- the race a round was spent on
	wantsOnRoundId: string?, -- asked to switch on, was offered a purchase
	lastRouteKey: string?,
}

local states: { [Player]: PlayerState } = {}

local function stateFor(player: Player): PlayerState
	local state = states[player]
	if state == nil then
		state = { on = false }
		states[player] = state
	end
	return state
end

local function toPoint(position: Vector3): NavigationLogic.Point
	return { x = position.X, y = position.Y, z = position.Z }
end

-- In Race, with stations assigned. A finished racer still counts, and
-- just gets an empty path.
local function isRacing(player: Player): boolean
	if (Loader.get("RoundService") :: any).getState() ~= "Race" then
		return false
	end
	return (Loader.get("TaskService") :: any).getAssignment(player) ~= nil
end

local function ownsPass(player: Player): boolean
	return (Loader.get("StoreService") :: any).ownsPerk(player, PERK)
end

local function chargedThisRound(player: Player): boolean
	local roundId = (Loader.get("RoundService") :: any).getRoundId()
	return stateFor(player).chargedRoundId == roundId
end

-- `status` is the answer to the last thing asked: "On", "Off",
-- "NeedsPurchase" or "Unavailable". The rest is what the toggle and the
-- buy sheet show.
local function pushState(player: Player, status: string)
	Net.fireClient("NavigationState", player, {
		status = status,
		on = stateFor(player).on,
		unlimited = ownsPass(player),
		roundsHeld = (Loader.get("DataService") :: any).getNavigationRounds(player),
	})
end

local function sendPath(player: Player, stationId: string?, points: { Vector3 })
	local asPoints: { NavigationLogic.Point } = {}
	for _, point in points do
		table.insert(asPoints, toPoint(point))
	end
	local key = NavigationLogic.routeKey(stationId, asPoints)

	local state = stateFor(player)
	if state.lastRouteKey == key then
		return
	end
	state.lastRouteKey = key
	Net.fireClient("NavigationPath", player, { stationId = stationId, points = points })
end

local function clearPath(player: Player)
	stateFor(player).lastRouteKey = nil
	Net.fireClient("NavigationPath", player, { stationId = nil, points = {} })
end

-- Rebuilds one player's route: their nearest unfinished station, then
-- the NavNode chain to it, ending on the station itself.
local function refresh(player: Player)
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	if root == nil then
		return
	end

	local TaskService = Loader.get("TaskService") :: any
	local candidates: { { stationId: string, position: NavigationLogic.Point } } = {}
	for _, assignment in TaskService.getRemainingStations(player.UserId) do
		local part = TaskService.getStationPart(assignment.stationId) :: BasePart?
		if part ~= nil then
			table.insert(candidates, { stationId = assignment.stationId, position = toPoint(part.Position) })
		end
	end

	local targetId = NavigationLogic.nearestStation(toPoint(root.Position), candidates)
	local points: { Vector3 } = {}
	if targetId ~= nil then
		local target = (TaskService.getStationPart(targetId) :: BasePart).Position
		points = (Loader.get("NPCService") :: any).routeBetween(root.Position, target)
		table.insert(points, target)
	end
	sendPath(player, targetId, points)
end

local function switchOn(player: Player)
	local state = stateFor(player)
	local roundId = (Loader.get("RoundService") :: any).getRoundId()
	local DataService = Loader.get("DataService") :: any

	local answer, spend = NavigationLogic.switchOn({
		isRacing = isRacing(player),
		ownsPass = ownsPass(player),
		chargedThisRound = state.chargedRoundId == roundId,
		roundsHeld = DataService.getNavigationRounds(player),
	})

	if answer == "On" and spend then
		-- Refused only in live-ops read-only mode or an unloaded profile.
		if DataService.spendNavigationRound(player) then
			state.chargedRoundId = roundId
		else
			answer = "Unavailable"
		end
	end

	if answer == "On" then
		state.on = true
		state.wantsOnRoundId = nil
		state.lastRouteKey = nil
		refresh(player)
	elseif answer == "NeedsPurchase" then
		state.wantsOnRoundId = roundId
	end
	pushState(player, answer)
end

local function switchOff(player: Player)
	local state = stateFor(player)
	state.on = false
	state.wantsOnRoundId = nil
	clearPath(player)
	pushState(player, "Off")
end

local NavigationService: Loader.Service = {
	name = "NavigationService",
	dependencies = { "NetGuard", "RoundService", "TaskService", "DataService", "StoreService", "NPCService" },

	-- StoreService asks before opening a prompt for a round: only a
	-- racer who hasn't already paid for this race, and has no pass.
	canBuyRound = function(player: Player): boolean
		return isRacing(player) and not chargedThisRound(player) and not ownsPass(player)
	end,
}

function NavigationService:init()
	local NetGuard = Loader.get("NetGuard") :: any
	local RoundService = Loader.get("RoundService") :: any
	local StoreService = Loader.get("StoreService") :: any

	NetGuard.on("NavigationToggle", function(player: Player, payload: any)
		if payload.on then
			switchOn(player)
		else
			switchOff(player)
		end
	end)

	-- A round or the pass bought from the toggle's sheet switches it on
	-- by itself, as long as it's still the race it was bought in.
	StoreService.onGranted(function(player: Player, def: Validate.StoreItemDef)
		local sellsNavigation = def.perk == PERK or StoreLogic.grantsNavigationRound(def.grants :: any)
		local state = states[player]
		if not sellsNavigation or state == nil then
			return
		end
		if state.wantsOnRoundId ~= nil and state.wantsOnRoundId == RoundService.getRoundId() then
			switchOn(player)
		end
	end)

	-- The line lasts until the race ends.
	RoundService.onExit("Race", function()
		for player, state in states do
			state.wantsOnRoundId = nil
			if state.on then
				state.on = false
				clearPath(player)
				pushState(player, "Off")
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
end

function NavigationService:start()
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed < REFRESH_SECONDS then
			return
		end
		elapsed = 0
		for player, state in states do
			if state.on then
				refresh(player)
			end
		end
	end)
end

return NavigationService
