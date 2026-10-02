--!strict
-- Streak resolution (P4-1) and win rewards (rewards-roadmap.md 2b). `applyRoundResult` below is THE
-- only path to a streak change anywhere in this game - not by
-- convention, but because DataService no longer publishes a way to
-- change one and hands its single atomic writer to exactly one claimant
-- (see DataService's own "progression write gate" section).
--
-- The rules themselves - what a win does, what a loss does, which
-- reason code an outcome maps to, what counts as a duplicate - are pure
-- and live in ProgressionLogic.luau, tested headlessly in
-- tests/ProgressionLogic.spec.luau. This file supplies the real
-- profile, the real round id and the real clock, and writes the answer
-- back.
--
-- ===== WHERE A STREAK COULD BE CHANGED BEFORE THIS TASK =================
--
-- P4-1 asks for this list explicitly. Three paths existed; all three
-- are closed:
--
-- 1. DecisionService.computeOutcomeAndWriteProfiles called
--    DataService.incrementStreak / resetStreak / setPendingBounty
--    directly, per finalist, with no round id and no reason code. Now
--    it calls applyRoundResult with a reason derived from the outcome
--    branch.
--
-- 2. DecisionService's pending-round-outcome resolver (the Q4 forfeit,
--    registered per qualifier in beginDecisionStudio) called
--    resetStreak + recordRoundStat("losses") at the leaver's session
--    end. Now it calls applyRoundResult with ForfeitDisconnect. This
--    one matters most: it fires during profile release, so it is the
--    path where a double-count would be hardest to notice.
--
-- 3. DataService published the three mutators to every service on the
--    loader. Now it publishes none of them, and `claimProgressionWriter`
--    errors loudly on a second claimant.
--
-- A FOURTH path never existed and should have: nothing anywhere applied
-- design-decisions.md Q7's "everyone but the winner resets, including
-- failing to qualify at all." A player who came 4th kept their streak
-- indefinitely. `sweepNonQualifiers` below closes that, and it is a
-- genuine rule fix rather than a refactor - see its own comment.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Titles = require(ReplicatedStorage.Shared.Config.Titles)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local Seasons = require(ReplicatedStorage.Shared.Config.Seasons)
local ProfileLogic = require(ServerScriptService.Server.ProfileLogic)
local SeasonLogic = require(ServerScriptService.Server.SeasonLogic)
local ProgressionLogic = require(ServerScriptService.Server.ProgressionLogic)
local RewardLogic = require(ServerScriptService.Server.RewardLogic)
local Participants = require(ServerScriptService.Server.Participants)

export type ReasonCode = ProgressionLogic.ReasonCode

export type RoundResult = {
	roundId: string,
	reason: ReasonCode,
	-- Only read on a win: which currency base the win pays
	-- (RewardLogic.currencyFor). A win with none pays nothing and warns.
	outcomeTag: ProfileLogic.OutcomeTag?,
}

type LedgerEntry = {
	reason: ReasonCode,
	after: ProgressionLogic.StreakState,
	-- P6-6: kept for the RoundRecap sent on entering Results, which
	-- can't be sent from the write itself (see sendRecaps).
	before: ProgressionLogic.StreakState,
	-- What this round paid. Rolled once and kept here, so a retry
	-- returns the same reward rather than rolling a second one.
	reward: ProfileLogic.WinRewardRecord?,
	-- The drop grant's amount: a power-up drop's stock count, or what a
	-- duplicate cosmetic paid in coins instead. Read off the grants so
	-- the screens show what was granted rather than recomputing it from
	-- a config LiveConfig can retune between roll and screen.
	dropAmount: number?,
}

-- ===== season tracks (rewards-roadmap.md step 5) ===========================

