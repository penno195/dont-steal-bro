--!strict
-- Studio test mode: press Play and a round runs on a real map, with no
-- command-bar steps. Does nothing outside Studio, or when
-- GameConfig.studioTest.enabled is false.
--
-- On start it waits for `minHumans` players to finish loading their
-- data, waits `startDelaySeconds` more so a second test client can join,
-- then has MapLoaderService load `mapId` (workspace's copy if one is
-- already there, so edits made during a test session are what gets
-- played) and requests Loading.
--
-- It never picks a map by vote, and one round per session is all
-- RoundService allows (Cleanup is terminal). Stop and Play for another.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local POLL_SECONDS = 0.5

local config = GameConfig.studioTest

local function loadedHumans(): number
	local DataService = Loader.get("DataService") :: any
	local count = 0
	for _, player in Players:GetPlayers() do
		if DataService.isLoaded(player) then
			count += 1
		end
	end
	return count
end

local function run()
	while loadedHumans() < config.minHumans do
		task.wait(POLL_SECONDS)
	end
	task.wait(config.startDelaySeconds)

	local MapLoaderService = Loader.get("MapLoaderService") :: any
	if not MapLoaderService.load(config.mapId) then
		warn(
			"StudioTestService: build the map (scripts/build-graybox.luau for GrayBoxTest) or change GameConfig.studioTest.mapId"
		)
		return
	end

	-- This service's own wait above is the arrival grace; NPCs waiting
	-- out theirs as well would spawn after Race had already begun.
	local NPCService = Loader.get("NPCService") :: any
	NPCService.markArrivalGraceServed()

	local RoundService = Loader.get("RoundService") :: any
	print(
		string.format("StudioTestService: starting a round on %s with %d human(s)", config.mapId, #Players:GetPlayers())
	)
	RoundService.requestTransition("Loading")
end

local StudioTestService: Loader.Service = {
	name = "StudioTestService",
	dependencies = {
		"ConfigValidator",
		"DataService",
		"RoundService",
		"NPCService",
		"MapLoaderService",
	},
}

function StudioTestService:start()
	if not (RunService:IsStudio() and config.enabled) then
		return
	end
	task.spawn(run)
end

return StudioTestService
