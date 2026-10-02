--!strict
-- The streak rules (P4-1), as arithmetic. Every change to a
-- player's progression is computed here as a pure before -> after
-- transformation; ProgressionService.luau is the thin Roblox-touching
-- wrapper that reads the real profile, calls `applyResult`, and writes
-- the answer back atomically.
--
-- WHY THE SPLIT IS WORTH IT HERE ESPECIALLY: the streak is the entire
-- metagame (gdd.md) and resets completely on any loss, so "did this
-- round change my streak correctly" is the single most consequential
-- question in the game, and the one a player will be angriest about
-- getting wrong. A five-round win chain and a loss at every possible
-- point are both things a test can state directly against this module -
-- see tests/ProgressionLogic.spec.luau. Ground Rule 4.

-- Self-contained: no requires of sibling files, no Roblox API calls
-- anywhere, so it stays requirable under Lune.
--
-- What a win PAYS is not here. RewardLogic works it out and
-- ProgressionService applies it in the same write as the streak
-- (rewards-roadmap.md step 2b). This module only says whether the round
-- was a win and what that does to the streak.

local ProgressionLogic = {}

-- ===== reason codes =========================================================

-- P4-1's list, verbatim. These are analytics keys as much as control
-- flow: every streak change in the game carries exactly one of them, so
-- "why did streaks reset this week" is answerable by grouping on this
-- field rather than by reading logs.
export type ReasonCode =
	-- A win with no more specific Studio branch behind it. In practice
	-- that means a finale that never became a real three-way table -
	-- Outcomes' SoloFinalist branch, where the last finalist standing
	-- wins by default. Kept distinct from the three StudioWin* codes
	-- precisely so those stay meaningful: a spike in QualifiedWin means
	-- lobbies are emptying out before the Studio resolves, which is an
	-- operational problem, not a balance one.
	"QualifiedWin"
	| "StudioWinSoleStealer"
	| "StudioWinLoneSharer"
	| "StudioWinAllShare"
	-- Reached the Studio and lost it - stole against a stealer, or
	-- shared against a sole stealer.
	| "StudioLoss"
	-- Never reached the Studio at all: 4th-6th place, or below
	-- design-decisions.md Q2's 50% completion floor. Q7 is explicit that
	-- this is a real loss and resets the streak like any other.
	| "FailedToQualify"
	-- Left mid-Studio. design-decisions.md Q4: the leaver always
	-- personally takes the loss regardless of what the table said.
	| "ForfeitDisconnect"

local WIN_REASONS: { [string]: boolean } = {
	QualifiedWin = true,
	StudioWinSoleStealer = true,
	StudioWinLoneSharer = true,
	StudioWinAllShare = true,
}

function ProgressionLogic.isWin(reason: ReasonCode): boolean
	return WIN_REASONS[reason] == true
end

-- Maps an Outcomes.luau branch plus "did this player win it" onto the
-- reason code that gets recorded. Total over every branch Outcomes can
-- return (P3-1: the three-, two- and one-finalist sets), because a
-- branch with no mapping would otherwise silently become a loss - and
-- silently turning a win into a loss is the worst failure this file
-- could have.
function ProgressionLogic.reasonForOutcome(branch: string, won: boolean): ReasonCode
	if not won then
		return "StudioLoss"
	end

	if branch == "SoleSteal" or branch == "OneStealOneShare" then
		return "StudioWinSoleStealer"
	elseif branch == "LoneShare" then
		return "StudioWinLoneSharer"
	elseif branch == "AllShare" or branch == "TwoShare" then
		return "StudioWinAllShare"
	elseif branch == "SoloFinalist" then
		return "QualifiedWin"
	end

	-- A winner from a branch this function doesn't know. It can't happen
	-- for any branch Outcomes.resolve currently returns (AllSteal and
	-- TwoSteal have no winners at all), but a new branch added later
	-- must not silently cost somebody their streak - so an unrecognised
	-- WIN still records as a win, just the unspecific one.
	return "QualifiedWin"
end

-- ===== the state a round result changes =====================================

export type StreakState = {
	currentStreak: number,
	bestStreak: number,
}