-- A win counts toward every live season's tracks. Seasons don't overlap
-- (Validate), so in practice that's at most one. Returned as a step the
-- progression writer runs inside its own mutation, so the count, the
-- items it unlocks and the streak all land together.
local function seasonStepFor(
	player: Player,
	roundId: string
): (progress: { [string]: any }) -> ({ [string]: any }, { any })
	return function(progress)
		local now = os.time()
		local updates: { [string]: any } = {}
		local grants: { any } = {}
		for _, entry in Seasons do
			local season = SeasonLogic.fromDef(entry.def :: any)
			if season == nil then
				continue
			end
			local after, paid = SeasonLogic.recordWin(progress[season.id], season, now)
			if after ~= nil and after ~= progress[season.id] then
				updates[season.id] = after
			end
			for _, item in paid do
				table.insert(grants, item.grant)
				print(
					string.format(
						"Progression: %s round=%s %s",
						player.Name,
						roundId,
						SeasonLogic.describePaid(season.id, item)
					)
				)
			end
		end
		return updates, grants
	end
end

-- ===== win rewards (rewards-roadmap.md step 2b) ============================

-- Every title's minStreak: the ladder is the reward rung axis
-- (design-decisions.md Q1's 2026-09-30 revision), so a new title file
-- is a new rung with nothing to edit here.
local rungThresholds: { number } = {}
for _, entry in Titles do
	table.insert(rungThresholds, (entry.def :: any).minStreak :: number)
end

-- Server-side randomness only. The client never sees a roll before
-- Results, and never supplies one.
local rewardRng = Random.new()

local function nextRoll(): number
	return rewardRng:NextNumber()
end

-- Rebuilt per roll rather than at load, so a power-up LiveConfig has
-- switched off stops dropping without a restart.
local function dropPool(): { RewardLogic.PoolItem }
	local LiveConfig = Loader.get("LiveConfig") :: any
	local powerUps: { RewardLogic.PowerUpSource } = {}
	for _, entry in PowerUps do
		local def = entry.def :: any
		if LiveConfig.isPowerUpEnabled(def.id) then
			table.insert(powerUps, def)
		end
	end
	local cosmetics: { RewardLogic.CosmeticSource } = {}
	for _, entry in Cosmetics do
		table.insert(cosmetics, entry.def :: any)
	end
	return RewardLogic.buildDropPool(powerUps, cosmetics)
end

-- Rolls what one win pays. `streakAfter` is the streak the win took the
-- player to (applied case 2026-10-02: a first win pays at rung 1).
local function rollReward(
	player: Player,
	roundId: string,
	outcomeTag: ProfileLogic.OutcomeTag,
	streakAfter: number
): (ProfileLogic.WinRewardRecord, { RewardLogic.Grant })
	local DataService = Loader.get("DataService") :: any
	local reward = RewardLogic.rollWinReward(
		GameConfig.winRewards,
		outcomeTag,
		streakAfter,
		rungThresholds,
		dropPool(),
		DataService.getOwnedCosmetics(player),
		nextRoll
	)

	local drop: ProfileLogic.WinDropRecord? = nil
	if reward.drop ~= nil then
		drop = {
			kind = reward.drop.item.kind,
			id = reward.drop.item.id,
			rarity = reward.drop.item.rarity,
			duplicate = reward.drop.duplicate,
		}
	end
	local record: ProfileLogic.WinRewardRecord = {
		roundId = roundId,
		outcomeTag = outcomeTag,
		rung = reward.rung,
		currency = reward.currency,
		drop = drop,
		grantedAt = os.time(),
	}
	return record, reward.grants
end

-- The idempotency ledger: "<roundId>|<userId>" -> what was recorded.
-- Server-local and never persisted, which is the right scope: a round
-- happens entirely on one server, and a result can only be
-- double-reported by something on that same server.
local ledger: { [string]: LedgerEntry } = {}

-- DataService.ProgressionWriter's shape: the reward is its WinRewardWrite
-- and the step its SeasonStep.
local writeProgressionState: ((player: Player, state: ProfileLogic.ProgressionState, reward: any, seasonStep: any) -> { string })? =
	nil

local function ledgerKey(roundId: string, userId: number): string
	return string.format("%s|%d", roundId, userId)
end

local function currentRoundId(): string
	local RoundService = Loader.get("RoundService") :: any
	return RoundService.getRoundId() :: string
end

-- ===== the one function ====================================================

-- Applies a round's result to one player's progression, exactly once.
--
-- Returns the state that is now recorded for them this round - the
-- freshly applied one, or, on a retry, the one already recorded.
--
-- DUPLICATE HANDLING, and why it isn't a flat assert: P4-1 asks both
-- for idempotency ("a retry or a duplicated event cannot double-count")
-- and for an assert on a second call for the same round and player.
-- Literally combined, the assert would fire on exactly the retries the
-- idempotency exists to absorb. So the two are reconciled on the reason
-- code (ProgressionLogic.classifyDuplicate): a second call AGREEING
-- with the first is a retry and is absorbed silently; a second call
-- DISAGREEING means something decided this player both won and lost the
-- same round, which is a caller bug that must never be papered over,
-- and that is what asserts.
local function applyRoundResult(player: Player, result: RoundResult): ProgressionLogic.StreakState
	local DataService = Loader.get("DataService") :: any
	local key = ledgerKey(result.roundId, player.UserId)

	local existing = ledger[key]
	if existing ~= nil then
		local action = ProgressionLogic.classifyDuplicate(existing.reason, result.reason)
		assert(
			action == "Retry",
			string.format(
				"ProgressionService: contradictory results for %s in round %s - already recorded %s, now told %s. One round gives a player exactly one result.",
				player.Name,
				result.roundId,
				existing.reason,
				result.reason
			)
		)
		print(
			string.format(
				"Progression: %s round=%s reason=%s IGNORED (already recorded - retry absorbed)",
				player.Name,
				result.roundId,
				result.reason
			)
		)
		return existing.after
	end

	local before: ProgressionLogic.StreakState = {
		currentStreak = DataService.getStreak(player),
		bestStreak = DataService.getBestStreak(player),
	}

	-- A real player's result always counts, however many seats were
	-- bots (design-decisions.md Q5's 2026-10-02 applied case).
	local after = ProgressionLogic.applyResult(before, result.reason)

	-- Every win pays (design-decisions.md Q1 revision). Rolled before
	-- the ledger entry so the entry carries it.
	local rewardRecord: ProfileLogic.WinRewardRecord? = nil
	local rewardGrants: { RewardLogic.Grant } = {}
	if ProgressionLogic.isWin(result.reason) then
		local outcomeTag = result.outcomeTag
		if outcomeTag ~= nil then
			-- The cast undoes the `~= nil` refinement widening the
			-- literal union to `string` (same luau-lsp quirk noted on
			-- ProgressionLogic's types).
			rewardRecord, rewardGrants =
				rollReward(player, result.roundId, outcomeTag :: ProfileLogic.OutcomeTag, after.currentStreak)
		else
			warn(
				string.format(
					"ProgressionService: %s won round %s (%s) with no outcome tag - no reward paid",
					player.Name,
					result.roundId,
					result.reason
				)
			)
		end
	end

	-- Recorded in the ledger BEFORE the write, so even a write that
	-- errors can't leave the round open to a second attempt that would
	-- double-count. A failed write is a lost result; a double-counted
	-- one is a corrupted streak (or a win paid twice), and of the two,
	-- the second is far worse for a leaderboard nobody can audit.
	-- rollWinReward lists the currency grant first, then the drop's.
	local dropGrant = if rewardRecord ~= nil and rewardRecord.drop ~= nil then rewardGrants[2] else nil
	local dropAmount = if dropGrant ~= nil then dropGrant.amount else nil
	ledger[key] = {
		reason = result.reason,
		after = after,
		before = before,
		reward = rewardRecord,
		dropAmount = dropAmount,
	}

	local write = writeProgressionState
	if write == nil then
		warn("ProgressionService: no progression writer claimed - DataService init must run first")
		return after
	end
	local rewardWrite = if rewardRecord ~= nil then { record = rewardRecord, grants = rewardGrants } else nil
	local seasonStep = if ProgressionLogic.isWin(result.reason) then seasonStepFor(player, result.roundId) else nil
	local rewardChanges = write(player, after, rewardWrite, seasonStep)

	DataService.recordRoundStat(player, ProgressionLogic.statForReason(result.reason))

	-- One audit line per grant, beside the Progression: line below.
	if rewardRecord ~= nil then
		for _, change in rewardChanges do
			print(
				ProgressionLogic.formatRewardAudit(
					player.Name,
					result.roundId,
					rewardRecord.outcomeTag,
					rewardRecord.rung,
					change
				)
			)
		end
	end

	-- No client message here. The RoundRecap is sent on entering
	-- Results (sendRecaps below). Fired from here it would land, for a
	-- finalist, just BEFORE DecisionReveal - and `reason` would tell
	-- them whether they'd won.

	-- "One auditable function that logs the before state, the after
	-- state, and the reason code" (P4-1's own requirement). Every
	-- progression change in the game passes through this print, so a
	-- streak that moved without a `Progression:` line next to it moved
	-- somewhere it shouldn't have.
	print(ProgressionLogic.formatAudit(player.Name, result.roundId, result.reason, before, after))

	-- P4-2: a win that raised bestStreak may have crossed a title
	-- threshold, and the unlock should land in the same beat as the win
	-- that earned it rather than on the player's next join. Only ever
	-- called AFTER the write, so TitleService reads the new bestStreak.
	if after.bestStreak > before.bestStreak then
		local ok, titleService = pcall(function()
			return Loader.get("TitleService")
		end)
		if ok and titleService ~= nil then
			(titleService :: any).refreshFor(player)
		end

		-- P4-3: a new personal best is the ONLY thing the all-time board
		-- cares about, and this is the only place one can happen - so the
		-- leaderboard write is issued from here rather than polled for.
		-- Fire-and-forget: the submit spawns its own thread, because a
		-- write can retry with backoff for tens of seconds and a round
		-- must never wait on a leaderboard.
		local boardOk, leaderboard = pcall(function()
			return Loader.get("LeaderboardService")
		end)
		if boardOk and leaderboard ~= nil then
			(leaderboard :: any).submitBestStreak(player, after.bestStreak)
		end
	end

	-- P4-4: the daily and weekly boards track the streak reached WITHIN
	-- the current period, so they are fed on EVERY win rather than only
	-- on an all-time best - a player whose record is 40 but who has
	-- reached 3 today belongs on today's board at 3.
	if after.currentStreak > before.currentStreak then
		local periodOk, periodBoard = pcall(function()
			return Loader.get("LeaderboardService")
		end)
		if periodOk and periodBoard ~= nil then
			(periodBoard :: any).submitPeriodStreak(player, after.currentStreak)
		end
	end

	return after
end

local function hasResultFor(roundId: string, userId: number): boolean
	return ledger[ledgerKey(roundId, userId)] ~= nil
end

-- A win's reward as the client sees it (ResultsLogic.RecapReward /
-- DecisionLogic.Payout), from the ledger rather than the profile, so it
-- is this round's reward even if the write was skipped. Only ever sent
-- to its owner, and only after every choice is locked in (Q7's
-- 2026-10-02 applied case): your own rung is your own streak.
local function rewardPayload(entry: LedgerEntry): { [string]: any }?
	local reward = entry.reward
	if reward == nil then
		return nil
	end
	return {
		currency = reward.currency,
		rung = reward.rung,
		drop = reward.drop,
		dropAmount = entry.dropAmount,
	}
end

-- rewards-roadmap.md step 3: DecisionService adds this to a finalist's
-- DecisionPersonalResult, which only goes out after DecisionReveal.
local function rewardFor(roundId: string, userId: number): { [string]: any }?
	local entry = ledger[ledgerKey(roundId, userId)]
	return if entry ~= nil then rewardPayload(entry) else nil
end

-- ===== design-decisions.md Q7's missing half ===============================

-- "Everyone but the winner(s) resets the streak, including failing to
-- qualify at all (4th-6th place, or falling below Q2's 50% floor)" -
-- Q7, verbatim. Nothing in the codebase implemented it before P4-1: a
-- player who came 4th simply kept their streak, which quietly made the
-- streak far easier to hold than the design says and would have shown
-- up as an inexplicably top-heavy leaderboard.
--
-- Runs once per round, on entering Results - after the Studio has
-- resolved and recorded its own three finalists, so the `hasResultFor`
-- check below skips them rather than contradicting them. Anyone left is
-- by definition someone who raced and didn't qualify.
--
-- NPCs are skipped: a bot has no profile to write to, and a bot's
-- streak is not a thing that exists.
local function sweepNonQualifiers()
	local roundId = currentRoundId()
	local swept = 0

	for _, participant in Participants.humans() do
		local player = participant.player
		if player == nil or player.Parent == nil then
			continue
		end
		if hasResultFor(roundId, participant.id) then
			continue -- already recorded: a finalist, or an earlier forfeit
		end

		applyRoundResult(player, { roundId = roundId, reason = "FailedToQualify", outcomeTag = nil })
		swept += 1
	end

	if swept > 0 then
		print(string.format("ProgressionService: %d non-qualifier(s) took a loss this round (Q7)", swept))
	end
end

-- P6-6: every human still here gets their own RoundRecap (Net.luau's
-- note on it). Runs after sweepNonQualifiers, so everyone who raced has
-- a ledger entry by now, and after DecisionReveal, because Results is
-- only entered once the reveal is over - so a finalist learns nothing
-- here the reveal hasn't already shown them. A player with no entry
-- (joined mid-round, never raced) gets nothing, and the results screen
-- treats that as "you were watching".
local function sendRecaps()
	local roundId = currentRoundId()
	for _, participant in Participants.humans() do
		local player = participant.player
		local entry = ledger[ledgerKey(roundId, participant.id)]
		if player == nil or player.Parent == nil or entry == nil then
			continue
		end
		Net.fireClient("RoundRecap", player, {
			roundId = roundId,
			reason = entry.reason,
			streakBefore = entry.before.currentStreak,
			streakAfter = entry.after.currentStreak,
			bestStreakBefore = entry.before.bestStreak,
			bestStreakAfter = entry.after.bestStreak,
			reward = rewardPayload(entry),
		})
		-- The win's coins, drop and season progress, now that Results is
		-- on screen. Not from the write itself, for the reason RoundRecap
		-- isn't: it would land before DecisionReveal.
		local StoreService = Loader.get("StoreService") :: any
		StoreService.pushState(player)
	end
end

-- ===== service =============================================================

local ProgressionService: Loader.Service = {
	name = "ProgressionService",
	dependencies = { "DataService", "RoundService", "ParticipantService" },

	applyRoundResult = applyRoundResult,
	hasResultFor = hasResultFor,
	rewardFor = rewardFor,

	-- Re-exported so a caller (DecisionService) maps an outcome branch
	-- to a reason code through the same function the tests cover,
	-- rather than keeping its own copy of the mapping.
	reasonForOutcome = ProgressionLogic.reasonForOutcome,
}

function ProgressionService:init()
	local DataService = Loader.get("DataService") :: any
	writeProgressionState = DataService.claimProgressionWriter("ProgressionService")

	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Results", function()
		sweepNonQualifiers()
		sendRecaps()
	end)

	-- The ledger is per-round state, not per-server: clearing it on
	-- Cleanup keeps a long-lived server from accumulating an entry for
	-- every player of every round it ever ran. Keyed on round id anyway,
	-- so this is housekeeping rather than correctness.
	RoundService.onEnter("Cleanup", function()
		ledger = {}
	end)
end

return ProgressionService
