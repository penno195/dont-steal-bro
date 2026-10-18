--!strict
-- Streak resolution (P4-1) and win rewards (rewards-roadmap.md 2b). `applyRoundResult` below is THE
-- only path to a streak change anywhere in this game - not by
-- convention, but because DataService no longer publishes a way to
-- change one and hands its single atomic writer to exactly one claimant
-- (see DataService's own "progression write gate" section).
-- The one exception is paid and narrow: a streak buy-back receipt
-- (design-decisions.md Q7) restores the streak this writer recorded
-- losing, through StoreService's receipt path and its audit line.
-- Banking a streak in the Hub (`cashOut`, payoff-loop step 4) is not an
-- exception: it goes through this same writer, with its own reason code.
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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Titles = require(ReplicatedStorage.Shared.Config.Titles)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local Seasons = require(ReplicatedStorage.Shared.Config.Seasons)
local LevelLogic = require(ReplicatedStorage.Shared.LevelLogic)
local CashOutLogic = require(ServerScriptService.Server.CashOutLogic)
local ProfileLogic = require(ServerScriptService.Server.ProfileLogic)
local SeasonLogic = require(ServerScriptService.Server.SeasonLogic)
local ProgressionLogic = require(ServerScriptService.Server.ProgressionLogic)
local DailyChallengeLogic = require(ServerScriptService.Server.DailyChallengeLogic)
local RewardLogic = require(ServerScriptService.Server.RewardLogic)
local StreakTagLogic = require(ServerScriptService.Server.StreakTagLogic)
local Participants = require(ServerScriptService.Server.Participants)

export type ReasonCode = ProgressionLogic.ReasonCode

export type RoundResult = {
	roundId: string,
	reason: ReasonCode,
	-- Only read on a win: which currency base the win pays
	-- (RewardLogic.currencyFor). A win with none pays nothing and warns.
	outcomeTag: ProfileLogic.OutcomeTag?,
	-- A finalist's locked Studio choice, for the daily challenges'
	-- "Share and survive" (payoff-loop step 8). nil for everyone else.
	choice: ("Steal" | "Share")?,
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
	-- A practice match's result: recorded, never written (applyRoundResult).
	practice: boolean?,
	-- What the round paid in XP, coins and levels (LevelLogic.award),
	-- set by the write's level step. nil if the write never ran it.
	levelAward: LevelLogic.RoundAward?,
	-- The level cosmetics that award granted, for the recap's pop-up.
	levelCosmetics: { string }?,
	-- A streak shield took this loss instead of the streak (payoff-loop
	-- step 2): `after` kept the streak, and one shield was spent.
	shieldSpent: boolean?,
	-- What the round's daily challenges paid (payoff-loop step 8), set
	-- by the write's challenge step. nil if the write never ran it.
	challengePayout: DailyChallengeLogic.Payout?,
}

-- ===== season tracks (rewards-roadmap.md step 5) ===========================

-- A win counts toward every live season's tracks. Seasons don't overlap
-- (Validate), so in practice that's at most one. Returned as a step the
-- progression writer runs inside its own mutation, so the count, the
-- items it unlocks and the streak all land together.
local function seasonStepFor(): (progress: { [string]: any }) -> ({ [string]: any }, { any })
	return function(progress)
		local now = os.time()
		local updates: { [string]: any } = {}
		local grants: { any } = {}
		for _, entry in Seasons do
			local season = SeasonLogic.fromDef(entry.def :: any)
			if season == nil then
				continue
			end
			-- The items a win reaches wait to be claimed on the pass screen
			-- (StoreService's SeasonClaimIntent), so a win only counts.
			local after = SeasonLogic.recordWin(progress[season.id], season, now)
			if after ~= nil and after ~= progress[season.id] then
				updates[season.id] = after
			end
		end
		return updates, grants
	end
end

-- ===== every round's payoff (payoff-loop-roadmap.md step 1) ================

-- A service this file doesn't depend on, or nil if this server has none.
-- A missing source only means that part of the round pays nothing.
local function optionalService(name: string): any
	local ok, service = pcall(Loader.get, name)
	return if ok then service else nil
end

-- What `player` did this round, from the server's own records - nothing
-- here comes from a client. Read at the result, so a Studio leaver's
-- forfeit still counts their race.
local function performanceFor(player: Player, reason: ReasonCode): LevelLogic.RoundPerformance
	local tasksDone = 0
	local place: number? = nil
	local TaskService = optionalService("TaskService")
	if TaskService ~= nil then
		local progress = TaskService.getProgressFor(player.UserId)
		if progress ~= nil then
			tasksDone = progress.tasksCompleted
		end
		local qualification = TaskService.getLastQualificationResult()
		for _, entry in (if qualification ~= nil then qualification.ranked else {}) :: { any } do
			if entry.playerId == player.UserId then
				place = entry.rank
				-- A forfeit's leaver may have finished their tasks
				-- before the race state was read here; the ranking
				-- recorded them either way.
				tasksDone = math.max(tasksDone, entry.tasksCompleted)
			end
		end
	end
	local PowerUpService = optionalService("PowerUpService")
	return {
		tasksDone = tasksDone,
		place = place,
		reachedStudio = ProgressionLogic.reachedStudio(reason),
		won = ProgressionLogic.isWin(reason),
		hits = if PowerUpService ~= nil then PowerUpService.getHitsFor(player.UserId) else 0,
	}
end

-- The daily challenges' view of the same round (payoff-loop step 8):
-- the performance above plus the locked choice and the hits by
-- power-up id. All the server's own records again.
local function tallyFor(
	player: Player,
	performance: LevelLogic.RoundPerformance,
	choice: ("Steal" | "Share")?
): DailyChallengeLogic.RoundTally
	local PowerUpService = optionalService("PowerUpService")
	return {
		tasksDone = performance.tasksDone,
		place = performance.place,
		reachedStudio = performance.reachedStudio,
		won = performance.won,
		choice = choice,
		hitsByPowerUp = if PowerUpService ~= nil then PowerUpService.getHitsByPowerUpFor(player.UserId) else {},
	}
end

-- Every enabled level-only cosmetic (CosmeticDef.unlockLevel). Built per
-- round, like dropPool, so it reads the registry as it stands.
local function levelUnlocks(): { LevelLogic.LevelUnlock }
	local unlocks: { LevelLogic.LevelUnlock } = {}
	for _, entry in Cosmetics do
		local def = entry.def :: any
		if def.enabled and type(def.unlockLevel) == "number" then
			table.insert(unlocks, { id = def.id, level = def.unlockLevel })
		end
	end
	return unlocks
end

-- The progression writer's LevelStep: runs LevelLogic.award on the
-- stored XP, inside the write, and hands the award to `onAward` for the
-- ledger and the audit line. Place coins and level-up coins are one
-- Currency grant; each level cosmetic now due is a Cosmetic grant.
-- `bonusXp` is the daily challenges' XP, which levels up with the round's.
local function levelStepFor(
	performance: LevelLogic.RoundPerformance,
	onAward: (award: LevelLogic.RoundAward, cosmetics: { string }) -> ()
): (xp: number, owned: { string }, bonusXp: number) -> (number, { RewardLogic.Grant })
	return function(xp, owned, bonusXp)
		local unlocks = levelUnlocks()
		local award =
			LevelLogic.award(GameConfig.roundRewards, xp, performance, LevelLogic.milestoneLevels(unlocks), bonusXp)
		local grants: { RewardLogic.Grant } = {}
		local coins = award.placeCurrency + award.levelUpCurrency
		if coins > 0 then
			table.insert(grants, { kind = "Currency", amount = coins })
		end
		local cosmetics = LevelLogic.unlocksDue(unlocks, award.levelAfter, owned)
		for _, id in cosmetics do
			table.insert(grants, { kind = "Cosmetic", cosmeticId = id })
		end
		onAward(award, cosmetics)
		return award.xpAfter, grants
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
-- and the steps its SeasonStep and LevelStep.
local writeProgressionState: ((
	player: Player,
	state: ProfileLogic.ProgressionState,
	buyBackOffer: ProfileLogic.BuyBackOffer?,
	reward: any,
	seasonStep: any,
	levelStep: any,
	spendShield: boolean?,
	bank: any,
	challengeStep: any
) -> { string })? =
	nil

local function ledgerKey(roundId: string, userId: number): string
	return string.format("%s|%d", roundId, userId)
end

local function currentRoundId(): string
	local RoundService = Loader.get("RoundService") :: any
	return RoundService.getRoundId() :: string
end

local function isPracticeMatch(): boolean
	return (Loader.get("MatchTeleportService") :: any).isPracticeMatch() == true
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

	-- design-decisions.md Q7, the practice-match case: nothing is at
	-- stake. The result is still recorded in the ledger, so a
	-- contradiction still asserts and the recap still goes out, but the
	-- streak stays where it was and nothing is written: no reward, stat,
	-- telemetry, title, leaderboard or buy-back offer.
	if isPracticeMatch() then
		ledger[key] = { reason = result.reason, after = before, before = before, reward = nil, practice = true }
		print(
			string.format(
				"Progression: %s round=%s reason=%s PRACTICE - nothing at stake, nothing written",
				player.Name,
				result.roundId,
				result.reason
			)
		)
		return before
	end

	-- A real player's result always counts, however many seats were
	-- bots (design-decisions.md Q5's 2026-10-02 applied case).
	-- A held streak shield takes a loss of a streak of 1 or more instead
	-- of the streak (design-decisions.md Q7, "finale guesses"). Read and
	-- spent with nothing yielding in between: the write below is the
	-- spend, in the same mutation as the streak it keeps.
	local shielded = ProgressionLogic.spendsShield(before, result.reason, DataService.getStreakShields(player))
	local after = ProgressionLogic.applyResult(before, result.reason, shielded)

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
	local entry: LedgerEntry = {
		reason = result.reason,
		after = after,
		before = before,
		reward = rewardRecord,
		dropAmount = dropAmount,
		shieldSpent = if shielded then true else nil,
	}
	ledger[key] = entry

	local write = writeProgressionState
	if write == nil then
		warn("ProgressionService: no progression writer claimed - DataService init must run first")
		return after
	end
	local rewardWrite = if rewardRecord ~= nil then { record = rewardRecord, grants = rewardGrants } else nil
	local seasonStep = if ProgressionLogic.isWin(result.reason) then seasonStepFor() else nil
	local buyBackOffer = ProgressionLogic.buyBackOffer(result.roundId, before, result.reason, shielded)
	-- Every round pays, win or lose (Q1, "a payoff for every round").
	local levelCosmetics: { string } = {}
	local performance = performanceFor(player, result.reason)
	local levelStep = levelStepFor(performance, function(award, cosmetics)
		entry.levelAward = award
		entry.levelCosmetics = cosmetics
		levelCosmetics = cosmetics
	end)
	-- Ranked rounds only: practice returned above (owner, 2026-10-18).
	local challenges = optionalService("DailyChallengeService")
	local challengeStep = if challenges ~= nil
		then challenges.stepFor(player, tallyFor(player, performance, result.choice), function(payout)
			entry.challengePayout = payout
		end)
		else nil
	local rewardChanges =
		write(player, after, buyBackOffer, rewardWrite, seasonStep, levelStep, shielded, nil, challengeStep)

	DataService.recordRoundStat(player, ProgressionLogic.statForReason(result.reason))
	if ProgressionLogic.isWin(result.reason) then
		Loader.get("Telemetry").streakWin(player, after.currentStreak)
	elseif not shielded then
		-- A shielded loss lost no streak, so it isn't a streakLoss.
		Loader.get("Telemetry").streakLoss(player, before.currentStreak, result.reason)
	end

	if shielded then
		print(
			string.format(
				"Progression: %s round=%s reason=%s streak shield spent (%d left), streak %d kept",
				player.Name,
				result.roundId,
				result.reason,
				DataService.getStreakShields(player),
				before.currentStreak
			)
		)
	end

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

	local award = entry.levelAward
	if award ~= nil then
		print(
			string.format(
				"Progression: %s round=%s xp +%d (%d) level %d->%d coins +%d (place) +%d (level-ups)%s",
				player.Name,
				result.roundId,
				award.xpGained,
				award.xpAfter,
				award.levelBefore,
				award.levelAfter,
				award.placeCurrency,
				award.levelUpCurrency,
				if #levelCosmetics > 0 then " cosmetics " .. table.concat(levelCosmetics, ",") else ""
			)
		)
	end

	local payout = entry.challengePayout
	if payout ~= nil and #payout.completed > 0 then
		print(
			string.format(
				"Progression: %s round=%s daily challenges done %s coins +%d xp +%d%s",
				player.Name,
				result.roundId,
				table.concat(payout.completed, ","),
				payout.coins,
				payout.xp,
				if payout.allDone then " (all done bonus)" else ""
			)
		)
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
	-- Mid-Studio TitleService holds it until Results (before the reveal
	-- it would be a tell; TitleLogic.mayAnnounceUnlock).
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
-- What the round paid toward the account level (payoff-loop step 1c),
-- as the results screen shows it. Both ends of the bar are worked out
-- here, against the curve the award used, so a LiveConfig retune can't
-- leave the client drawing a different one. Not a streak, so it's no
-- secret, but it goes out with the recap all the same.
local function levelPayload(entry: LedgerEntry): { [string]: any }?
	local award = entry.levelAward
	if award == nil then
		return nil
	end
	local curve = GameConfig.roundRewards.level
	return {
		xpGained = award.xpGained,
		before = LevelLogic.progressFor(curve, award.xpAfter - award.xpGained),
		after = LevelLogic.progressFor(curve, award.xpAfter),
		placeCurrency = award.placeCurrency,
		levelUpCurrency = award.levelUpCurrency,
		cosmetics = entry.levelCosmetics or {},
		-- Of xpGained, what the daily challenges paid (payoff-loop step 8).
		challengeXp = award.bonusXp,
	}
end

-- The daily challenges this round finished, for the results screen's
-- "Challenge done" pop-up (payoff-loop step 8c). nil if none.
local function challengesPayload(entry: LedgerEntry): { [string]: any }?
	local payout = entry.challengePayout
	local challenges = optionalService("DailyChallengeService")
	if payout == nil or #payout.completed == 0 or challenges == nil then
		return nil
	end
	return {
		completed = challenges.labelsFor(payout.completed),
		coins = payout.coins,
		xp = payout.xp,
		allDone = payout.allDone,
	}
end

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
	local DataService = Loader.get("DataService") :: any
	local guesses = optionalService("GuessService")
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
			level = levelPayload(entry),
			challenges = challengesPayload(entry),
			practice = entry.practice,
			-- Payoff-loop step 2: whether a shield kept this streak, this
			-- player's finale guess (nil if they placed none), and the
			-- shields they now hold. All their own, to them alone.
			shieldSpent = entry.shieldSpent,
			guess = if guesses ~= nil then guesses.recapFor(player) else nil,
			streakShields = DataService.getStreakShields(player),
		})
		-- The win's coins, drop and season progress, now that Results is
		-- on screen. Not from the write itself, for the reason RoundRecap
		-- isn't: it would land before DecisionReveal.
		local StoreService = Loader.get("StoreService") :: any
		StoreService.pushState(player)
		-- The round's challenge progress, same timing, same reason: a
		-- finished "Win a round" would tell a finalist they'd won.
		local challenges = optionalService("DailyChallengeService")
		if challenges ~= nil and not entry.practice then
			challenges.push(player)
		end
	end
end

-- ===== the stakes ==========================================================

-- What each outcome would pay `player`, and its drop chance, at the
-- rung a win would put them on: the Studio's stakes panel and the
-- finale card's prize boxes (design-decisions.md Q1, "a much bigger
-- reason to steal"). The same RewardLogic calls rollReward makes, so
-- neither can promise a different number from the one a win pays.
-- `streak` is their own current streak, for the Studio's "Your streak:
-- 6, at stake" line (payoff-loop step 6): it reaches only them.
local function stakesFor(player: Player): { [string]: number }
	local DataService = Loader.get("DataService") :: any
	local streak = DataService.getStreak(player) :: number
	local rung = RewardLogic.rungFor(rungThresholds, streak + 1)
	local config = GameConfig.winRewards
	return {
		streak = streak,
		soleStealer = RewardLogic.currencyFor(config, "SoleStealer", rung),
		loneSharer = RewardLogic.currencyFor(config, "LoneSharer", rung),
		allShare = RewardLogic.currencyFor(config, "AllShare", rung),
		stealDropChance = RewardLogic.dropChanceFor(config, rung, "SoleStealer"),
		shareDropChance = RewardLogic.dropChanceFor(config, rung, "AllShare"),
	}
end

-- A human finalist's own stakes, to them alone (Q1's 2026-10-08 case):
-- at their last task (the finale card comes up then, owner 2026-10-16),
-- again as the race resolves, and at the Studio's start. None in a
-- practice match, which pays nothing.
local function sendStakes(racerId: number)
	local player = Players:GetPlayerByUserId(racerId)
	if player ~= nil and not isPracticeMatch() then
		Net.fireClient("DecisionStakes", player, stakesFor(player))
	end
