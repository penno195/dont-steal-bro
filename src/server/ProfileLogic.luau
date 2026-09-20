--!strict
-- Pure logic behind DataService.luau (P1-5): the schema type, the
-- versioned migration chain, the mid-round-leave ordering rule, and the
-- bounty-tier lookup. Self-contained on purpose - no requires of sibling
-- files, no Roblox API calls anywhere - so it stays requirable under
-- Lune for headless tests (tests/ProfileLogic.spec.luau), the same shape
-- as Net.luau (P1-3) and Validate.luau (P1-4) and for the same reason.
--
-- `BountyTier` below duplicates five fields from Validate.luau's own
-- BountyTier rather than requiring that module - Luau's structural
-- typing means a real `Validate.BountyTier` value (e.g. from
-- GameConfig.bountyTiers) still satisfies this type with no cast needed,
-- so the duplication costs nothing at call sites and keeps this file
-- from needing a Roblox Instance-path require it can't resolve under
-- Lune.

local ProfileLogic = {}

-- ===== Schema v1 =========================================================

export type Stats = {
	roundsPlayed: number,
	qualifications: number,
	steals: number,
	shares: number,
	wins: number,
	losses: number,
}

-- Per design-decisions.md Q1: bounty is a fixed, deterministic ITEM
-- PACKAGE looked up from (the winner's own streak tier, their outcome
-- tier) - never a raw currency amount. `streakTier`/`outcomeTag` are
-- exactly the two lookup keys that decision names; the actual item
-- grant is a RewardTables lookup this schema only references, not
-- resolves (RewardTables doesn't exist yet - a later task).
export type OutcomeTag = "SoleStealer" | "LoneSharer" | "AllShare"

export type PendingBounty = {
	streakTier: number,
	outcomeTag: OutcomeTag,
	grantedAt: number, -- os.time() when computed; threat-model.md §13's idempotent-per-round grant audit trail
}

export type ProfileData = {
	schemaVersion: number,
	currentStreak: number,
	bestStreak: number, -- titles key off THIS, never currentStreak - gdd.md §3: "never revoked when a streak resets"
	pendingBounty: PendingBounty?,
	currency: number, -- the free-to-earn resource behind design-decisions.md Q8's "also earnable free" path - never bounty itself
	ownedCosmetics: { string },
	equipped: { [string]: string }, -- cosmetic slot -> item id
	starterPowerUps: { string }, -- <= 3 items, design-decisions.md Q8's loadout cap
	unlockedTitles: { string },
	equippedTitle: string?,
	stats: Stats,
	lastSeen: number, -- os.time() of last profile touch
}

local CURRENT_SCHEMA_VERSION = 1

local function defaultStats(): Stats
	return { roundsPlayed = 0, qualifications = 0, steals = 0, shares = 0, wins = 0, losses = 0 }
end

function ProfileLogic.newProfileTemplate(): ProfileData
	return {
		schemaVersion = CURRENT_SCHEMA_VERSION,
		currentStreak = 0,
		bestStreak = 0,
		pendingBounty = nil,
		currency = 0,
		ownedCosmetics = {},
		equipped = {},
		starterPowerUps = {},
		unlockedTitles = {},
		equippedTitle = nil,
		stats = defaultStats(),
		lastSeen = 0,
	}
end

-- ===== Migration chain ===================================================
-- Keyed by the version a profile is migrating FROM. Each step is a pure
-- function from version n to n+1 that returns a FRESH table - "never
-- mutate a profile in place without bumping the version." There's only
-- one step today (0 -> 1, schemaVersion didn't exist before this task),
-- but the chain mechanism itself is real: adding v2 later means writing
-- migrations[1] and nothing else, and ProfileLogic.migrate below walks
-- however many steps a stored profile actually needs.

local migrations: { [number]: (old: { [string]: any }) -> ProfileData } = {}

-- A profile with no `schemaVersion` at all - either genuinely pre-
-- versioning, or a raw ProfileStore template that hasn't been through
-- Profile:Reconcile() yet. Treated identically: keep whatever v1 fields
-- `old` already has, default the rest. Never mutates `old`.
migrations[0] = function(old: { [string]: any }): ProfileData
	local template = ProfileLogic.newProfileTemplate()
	return {
		schemaVersion = 1,
		currentStreak = (old.currentStreak :: number?) or template.currentStreak,
		bestStreak = (old.bestStreak :: number?) or template.bestStreak,
		pendingBounty = old.pendingBounty :: PendingBounty?,
		currency = (old.currency :: number?) or template.currency,
		ownedCosmetics = (old.ownedCosmetics :: { string }?) or template.ownedCosmetics,
		equipped = (old.equipped :: { [string]: string }?) or template.equipped,
		starterPowerUps = (old.starterPowerUps :: { string }?) or template.starterPowerUps,
		unlockedTitles = (old.unlockedTitles :: { string }?) or template.unlockedTitles,
		equippedTitle = old.equippedTitle :: string?,
		stats = (old.stats :: Stats?) or template.stats,
		lastSeen = (old.lastSeen :: number?) or template.lastSeen,
	}
end

-- Walks `data` forward from whatever `schemaVersion` it declares (0 if
-- absent) to CURRENT_SCHEMA_VERSION, one pure step at a time. Errors
-- loudly - rather than silently returning a half-migrated profile - if
-- the chain has a gap, which can only happen if a future schema bump
-- forgets to register its own migration step.
function ProfileLogic.migrate(data: { [string]: any }): ProfileData
	local version = (data.schemaVersion :: number?) or 0
	local current: { [string]: any } = data

	while version < CURRENT_SCHEMA_VERSION do
		local step = migrations[version]
		if step == nil then
			error(string.format("ProfileLogic.migrate: no migration registered from schema version %d", version), 0)
		end
		current = (step(current) :: any) :: { [string]: any }
		version = current.schemaVersion :: number
	end

	return current :: ProfileData
end

-- ===== Mid-round leave ordering =========================================

-- Pure: enforces the one ordering rule that actually matters for a
-- mid-round leave (threat-model.md §6/§13/§14's atomic-resolution
-- requirement) - any pending round outcome is applied to profile.Data
-- BEFORE the ProfileStore session ends, never after. Called from exactly
-- one place (DataService's own PlayerRemoving handler), so no other call
-- site can get the order wrong even by accident - there's only one place
-- the order is decided at all, and it's this function.
function ProfileLogic.applyLeaveSequence(applyPendingOutcome: (() -> ())?, endSession: () -> ())
	if applyPendingOutcome ~= nil then
		applyPendingOutcome()
	end
	endSession()
end

-- Pure: runs the release sequence above exactly once. `alreadyReleased`
-- reflects the caller's own per-player bookkeeping (DataService uses
-- "is this player already missing from my `profiles` table?"); when
-- true, this is a no-op - handles OnSessionEnd and PlayerRemoving both
-- firing for the same player, or any other duplicate release attempt,
-- without a second `:EndSession()` call. Returns whether it actually
-- ran, so the caller knows whether to clear its own bookkeeping.
function ProfileLogic.release(alreadyReleased: boolean, applyPendingOutcome: (() -> ())?, endSession: () -> ()): boolean
	if alreadyReleased then
		return false
	end
	ProfileLogic.applyLeaveSequence(applyPendingOutcome, endSession)
	return true
end

-- ===== Load-outcome classification =======================================

export type LoadOutcome = "Loaded" | "CancelledByLeave" | "LikelyLockedOrOutage"

-- Pure: classifies why StartSessionAsync returned what it did, so
-- DataService's own load handler has one small, testable decision point
-- instead of ad-hoc inline branching. `profileIsNil` is whether
-- StartSessionAsync returned nil; `cancelled` is whether DataService's
-- own Cancel callback is what caused that (the player already left
-- before the session finished starting) - StartSessionAsync itself never
-- says which of these happened, so the caller has to track `cancelled`
-- itself and hand it in here. The remaining case - nil with no
-- cancellation - is the session-lock diagnostic: either another server
-- still holds the lock, or a genuine DataStore outage.
function ProfileLogic.classifyLoadOutcome(profileIsNil: boolean, cancelled: boolean): LoadOutcome
	if not profileIsNil then
		return "Loaded"
	end
	if cancelled then
		return "CancelledByLeave"
	end
	return "LikelyLockedOrOutage"
end

-- ===== Bounty tier lookup ================================================

export type BountyTier = {
	tier: number,
	minStreak: number,
	soleStealerVU: number,
	loneSharerVU: number,
	allShareVU: number,
}

-- Pure: which bounty tier a streak falls into, per payoff-table.md §3's
-- ascending minStreak brackets - the highest tier whose floor the streak
-- has reached. Errors rather than guessing if `bountyTiers` doesn't
-- cover streak 0 at all; that's a GameConfig authoring bug Validate.
-- checkGameConfig (P1-4) should have already caught at boot.
function ProfileLogic.resolveBountyTier(bountyTiers: { BountyTier }, streak: number): BountyTier
	local best: BountyTier? = nil
	for _, tier in bountyTiers do
		if streak >= tier.minStreak and (best == nil or tier.minStreak > (best :: BountyTier).minStreak) then
			best = tier
		end
	end
	assert(
		best ~= nil,
		"ProfileLogic.resolveBountyTier: no bounty tier covers this streak - check GameConfig.bountyTiers"
	)
	return best :: BountyTier
end

return ProfileLogic
