--!strict
-- Pure logic behind DataService.luau (P1-5): the schema type, the
-- versioned migration chain, and the mid-round-leave ordering rule.
-- Self-contained on purpose - no requires of sibling files, no Roblox
-- API calls anywhere - so it stays requirable under Lune for headless
-- tests (tests/ProfileLogic.spec.luau), the same shape as Net.luau
-- (P1-3) and Validate.luau (P1-4) and for the same reason.

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

export type OutcomeTag = "SoleStealer" | "LoneSharer" | "AllShare"

-- What a player's most recent win paid (schema v4, rewards-roadmap.md
-- step 2b). Replaces v1-v3's PendingBounty, which keyed into a reward
-- table that was never built. design-decisions.md Q1's 2026-09-30
-- revision pays every win at once, so nothing is left pending: this is
-- the audit trail of a grant that already happened, written in the same
-- mutation as the grants it describes (DataService's progression
-- writer), so the two can't disagree.
export type WinDropRecord = {
	kind: "PowerUp" | "Cosmetic",
	id: string,
	rarity: "Common" | "Uncommon" | "Rare",
	duplicate: boolean, -- an owned cosmetic, paid as currency instead
}

export type WinRewardRecord = {
	roundId: string,
	outcomeTag: OutcomeTag,
	rung: number,
	currency: number,
	drop: WinDropRecord?,
	grantedAt: number, -- os.time(); threat-model.md §13's per-round grant audit trail
}

-- The two fields a round result moves, as one value (P4-1). They are
-- written together or not at all - see DataService's progression write
-- gate for why one atomic write beats separate mutators. Structurally
-- identical to ProgressionLogic.StreakState, which is what that module
-- computes and this one stores; neither requires the other.
export type ProgressionState = {
	currentStreak: number,
	bestStreak: number,
}