-- THE rule, in four lines:
--
--   A win increments currentStreak and raises bestStreak to the max of
--   the two.
--   Any loss zeroes currentStreak.
--
-- bestStreak is never lowered by anything, ever - it's what titles key
-- off (gdd.md §3: "never revoked when a streak resets"), so it is the
-- one field here that only moves upward. P4-2's title ladder depends on
-- that being structurally true rather than merely usual.
--
-- Returns a NEW table; `before` is never mutated, so a caller can log
-- both sides of the change without having to snapshot first.
-- `streakCredited = false` is threat-model.md §8's required launch
-- mitigation reaching this function: a round with more than
-- GameConfig.npcSeatStreakCreditThreshold bot seats moves nobody's
-- streak, in EITHER direction.
--
-- Both directions matters and is a deliberate call. The threat model
-- only asks for "no streak credit above a defined NPC-seat threshold",
-- which on its own would mean wins stop counting while losses still
-- reset - so an honest player queueing at 4am could only ever go
-- backwards, and the mitigation aimed at farmers would land hardest on
-- exactly the players it isn't about. A round that doesn't count,
-- doesn't count.
--
-- 2026-10-02 (design-decisions.md Q5 applied case): the user ruled that
-- a real player's win always counts, NPC seats or not, so the threshold
-- is now set where it never fires. Retiring this parameter and the
-- machinery behind it is rewards-roadmap.md step 2d.
function ProgressionLogic.applyResult(before: StreakState, reason: ReasonCode, streakCredited: boolean?): StreakState
	local credited = streakCredited ~= false

	if not credited then
		return { currentStreak = before.currentStreak, bestStreak = before.bestStreak }
	end

	if not ProgressionLogic.isWin(reason) then
		return { currentStreak = 0, bestStreak = before.bestStreak }
	end

	local currentStreak = before.currentStreak + 1
	return {
		currentStreak = currentStreak,
		bestStreak = math.max(before.bestStreak, currentStreak),
	}
end

-- Which stat a reason bumps. Split out rather than inlined so the
-- win/loss stat can never disagree with the streak change that
-- accompanies it - both read `isWin`.
function ProgressionLogic.statForReason(reason: ReasonCode): "wins" | "losses"
	return if ProgressionLogic.isWin(reason) then "wins" else "losses"
end

-- ===== idempotency ==========================================================

export type DuplicateAction =
	-- The same result, reported twice - a retry, a re-fired event, a
	-- service restarted mid-round. Return what was already recorded and
	-- change nothing.
	"Retry"
	-- TWO DIFFERENT results claimed for the same player in the same
	-- round. That is not a duplicate, it's a contradiction: something
	-- has decided this player both won and lost, and whichever call
	-- lands second would silently overwrite the first.
	| "Contradiction"

-- P4-1 asks for two things that pull in opposite directions -
-- "idempotency keyed on a round id, so a retry or a duplicated event
-- cannot double-count" and "assert if it is called twice for the same
-- round for the same player." Taken literally together, the assert
-- would fire on exactly the retries the idempotency is meant to absorb.
--
-- This function is the reconciliation, and the distinction is the
-- reason code: a second call agreeing with the first is a retry and is
-- absorbed silently; a second call DISAGREEING is a real bug in a
-- caller and fails loudly. Both requirements are satisfied, and neither
-- is satisfied by punishing the harmless case.
function ProgressionLogic.classifyDuplicate(previousReason: ReasonCode, incomingReason: ReasonCode): DuplicateAction
	return if previousReason == incomingReason then "Retry" else "Contradiction"
end

-- ===== the audit line =======================================================

-- "Logs the before state, the after state, and the reason code" (P4-1's
-- own requirement). One line, one format, every change - so the whole
-- progression history of a server is greppable on a single prefix, and
-- a streak that moved without one of these is a streak that moved
-- outside ProgressionService.
function ProgressionLogic.formatAudit(
	playerName: string,
	roundId: string,
	reason: ReasonCode,
	before: StreakState,
	after: StreakState
): string
	return string.format(
		"Progression: %s round=%s reason=%s streak %d->%d best %d->%d",
		playerName,
		roundId,
		reason,
		before.currentStreak,
		after.currentStreak,
		before.bestStreak,
		after.bestStreak
	)
end

-- One line per grant a win paid (rewards-roadmap.md step 2b), on its
-- own `Reward:` prefix so the economy is greppable apart from streaks.
-- `change` is one of StoreLogic.applyGrants' lines, so a win and a
-- purchase describe the same grant the same way.
function ProgressionLogic.formatRewardAudit(
	playerName: string,
	roundId: string,
	outcomeTag: string,
	rung: number,
	change: string
): string
	return string.format("Reward: %s round=%s outcome=%s rung=%d -> %s", playerName, roundId, outcomeTag, rung, change)
end

return ProgressionLogic
