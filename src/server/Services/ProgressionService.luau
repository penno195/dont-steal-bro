--!strict
-- Streak and bounty resolution (P4-1). `applyRoundResult` below is THE
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
local ProfileLogic = require(ServerScriptService.Server.ProfileLogic)
local ProgressionLogic = require(ServerScriptService.Server.ProgressionLogic)
local Participants = require(ServerScriptService.Server.Participants)

export type ReasonCode = ProgressionLogic.ReasonCode

export type RoundResult = {
	roundId: string,
	reason: ReasonCode,
	-- Only meaningful on a win: what this player earned. A loss clears
	-- any pending bounty regardless of what's passed here.
	bounty: ProfileLogic.PendingBounty?,
}

type LedgerEntry = {
	reason: ReasonCode,
	after: ProgressionLogic.StreakState,
}

-- The idempotency ledger: "<roundId>|<userId>" -> what was recorded.
-- Server-local and never persisted, which is the right scope: a round
-- happens entirely on one server, and a result can only be
-- double-reported by something on that same server.
local ledger: { [string]: LedgerEntry } = {}

local writeProgressionState: ((player: Player, state: ProfileLogic.ProgressionState) -> ())? = nil

local function ledgerKey(roundId: string, userId: number): string
	return string.format("%s|%d", roundId, userId)
end

local function currentRoundId(): string
	local RoundService = Loader.get("RoundService") :: any
	return RoundService.getRoundId() :: string
end

-- ===== threat-model.md §8's required launch mitigation =====================

-- "No streak credit above a defined NPC-seat threshold. Exact N is a
-- playtest tuning call, but *some* threshold must ship day one" -
-- threat-model.md §8, which ranks farming NPC-filled lobbies as the 4th
-- most damaging attack on leaderboard credibility. This is the one
-- place that check happens, so a win can't reach a streak without
-- passing it.
--
-- The decision itself lives in NPCLogic.earnsStreakCredit and the count
-- in NPCService, deliberately: "how many seats were bots" and "does
-- that still count" must not drift apart, which they would the moment
-- two services each kept their own idea of the threshold.
--
-- Returns true when NPCService isn't loaded at all, which is the honest
-- default - a round with no NPC system running had no bot seats to
-- worry about.
local function npcService(): any?
	local ok, service = pcall(function()
		return Loader.get("NPCService")
	end)
	return if ok then service else nil
end

local function shouldCreditStreak(): boolean
	local service = npcService()
	if service == nil then
		return true
	end
	return service.roundEarnsStreakCredit() :: boolean
end

local function npcSeatCount(): number
	local service = npcService()
	if service == nil then
		return 0
	end
	return service.getNPCSeatCount() :: number
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
		pendingBounty = DataService.getPendingBounty(player),
	}

	local credited = shouldCreditStreak()
	local after = ProgressionLogic.applyResult(before, result.reason, result.bounty, credited)

	-- Recorded in the ledger BEFORE the write, so even a write that
	-- errors can't leave the round open to a second attempt that would
	-- double-count. A failed write is a lost result; a double-counted
	-- one is a corrupted streak, and of the two, the second is far
	-- worse for a leaderboard nobody can audit.
	ledger[key] = { reason = result.reason, after = after }

	local write = writeProgressionState
	if write == nil then
		warn("ProgressionService: no progression writer claimed - DataService init must run first")
		return after
	end
	write(player, after :: any)

	DataService.recordRoundStat(player, ProgressionLogic.statForReason(result.reason))

	if not credited then
		-- threat-model.md §8's own cost note: an NPC-heavy round that
		-- doesn't move the streak "needs an explicit 'queue too thin for
		-- streak credit right now' message, not silent
		-- non-progression." A player who wins and sees their streak
		-- unchanged with no explanation will read it as the game
		-- eating their win, and they'd be right to.
		Net.fireClient("ProgressionStreakSkipped", player, {
			roundId = result.roundId,
			reason = result.reason,
			npcSeatCount = npcSeatCount(),
			threshold = GameConfig.npcSeatStreakCreditThreshold,
		})
	end

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

	return after
end

local function hasResultFor(roundId: string, userId: number): boolean
	return ledger[ledgerKey(roundId, userId)] ~= nil
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

		applyRoundResult(player, { roundId = roundId, reason = "FailedToQualify", bounty = nil })
		swept += 1
	end

	if swept > 0 then
		print(string.format("ProgressionService: %d non-qualifier(s) took a loss this round (Q7)", swept))
	end
end

-- ===== service =============================================================

local ProgressionService: Loader.Service = {
	name = "ProgressionService",
	dependencies = { "DataService", "RoundService", "ParticipantService" },

	applyRoundResult = applyRoundResult,
	hasResultFor = hasResultFor,

	-- Re-exported so a caller (DecisionService) maps an outcome branch
	-- to a reason code through the same function the tests cover,
	-- rather than keeping its own copy of the mapping.
	reasonForOutcome = ProgressionLogic.reasonForOutcome,

	-- threat-model.md §8, readable so a results screen can explain
	-- itself without re-deriving the rule.
	roundEarnsStreakCredit = shouldCreditStreak,
}

function ProgressionService:init()
	local DataService = Loader.get("DataService") :: any
	writeProgressionState = DataService.claimProgressionWriter("ProgressionService")

	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Results", function()
		sweepNonQualifiers()
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