export type ProfileData = {
	schemaVersion: number,
	currentStreak: number,
	bestStreak: number, -- titles key off THIS, never currentStreak - gdd.md §3: "never revoked when a streak resets"
	currency: number, -- Q8's "also earnable free" resource, and what every win pays (Q1's 2026-09-30 revision)
	ownedCosmetics: { string },
	equipped: { [string]: string }, -- cosmetic slot -> item id
	starterPowerUps: { string }, -- <= 3 items, design-decisions.md Q8's loadout cap
	unlockedTitles: { string },
	equippedTitle: string?,
	stats: Stats,

	-- ===== schema v2, P4-5 ==============================================

	-- The PurchaseIds of recent developer product receipts, oldest
	-- first. This is the single thing that makes a receipt replay safe:
	-- it is written into Profile.Data in the SAME mutation that applies
	-- the grant, so ProfileStore saves both or neither, and a receipt
	-- Roblox re-offers after a crash or a rejoin is recognised as
	-- already-paid rather than granted twice. Trimmed oldest-first at
	-- GameConfig.store.purchaseIdCacheSize - see StoreLogic.recordPurchaseId.
	purchaseIdCache: { string },

	-- How many of each power-up this player owns for their pre-game
	-- loadout (powerups.md's "Loadout slot" acquisition path), by
	-- power-up id. Distinct from `starterPowerUps` above, which is the
	-- <= 3 items they have SELECTED out of this stock for the next
	-- round. Owning 40 Sprint Boosts and being able to take 3 items
	-- into a race are different facts, and conflating them is how a
	-- 3-item cap quietly stops being a cap.
	powerUpStock: { [string]: number },
	lastSeen: number, -- os.time() of last profile touch

	-- ===== schema v3, P6-6 ==============================================

	-- The settings screen's preferences. Stored raw and typed loosely on
	-- purpose: SettingsLogic (src/shared) owns the shape and sanitises
	-- on every read, so this module stays require-free and a value from
	-- an older client can never reach the UI out of bounds. Empty means
	-- "all defaults".
	settings: { [string]: any },

	-- ===== schema v4, rewards step 2b ===================================

	lastWinReward: WinRewardRecord?, -- nil until a first win; a loss leaves it alone

	-- ===== schema v5, rewards step 5 ====================================

	-- Season id -> this player's progress on that season's tracks. An
	-- entry appears the first time the player is seen during the season,
	-- and is kept after it ends (it's the record of what was paid).
	seasonProgress: { [string]: SeasonProgress },

	-- ===== schema v6, the Locker ========================================

	-- The loadout as it stood when the last round spent it, before stock
	-- was checked. Spending clears `starterPowerUps`, so this is what the
	-- queue strip's "Same as last round" re-arms from (design-decisions.md
	-- Q8, "the Locker and choosing a loadout"). Never spent by itself.
	lastLoadout: { string },

	-- ===== schema v7, Navigation ========================================

	-- Paid Navigation rounds not yet spent (design-decisions.md Q8,
	-- "Navigation"). A round is bought from the in-match toggle and spent
	-- on its first switch-on, so this is normally 0; it holds one only
	-- when a receipt lands after the race it was bought in has ended.
	navigationRounds: number,

	-- ===== schema v8, streak buy-back ===================================

	-- The streak this player may buy back (design-decisions.md Q7, "buying
	-- back a streak"), or nil. Set by the progression write that took the
	-- loss, replaced by the next loss, cleared by a buy-back or by the
	-- start of their next race. Only ever shown to its owner.
	buyBackOffer: BuyBackOffer?,
}

-- A lost streak still open to buying back: which round lost it, and how
-- long it was. `roundId` is what keeps it off the end screen before that
-- round's reveal (StoreLogic.mayShowBuyBack).
export type BuyBackOffer = {
	roundId: string,
	streak: number,
}

-- Structurally SeasonLogic.Progress, which computes what this stores.
-- `passSeenAt` is when this season's pass was bought (os.time()); nil =
-- premium locked. Both tracks count every season win (2026-10-09), so
-- `premiumWins` mirrors `freeWins`. The `*Paid` fields count items paid from the front of each track, which is
-- what stops a join or a retry paying an item twice.
export type SeasonProgress = {
	passSeenAt: number?,
	freeWins: number,
	premiumWins: number,
	freePaid: number,
	premiumPaid: number,
}

local CURRENT_SCHEMA_VERSION = 8

local function defaultStats(): Stats
	return { roundsPlayed = 0, qualifications = 0, steals = 0, shares = 0, wins = 0, losses = 0 }
end

function ProfileLogic.newProfileTemplate(): ProfileData
	return {
		schemaVersion = CURRENT_SCHEMA_VERSION,
		currentStreak = 0,
		bestStreak = 0,
		currency = 0,
		ownedCosmetics = {},
		equipped = {},
		starterPowerUps = {},
		purchaseIdCache = {},
		powerUpStock = {},
		settings = {},
		unlockedTitles = {},
		equippedTitle = nil,
		stats = defaultStats(),
		lastSeen = 0,
		lastWinReward = nil,
		seasonProgress = {},
		lastLoadout = {},
		navigationRounds = 0,
		buyBackOffer = nil,
	}
end

-- ===== Migration chain ===================================================
-- Keyed by the version a profile is migrating FROM. Each step is a pure
-- function from version n to n+1 that returns a FRESH table - "never
-- mutate a profile in place without bumping the version." Four steps
-- exist now: 0 -> 1 (schemaVersion didn't exist before P1-5), 1 -> 2
-- (P4-5's store fields), 2 -> 3 (P6-6's settings) and 3 -> 4 (rewards
-- step 2b's lastWinReward). Adding a v5 means writing migrations[4] and
-- bumping CURRENT_SCHEMA_VERSION, and nothing else - ProfileLogic.
-- migrate below walks however many steps a stored profile actually
-- needs, so a profile last saved under v0 arrives at v2 in one call.

-- A step is `any -> any`, not `any -> ProfileData`: a migration from n
-- to n+1 produces the shape schema n+1 had AT THE TIME, which stops
-- being ProfileData the moment a later version adds a field. Typing
-- every step as ProfileData compiled only while there was exactly one
-- step; P4-5's v2 is what made that visible. Only `migrate`'s final
-- return is cast, because only the last step's output is current.
local migrations: { [number]: (old: { [string]: any }) -> { [string]: any } } = {}

-- A profile with no `schemaVersion` at all - either genuinely pre-
-- versioning, or a raw ProfileStore template that hasn't been through
-- Profile:Reconcile() yet. Treated identically: keep whatever v1 fields
-- `old` already has, default the rest. Never mutates `old`.
migrations[0] = function(old: { [string]: any }): { [string]: any }
	return {
		schemaVersion = 1,
		currentStreak = (old.currentStreak :: number?) or 0,
		bestStreak = (old.bestStreak :: number?) or 0,
		pendingBounty = old.pendingBounty, -- v1's field; migrations[3] drops it
		currency = (old.currency :: number?) or 0,
		ownedCosmetics = (old.ownedCosmetics :: { string }?) or {},
		equipped = (old.equipped :: { [string]: string }?) or {},
		starterPowerUps = (old.starterPowerUps :: { string }?) or {},
		unlockedTitles = (old.unlockedTitles :: { string }?) or {},
		equippedTitle = old.equippedTitle :: string?,
		stats = (old.stats :: Stats?) or defaultStats(),
		lastSeen = (old.lastSeen :: number?) or 0,
	}
end

-- v1 -> v2 (P4-5): the store's two new fields. Both are additive and
-- both default to empty, so there is nothing to compute or reinterpret
-- here - but the step is written out rather than left to
-- Profile:Reconcile() for one specific reason: `purchaseIdCache` is a
-- correctness field, not a convenience one. A v1 profile arriving with
-- no cache must arrive with an EMPTY one rather than a nil one, because
-- StoreLogic.classifyReceipt reads it on the very first receipt that
-- player ever presents, and "no cache" and "cache says not yet granted"
-- have to be the same answer.
--
-- Note what is deliberately NOT done: no attempt to back-fill
-- `powerUpStock` from `starterPowerUps`. A v1 profile's selected
-- loadout was never backed by stock (nothing granted stock before this
-- task), so inventing some would hand every existing player free items.
migrations[1] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 2
	next.purchaseIdCache = (old.purchaseIdCache :: { string }?) or {}
	next.powerUpStock = (old.powerUpStock :: { [string]: number }?) or {}
	return next
end

-- v2 -> v3 (P6-6): an empty settings table, which SettingsLogic reads as
-- all defaults. Nothing to infer - no earlier version stored any
-- preference.
migrations[2] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 3
	next.settings = (old.settings :: { [string]: any }?) or {}
	return next
end

-- v3 -> v4 (rewards step 2b): `pendingBounty` gives way to
-- `lastWinReward`. Nothing carries over. A PendingBounty was a key into
-- a reward table that was never built, so no player was ever paid by
-- one and there is no grant to reconstruct.
migrations[3] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 4
	next.pendingBounty = nil
	next.lastWinReward = nil
	return next
end

-- v4 -> v5 (rewards step 5): an empty seasonProgress. No season existed
-- before this version, so there is no progress to reconstruct.
migrations[4] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 5
	next.seasonProgress = (old.seasonProgress :: { [string]: any }?) or {}
	return next
end

-- v5 -> v6 (the Locker): an empty lastLoadout. Earlier versions threw the
-- spent loadout away, so there is nothing to offer again yet.
migrations[5] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 6
	next.lastLoadout = (old.lastLoadout :: { string }?) or {}
	return next
end

-- v6 -> v7 (Navigation): no paid rounds held. Nothing earlier sold one.
migrations[6] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 7
	next.navigationRounds = (old.navigationRounds :: number?) or 0
	return next
end

-- v7 -> v8 (streak buy-back): no offer open. A streak lost before this
-- version had nothing to buy it back with.
migrations[7] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 8
	next.buyBackOffer = nil
	return next
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

return ProfileLogic
