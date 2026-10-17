--!strict
-- Finale guesses (payoff-loop-roadmap.md step 2b). Every player knocked
-- out of the race holds one Guess Token while the Decision Studio runs
-- and spends it on the finalist they think walks out. A correct guess
-- earns one streak shield, but only when the Studio has a lone stealer
-- or a lone sharer (design-decisions.md Q7, "finale guesses"). The
-- rules are GuessLogic's; this file holds the round's window, the
-- guesses placed and the grants.
--
-- TIMING. The window opens when the Studio's finalists are known
-- (DecisionService calls openWindow after DecisionParticipants) and
-- shuts the instant the outcome is committed (resolve, called inside
-- computeOutcomeAndWriteProfiles, before DecisionReveal is fired). So
-- no guess can be placed by someone who has seen the result.
--
-- Shields are granted at that same moment, which is before Results:
-- ProgressionService's non-qualifier sweep runs on entering Results, so
-- a shield won this round takes the guesser's own not-qualifying loss
-- (the owner's answer, 2026-10-17). A guesser at streak 0 keeps it.
--
-- Q7 CONDITION 1: nothing here is broadcast. The acceptance goes to the
-- guesser alone, and the result rides their own RoundRecap.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GuessLogic = require(ServerScriptService.Server.GuessLogic)
local Participants = require(ServerScriptService.Server.Participants)

-- What a guesser's results screen shows (RoundRecap.guess).
type GuessRecap = {
	targetId: number,
	correct: boolean,
	shieldEarned: boolean,
}

local windowOpen = false
local finalistIds: { number } = {}
-- guesser -> target, this round's guesses. GuessLogic.validate's shape.
local guesses: { [number]: number } = {}
local recaps: { [number]: GuessRecap } = {}

local grantShield: ((player: Player) -> number?)? = nil

local function reset()
	windowOpen = false
	finalistIds = {}
	guesses = {}
	recaps = {}
end

local function handleGuessIntent(player: Player, targetId: number)
	if not windowOpen then
		return
	end
	-- In this round at all: a racer, not a spectator who joined late.
	if Participants.fromPlayer(player) == nil then
		return
	end
	local ok, refusal = GuessLogic.validate(player.UserId, targetId, finalistIds, guesses)
	if not ok then
		print(string.format("GuessService: %s's guess on %d refused (%s)", player.Name, targetId, tostring(refusal)))
		return
	end
	guesses[player.UserId] = targetId
	Net.fireClient("FinaleGuessAccepted", player, { targetId = targetId })
	print(string.format("GuessService: %s guessed %d walks out", player.Name, targetId))
end

-- The Studio's finalists are known: knocked-out players may guess.
local function openWindow(ids: { number })
	reset()
	finalistIds = table.clone(ids)
	windowOpen = true
end

-- The Studio's outcome is committed: shut the window and grant every
-- correct guesser a shield. `result` is the Outcomes.OutcomeResult.
local function resolve(result: GuessLogic.ResolvedResult)
	if not windowOpen then
		return
	end
	windowOpen = false

	-- Practice matches put nothing at stake (design-decisions.md Q7), a
	-- shield included. The guess is still judged for the results screen.
	local practice = (Loader.get("ProgressionService") :: any).isPracticeMatch() == true
	local winners = GuessLogic.shieldWinners(guesses, result)
	for guesserId, targetId in guesses do
		recaps[guesserId] = {
			targetId = targetId,
			correct = table.find(winners, guesserId) ~= nil,
			shieldEarned = false,
		}
	end

	local roundId = (Loader.get("RoundService") :: any).getRoundId()
	for _, guesserId in winners do
		local player = Players:GetPlayerByUserId(guesserId)
		local grant = grantShield
		if practice or player == nil or grant == nil then
			continue
		end
		local held = grant(player)
		if held ~= nil then
			recaps[guesserId].shieldEarned = true
			-- The audit line: a shield saves a streak, so every one made
			-- is logged beside the Progression: lines.
			print(
				string.format(
					"Progression: %s round=%s finale guess correct, streak shield +1 (%d held)",
					player.Name,
					roundId,
					held
				)
			)
		end
	end
end

local GuessService: Loader.Service = {
	name = "GuessService",
	dependencies = { "NetGuard", "DataService", "RoundService", "ProgressionService" },

	openWindow = openWindow,
	resolve = resolve,

	-- This player's guess for their RoundRecap, or nil if they placed none.
	recapFor = function(player: Player): GuessRecap?
		return recaps[player.UserId]
	end,
}

function GuessService:init()
	local DataService = Loader.get("DataService") :: any
	grantShield = DataService.claimShieldGranter("GuessService")

	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("FinaleGuessIntent", function(player: Player, payload: any)
		handleGuessIntent(player, payload.targetId)
	end)

	-- A Studio that ends without resolving (a shutdown, every finalist
	-- gone) leaves no window open into Results. The recaps are read on
	-- entering Results, so they're kept until Cleanup.
	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Results", function()
		windowOpen = false
	end)
	RoundService.onEnter("Cleanup", reset)
end

return GuessService
