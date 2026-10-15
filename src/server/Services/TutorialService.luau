--!strict
-- The guided tutorial round on the match server (design-decisions.md,
-- "the first-time tutorial"; tutorial seam 3). The Hub's "Try a
-- practice round" queues a solo Tutorial ticket (MatchmakingService),
-- whose group record says `tutorial` and names GameConfig.tutorial's
-- map with no vote. Only that record makes a round a tutorial
-- (TeleportLogic.isTutorial): TeleportData never can.
--
-- What a tutorial round changes, owner's answers 2026-10-15:
--
--   No race clock. RoundService.setRaceTimed(false) before Race, so
--   the race ends when the third racer finishes, as any race can.
--
--   Easy bots. NPCService slows each one (TutorialLogic.easyProfile)
--   and holds one off its last task while finishing would take a top-3
--   seat an unfinished human still needs (TutorialLogic.botMayFinish).
--   NPCBrain uses no power-ups, and its finalists always Share.
--
--   Frozen while a step pop-up is up (owner, 2026-10-15). The client
--   says when one opens and when "Got it" is tapped (TutorialPause);
--   meanwhile the bots stop (NPCService.setPaused) and the player is
--   anchored. Only during the race, and it's solo, so a lying client
--   only stalls its own round.
--
--   The reward, once per account, when the round reaches Results with
--   the player still here. DataService.claimTutorialReward makes the
--   "once"; a replay or a second claim pays nothing.
--
-- Everything else is an ordinary practice round: nothing touches a
-- streak, a stat or a leaderboard (ProgressionService's practice gate).
-- The client learns it's a tutorial from Workspace's TutorialMatch
-- attribute (OnboardingController's step prompts, RaceHUD's hidden
-- clock), and hears about its reward from TutorialRewarded.
--
-- STUDIO: set Workspace attributes DebugPracticeMatch and
-- DebugTutorialMatch before the round loads (MatchTeleportService's
-- isTutorialMatch), with studioTest.mapId on the tutorial map.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local Participants = require(ServerScriptService.Server.Participants)
local TutorialLogic = require(ServerScriptService.Server.TutorialLogic)

local config = GameConfig.tutorial

-- Read live rather than cached at Loading: bots spawn on Loading too,
-- in no set order with this service's own handler. The match kind is
-- settled before Loading (MatchTeleportService's arrival gate).
local function isActive(): boolean
	return config.enabled and (Loader.get("MatchTeleportService") :: any).isTutorialMatch() == true
end

local function cosmeticEnabled(id: string): boolean
	for _, entry in Cosmetics do
		if entry.def.id == id then
			return entry.def.enabled ~= false
		end
	end
	return false
end

-- NPCService's question before a bot completes its last task.
local function botMayFinish(): boolean
	if not isActive() then
		return true
	end
	local TaskService = Loader.get("TaskService") :: any
	local botsFinished, humansUnfinished = 0, 0
	for _, racerId in TaskService.getRacerIds() :: { number } do
		local progress = TaskService.getProgressFor(racerId)
		local done = progress ~= nil and progress.tasksCompleted >= progress.tasksAssigned
		if Participants.isNPCId(racerId) then
			if done then
				botsFinished += 1
			end
		elseif not done then
			humansUnfinished += 1
		end
	end
	return TutorialLogic.botMayFinish(botsFinished, humansUnfinished, GameConfig.qualifierCount)
end

-- ===== freezing for a step pop-up =========================================

local frozen = false

local function holdPlayers(held: boolean)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if root ~= nil and root:IsA("BasePart") then
			root.Anchored = held
		end
	end
end

local function setFrozen(on: boolean)
	if on == frozen then
		return
	end
	frozen = on
	local NPCService = Loader.get("NPCService") :: any
	NPCService.setPaused(on)
	holdPlayers(on)
end

local function handlePause(_player: Player, paused: boolean)
	local RoundService = Loader.get("RoundService") :: any
	if not isActive() or RoundService.getState() ~= "Race" then
		return
	end
	setFrozen(paused)
end

local function payRewards()
	local DataService = Loader.get("DataService") :: any
	local grants = TutorialLogic.rewardGrants(config, cosmeticEnabled(config.rewardCosmeticId))
	for _, player in Players:GetPlayers() do
		local changes = DataService.claimTutorialReward(player, grants)
		if changes ~= nil then
			print(string.format("TutorialService: paid the tutorial reward to %d", player.UserId))
			Net.fireClient("TutorialRewarded", player, { grants = grants })
		end
	end
end

local TutorialService: Loader.Service = {
	name = "TutorialService",
	dependencies = {
		"NetGuard",
		"ConfigValidator",
		"RoundService",
		"MatchTeleportService",
		"TaskService",
		"DataService",
		"NPCService",
	},

	-- True for the whole of a tutorial round.
	isActive = isActive,
	botMayFinish = botMayFinish,
}

function TutorialService:init() end

function TutorialService:start()
	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Loading", function()
		local active = isActive()
		RoundService.setRaceTimed(not active)
		Workspace:SetAttribute("TutorialMatch", if active then true else nil)
	end)
	-- Never carry a freeze out of the race, or past the player leaving.
	RoundService.onExit("Race", function()
		setFrozen(false)
	end)
	Players.PlayerRemoving:Connect(function()
		setFrozen(false)
	end)
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("TutorialPause", function(player: Player, payload: any)
		handlePause(player, payload.paused)
	end)

	RoundService.onEnter("Results", function()
		if isActive() then
			payRewards()
		end
	end)
end

return TutorialService