end

-- ===== banking a streak (payoff-loop step 4) ==============================

-- Set in init: banking is Hub-only (design-decisions.md Q7's cash-out
-- case), so it can never show or happen in a live round.
local isHub = false

export type CashOutRefusal = CashOutLogic.Refusal | "NotHub" | "NotLoaded" | "NotSaved"

-- What banking `player`'s streak would pay right now (CashOutLogic.offer),
-- or nil off the Hub or before their profile loads. StoreState's
-- `cashOut` card.
local function cashOutOfferFor(player: Player): CashOutLogic.Offer?
	local DataService = Loader.get("DataService") :: any
	if not isHub or not DataService.isLoaded(player) then
		return nil
	end
	return CashOutLogic.offer(
		GameConfig.streakCashOut,
		DataService.getStreak(player) :: number,
		DataService.getStreakRestoredAt(player) :: number
	)
end

-- Banks `player`'s streak: coins by CashOutLogic, the streak to 0,
-- bestBanked raised, in the one progression write. `expectedStreak` is
-- the streak they confirmed on the card. Returns the offer it paid, or
-- nil and why not, having written nothing.
local function cashOut(player: Player, expectedStreak: number): (CashOutLogic.Offer?, CashOutRefusal?)
	if not isHub then
		return nil, "NotHub"
	end
	local DataService = Loader.get("DataService") :: any
	local write = writeProgressionState
	local offer = cashOutOfferFor(player)
	if offer == nil or write == nil then
		return nil, "NotLoaded"
	end
	local ok, refusal = CashOutLogic.validate(offer, expectedStreak)
	if not ok then
		-- Cast: luau-lsp widens the literal union back to `string`.
		return nil, refusal :: any
	end

	local restoredAt = DataService.getStreakRestoredAt(player) :: number
	local before: ProgressionLogic.StreakState = {
		currentStreak = DataService.getStreak(player),
		bestStreak = DataService.getBestStreak(player),
	}
	local changes = write(player, CashOutLogic.after(before), nil, nil, nil, nil, false, {
		grants = { { kind = "Currency", amount = offer.coins } },
		banked = offer.streak,
	})
	if #changes == 0 then
		-- Read-only or released mid-call: nothing was written.
		return nil, "NotSaved"
	end
	print(CashOutLogic.formatAudit(player.Name, offer, restoredAt))
	for _, change in changes do
		print(ProgressionLogic.formatRewardAudit(player.Name, "hub", "CashOut", 0, change))
	end
	return offer, nil
