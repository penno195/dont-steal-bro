--!strict
-- The free season pass for playtime (payoff-loop step 5b; the rules are
-- PlaytimeLogic's, design-decisions.md Q1's "a payoff for every round").
--
-- Every TICK_SECONDS each loaded player is credited the time since
-- their last tick, if that stretch counts: always in a ranked match,
-- and in the Hub or a practice match only with input in the last
-- GameConfig.playtimePass.idleWindowSeconds. Input is the server's own
-- clock stamped when a PlaytimeActivityIntent lands; the client sends no
-- time. Where the player is comes from the server alone: which place
-- this is, and whether this match is practice.
--
-- When the count reaches the week's target, StoreService grants the
-- live season's pass (SeasonLogic.buyPass, source "Playtime"), saved and
-- audited there. PlaytimeLogic.credit keeps saying "due" until the pass
-- is held, so a grant that failed is simply retried on the next tick.
--
-- The count itself rides on ProfileStore's autosave: losing a minute of
-- it to a crash costs nothing worth a save per tick. The time since the
-- last tick is dropped on leave, at most one tick's worth.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PlaytimeLogic = require(ServerScriptService.Server.PlaytimeLogic)
local SeasonLogic = require(ServerScriptService.Server.SeasonLogic)
local StreakTagLogic = require(ServerScriptService.Server.StreakTagLogic)

-- Short enough that the idle window (120s) judges roughly the stretch
-- being credited, and under maxCreditSeconds so a tick is never capped.
local TICK_SECONDS = 30
-- How often a ticking player's StoreState is re-sent so the pass
-- screen's bar moves. Any other push (a purchase, a round) also carries
-- it, so this is only for someone sitting in the Hub.
local PUSH_EVERY_SECONDS = 300

local isHub = false
local lastTickAt: { [Player]: number } = {}
local lastInputAt: { [Player]: number } = {}
local lastPushAt: { [Player]: number } = {}

local function contextFor(): PlaytimeLogic.Context
	if isHub then
		return "Hub"
	end
	if (Loader.get("ProgressionService") :: any).isPracticeMatch() == true then
		return "Practice"
	end
	return "Match"
end

local function tickPlayer(player: Player, context: PlaytimeLogic.Context, nowUtc: number)
	local DataService = Loader.get("DataService") :: any
	local StoreService = Loader.get("StoreService") :: any
	if not DataService.isLoaded(player) then
		return
	end
	local since = lastTickAt[player]
	lastTickAt[player] = nowUtc
	if since == nil then
		return -- the first tick only starts the clock
	end
	local config = GameConfig.playtimePass
	if not PlaytimeLogic.isActive(config, context, nowUtc, lastInputAt[player]) then
		return
	end
	local season: SeasonLogic.Season? = StoreService.liveSeason()
	if season == nil then
		return
	end
	local hasPass = SeasonLogic.hasPass(DataService.getSeasonProgress(player, season.id))
	local before = DataService.getPlaytime(player)
	local after, due = PlaytimeLogic.credit(config, before, season, hasPass, nowUtc, nowUtc - since)
	if after ~= before then
		DataService.setPlaytime(player, after)
	end
	if due then
		if StoreService.grantPlaytimePass(player) then
			lastPushAt[player] = nowUtc -- the grant pushed
		end
		return
	end
	if not hasPass and nowUtc - (lastPushAt[player] or 0) >= PUSH_EVERY_SECONDS then
		lastPushAt[player] = nowUtc
		StoreService.pushState(player)
	end
end

local function handleActivity(player: Player)
	lastInputAt[player] = os.time()
end

local PlaytimeService: Loader.Service = {
	name = "PlaytimeService",
	dependencies = { "NetGuard", "DataService", "StoreService", "ProgressionService" },
}

function PlaytimeService:init()
	isHub = StreakTagLogic.isHub(
		game.PlaceId,
		GameConfig.matchmaking.hubPlaceId,
		RunService:IsStudio(),
		Workspace:FindFirstChild("Hub") ~= nil
	)
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("PlaytimeActivityIntent", handleActivity)
end

function PlaytimeService:start()
	Players.PlayerRemoving:Connect(function(player: Player)
		lastTickAt[player] = nil
		lastInputAt[player] = nil
		lastPushAt[player] = nil
	end)
	task.spawn(function()
		while true do
			local context: PlaytimeLogic.Context = contextFor()
			local nowUtc = os.time()
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(function()
					tickPlayer(player, context, nowUtc)
				end)
				if not ok then
					warn(string.format("PlaytimeService: tick failed for %s: %s", player.Name, tostring(err)))
				end
			end
			task.wait(TICK_SECONDS)
		end
	end)
end

return PlaytimeService
