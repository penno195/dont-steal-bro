--!strict
-- Daily challenges on the server (payoff-loop step 8b; the rules are
-- DailyChallengeLogic's, design-decisions.md Q1's "a payoff for every
-- round" applied case).
--
-- THE LIST lives on the profile (schema v21, `dailyChallenges`) and is
-- redrawn lazily: whoever reads it runs DailyChallengeLogic.forDay
-- against today's UTC day key, so nothing has to run at midnight.
--
-- A ROUND'S PROGRESS is not written here. ProgressionService asks
-- stepFor for a ChallengeStep and hands it to the progression writer,
-- so the progress, the coins and the XP land in the round's own
-- mutation, and the XP levels up alongside the round's. Only ranked
-- rounds get that far (ProgressionService's practice gate: owner,
-- 2026-10-18, practice never counts).
--
-- THE REROLL is the one write this file makes. Hub only: the panel is
-- there, and refusing it on a match server means nothing can push a
-- finalist's list between their write and DecisionReveal (a finished
-- "Win a round" would tell them they'd won). For the same reason the
-- after-round push is ProgressionService's, sent with the recap at
-- Results.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local DailyChallenges = require(ReplicatedStorage.Shared.Config.DailyChallenges)
local DailyChallengeLogic = require(ServerScriptService.Server.DailyChallengeLogic)
local PeriodKeys = require(ServerScriptService.Server.PeriodKeys)
local StreakTagLogic = require(ServerScriptService.Server.StreakTagLogic)

-- How often the Hub checks for a UTC day change, so a player sitting in
-- the Hub at midnight gets the new list without doing anything.
local DAY_CHECK_SECONDS = 60

local isHub = false
local lastSentDay: { [Player]: string } = {}

-- The registry as DailyChallengeLogic reads it. Cast: Validate's def
-- types its metric with Validate's own union, which Luau won't match to
-- the logic's restated one.
local defs: { DailyChallengeLogic.Def } = {}
local defsById: { [string]: DailyChallengeLogic.Def } = {}
for _, entry in DailyChallenges do
	local def = entry.def :: any
	table.insert(defs, def)
	defsById[def.id] = def
end

local function config(): DailyChallengeLogic.Config
	return GameConfig.dailyChallenges :: any
end

local function today(): string
	return PeriodKeys.dayKey(os.time())
end

-- The player's list for today: the stored one, or a fresh draw if it's
-- an older day's or none was ever drawn. Not written back: a draw is
-- the same every time it's made today, so it's stored by the first
-- write that changes it (a round or a reroll).
local function stateFor(player: Player, dayKey: string): DailyChallengeLogic.State
	local DataService = Loader.get("DataService") :: any
	return DailyChallengeLogic.forDay(DataService.getDailyChallenges(player), defs, config(), player.UserId, dayKey)
end

local function payloadFor(state: DailyChallengeLogic.State, nowUtc: number): { [string]: any }
	local slots = {}
	for _, slot in state.slots do
		local def = defsById[slot.id]
		-- A file removed mid-day still shows, as itself, until rerolled.
		table.insert(slots, {
			id = slot.id,
			label = if def ~= nil then DailyChallengeLogic.label(def) else slot.id,
			progress = slot.progress,
			target = if def ~= nil then def.target else 1,
			done = slot.done,
			coins = if def ~= nil then def.coins else 0,
			xp = if def ~= nil then def.xp else 0,
		})
	end
	local cfg = config()
	return {
		day = state.day,
		slots = slots,
		rerollsLeft = math.max(0, cfg.rerollsPerDay - state.rerollsUsed),
		allDone = { coins = cfg.allDoneCoins, xp = cfg.allDoneXp, paid = state.allDonePaid },
		resetsIn = PeriodKeys.boundsFor("Daily", nowUtc).endsAt - nowUtc,
	}
end

local function push(player: Player)
	local DataService = Loader.get("DataService") :: any
	if not DataService.isLoaded(player) then
		return
	end
	local nowUtc = os.time()
	local dayKey = PeriodKeys.dayKey(nowUtc)
	lastSentDay[player] = dayKey
	Net.fireClient("DailyChallengeState", player, payloadFor(stateFor(player, dayKey), nowUtc))
end

-- The progression writer's ChallengeStep for one ranked round.
-- `onPayout` gets what the round finished, for the ledger, the audit
-- line and the recap. The day is read inside the write, so a round
-- that ends after midnight counts toward the new day's list.
export type ChallengeStep = (state: DailyChallengeLogic.State?) -> (DailyChallengeLogic.State, { any }, number)

local function stepFor(
	player: Player,
	tally: DailyChallengeLogic.RoundTally,
	onPayout: (payout: DailyChallengeLogic.Payout) -> ()
): ChallengeStep
	return function(stored)
		local cfg = config()
		local state = DailyChallengeLogic.forDay(stored, defs, cfg, player.UserId, today())
		local after, payout = DailyChallengeLogic.applyRound(state, defs, cfg, tally)
		local grants = {}
		if payout.coins > 0 then
			table.insert(grants, { kind = "Currency", amount = payout.coins })
		end
		onPayout(payout)
		return after, grants, payout.xp
	end
end

-- The labels of the challenges a payout finished, for the recap's
-- "Challenge done" pop-up (step 8c).
local function labelsFor(ids: { string }): { string }
	local labels = {}
	for _, id in ids do
		local def = defsById[id]
		table.insert(labels, if def ~= nil then DailyChallengeLogic.label(def) else id)
	end
	return labels
end

local function handleRerollIntent(player: Player, payload: any)
	local DataService = Loader.get("DataService") :: any
	local function refuse(reason: string)
		Net.fireClient("DailyChallengeRerollResult", player, { status = "Refused", reason = reason })
	end
	if not isHub then
		refuse("NotHub")
		return
	end
	if not DataService.isLoaded(player) then
		refuse("NotLoaded")
		return
	end
	local slotIndex = payload.slot :: number
	local before = stateFor(player, today())
	local after, refusal = DailyChallengeLogic.reroll(before, slotIndex, defs, config(), player.UserId)
	if after == nil then
		refuse(refusal or "NoCandidate")
		push(player) -- the panel may be showing yesterday's list
		return
	end
	if not DataService.setDailyChallenges(player, after) then
		refuse("NotSaved")
		return
	end
	print(
		string.format(
			"DailyChallenges: %s rerolled slot %d %s -> %s (day %s)",
			player.Name,
			slotIndex,
			before.slots[slotIndex].id,
			after.slots[slotIndex].id,
			after.day
		)
	)
	Net.fireClient("DailyChallengeRerollResult", player, { status = "Rerolled", slot = slotIndex })
	push(player)
end

local DailyChallengeService: Loader.Service = {
	name = "DailyChallengeService",
	dependencies = { "NetGuard", "DataService" },

	push = push,
	stepFor = stepFor,
	labelsFor = labelsFor,
}

function DailyChallengeService:init()
	isHub = StreakTagLogic.isHub(
		game.PlaceId,
		GameConfig.matchmaking.hubPlaceId,
		RunService:IsStudio(),
		Workspace:FindFirstChild("Hub") ~= nil
	)
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("DailyChallengeRerollIntent", handleRerollIntent)
end

function DailyChallengeService:start()
	local DataService = Loader.get("DataService") :: any
	DataService.onLoaded(push)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastSentDay[player] = nil
	end)
	-- Hub only: a match server's list moves at Results (the recap push),
	-- and its players are back in the Hub within minutes.
	if isHub then
		task.spawn(function()
			while true do
				task.wait(DAY_CHECK_SECONDS)
				local dayKey = today()
				for _, player in Players:GetPlayers() do
					if lastSentDay[player] ~= nil and lastSentDay[player] ~= dayKey then
						push(player)
					end
				end
			end
		end)
	end
end

return DailyChallengeService