end

local function handleCashOutIntent(player: Player, payload: any)
	local StoreService = Loader.get("StoreService") :: any
	local offer, refusal = cashOut(player, payload.streak)
	if offer == nil then
		Net.fireClient("StreakCashOutResult", player, { status = "Refused", reason = refusal })
		-- The card may be stale (a restore landed): send the current one.
		StoreService.pushState(player)
		return
	end
	Net.fireClient("StreakCashOutResult", player, { status = "Banked", streak = offer.streak, coins = offer.coins })
	-- The coins, the 0 streak and the new best banked on the Hub's card,
	-- and the counter over their head.
	StoreService.pushState(player)
	local StreakTagService = Loader.get("StreakTagService") :: any
	StreakTagService.broadcast()
end

-- ===== service =============================================================

local ProgressionService: Loader.Service = {
	name = "ProgressionService",
	dependencies = { "DataService", "RoundService", "ParticipantService", "Telemetry", "NetGuard" },

	applyRoundResult = applyRoundResult,
	hasResultFor = hasResultFor,
	rewardFor = rewardFor,
	isPracticeMatch = isPracticeMatch,

	-- The rung a win from `streak` would pay at (the after-win rung, as
	-- rollReward uses). Analytics splits the finale by it.
	rungAtStake = function(streak: number): number
		return RewardLogic.rungFor(rungThresholds, streak + 1)
	end,

	stakesFor = stakesFor,
	sendStakes = sendStakes,

	-- The level arithmetic, for the tutorial reward's level-up
	-- (TutorialService): the same LevelStep and level-only cosmetics a
	-- round's write uses, so a level gained there pays the same.
	levelStepFor = levelStepFor,
	levelUnlocks = levelUnlocks,

	-- Banking a streak in the Hub (payoff-loop step 4).
	cashOut = cashOut,
	cashOutOfferFor = cashOutOfferFor,

	-- Re-exported so a caller (DecisionService) maps an outcome branch
	-- to a reason code through the same function the tests cover,
	-- rather than keeping its own copy of the mapping.
	reasonForOutcome = ProgressionLogic.reasonForOutcome,
}

function ProgressionService:init()
	local DataService = Loader.get("DataService") :: any
	writeProgressionState = DataService.claimProgressionWriter("ProgressionService")

	isHub = StreakTagLogic.isHub(
		game.PlaceId,
		GameConfig.matchmaking.hubPlaceId,
		RunService:IsStudio(),
		Workspace:FindFirstChild("Hub") ~= nil
	)
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("StreakCashOutIntent", handleCashOutIntent)

	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Results", function()
		sweepNonQualifiers()
		sendRecaps()
	end)

	-- A streak buy-back offer lasts until its owner's next race starts
	-- (design-decisions.md Q7, the 2026-10-08 applied case). Every human
	-- racing is past the point of buying back an earlier loss.
	RoundService.onEnter("Race", function()
		for _, participant in Participants.humans() do
			local player = participant.player
			if player ~= nil and player.Parent ~= nil and DataService.expireBuyBackOffer(player) then
				print(
					string.format("ProgressionService: %s's streak buy-back offer expired at race start", player.Name)
				)
			end
		end
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
