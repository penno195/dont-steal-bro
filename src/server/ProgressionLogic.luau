--!strict
-- The streak and bounty rules (P4-1), as arithmetic. Every change to a
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
-- anywhere, so it stays requirable under Lune. `PendingBounty` below
-- duplicates ProfileLogic.PendingBounty's three fields rather than
-- requiring that module, for exactly the reason ProfileLogic's own
-- header gives about Validate.BountyTier: Luau's structural typing
-- means a real ProfileLogic.PendingBounty satisfies this type with no
-- cast at the call site, and a Roblox Instance-path require here would
-- make the whole module unloadable in the test runner.

local ProgressionLogic = {}

export type PendingBounty = {
	streakTier: number,
	-- The same three literals ProfileLogic.OutcomeTag declares, spelled
	-- out rather than widened to `string`: Luau table properties are
	-- invariant, so a `{ outcomeTag: string }` is NOT assignable where a
	-- `{ outcomeTag: "SoleStealer" | "LoneSharer" | "AllShare" }` is
	-- wanted, and the structural-compatibility trick this duplication
	-- exists for only works if the types actually match.
	outcomeTag: "SoleStealer" | "LoneSharer" | "AllShare",
	grantedAt: number,
}

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
	pendingBounty: PendingBounty?,
}

-- THE rule, in six lines:
--
--   A win increments currentStreak, raises bestStreak to the max of the
--   two, and attaches the bounty this win earned.
--   Any loss zeroes currentStreak and clears pendingBounty.
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
-- The bounty still follows the normal rule. threat-model.md §8 scopes
-- itself to streak credit, and the bounty is a deterministic item
-- package (design-decisions.md Q1), not a leaderboard position - the
-- thing being protected here is the credibility of the streak ladder,
-- not the item economy. Revisit if item farming in thin lobbies turns
-- out to matter.
function ProgressionLogic.applyResult(
	before: StreakState,
	reason: ReasonCode,
	bounty: PendingBounty?,
	streakCredited: boolean?
): StreakState
	local credited = streakCredited ~= false

	if not credited then
		return {
			currentStreak = before.currentStreak,
			bestStreak = before.bestStreak,
			pendingBounty = if ProgressionLogic.isWin(reason) then bounty else nil,
		}
	end

	if not ProgressionLogic.isWin(reason) then
		-- The bounty is cleared on EVERY loss, including a forfeit, and
		-- including a loss in a round where the player had an unclaimed
		-- bounty pending from... nothing. There is no such case today
		-- (a bounty is granted and consumed inside one round), but
		-- clearing unconditionally is what makes that still true if
		-- claiming ever becomes asynchronous.
		return {
			currentStreak = 0,
			bestStreak = before.bestStreak,
			pendingBounty = nil,
		}
	end

	local currentStreak = before.currentStreak + 1
	return {
		currentStreak = currentStreak,
		bestStreak = math.max(before.bestStreak, currentStreak),
		pendingBounty = bounty,
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
	local function bountyText(state: StreakState): string
		local bounty = state.pendingBounty
		if bounty == nil then
			return "none"
		end
		return string.format("tier %d/%s", bounty.streakTier, bounty.outcomeTag)
	end

	return string.format(
		"Progression: %s round=%s reason=%s streak %d->%d best %d->%d bounty %s->%s",
		playerName,
		roundId,
		reason,
		before.currentStreak,
		after.currentStreak,
		before.bestStreak,
		after.bestStreak,
		bountyText(before),
		bountyText(after)
	)
end

return ProgressionLogic
