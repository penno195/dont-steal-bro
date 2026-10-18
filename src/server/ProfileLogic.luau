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
	-- Schema v20 (payoff-loop step 7, BetrayalLogic): times this player
	-- shared and lost to a lone stealer. Counted beside steals/shares,
	-- never in practice. Shown in the Studio's reputation line and the
	-- owner's own Hub record.
	betrayed: number,
	-- Schema v22 (payoff-loop step 9): Steal picks that won, the
	-- StealWins lifetime-title ladder. Ranked only, like the rest.
	stealWins: number,
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

	-- ===== schema v9, the daily hunt =====================================

	-- The UTC day (PeriodKeys.dayKey) this player last claimed the daily
	-- hunt's pickup, or nil if never (design-decisions.md Q1, "the daily
	-- hunt"). Written in the same mutation as the reward, so a claim
	-- pays once a day. Only the last day is kept: the reward doesn't
	-- grow with consecutive days.
	lastHuntDay: string?,

	-- ===== schema v10, Streak Saves ======================================

	-- Streak Saves held (design-decisions.md, "Applied case: staff
	-- tools"). One does what a buy-back does, spent against an open
	-- buyBackOffer instead of Robux. Bought in the store or gifted by
	-- staff, never dropped for free. Stacks with no cap.
	streakSaves: number,

	-- ===== schema v11, staff grants ======================================

	-- Unlimited Navigation given by staff ("Applied case: staff tools"),
	-- held for good. The game pass is still checked live and never
	-- written here; this is the only other way to own the perk.
	unlimitedNavigation: boolean,

	-- ===== schema v12, staff gift pop-up =================================

	-- Staff gifts the player hasn't seen the pop-up for yet, oldest
	-- first (staff-tools.md step 3). The gift itself is applied when
	-- given; this is only what the Hub's "GIFT RECEIVED!" pop-up shows,
	-- kept here so it outlasts a match server and a closed game.
	-- StaffGrantLogic.noteUnseen / markSeen keep it, capped.
	unseenGifts: { UnseenGift },

	-- ===== schema v13, the first-time tutorial ===========================

	-- Whether this account has been paid for finishing the guided
	-- practice round (design-decisions.md, "the first-time tutorial").
	-- Set in the same mutation as the reward, so it pays once ever.
	tutorialRewarded: boolean,

	-- ===== schema v14, the tutorial reward reveal ========================

	-- Paid but not yet revealed. The guided round pays at its Results;
	-- the "you won" reveal waits for the Hub (owner, 2026-10-15), so it
	-- outlasts the match server like unseenGifts. Cleared when the Hub
	-- client says it showed it (TutorialRewardSeenIntent).
	tutorialRewardUnseen: boolean,

	-- ===== schema v15, the hub tutorial's Locker gift ====================

	-- Whether the hub tutorial's Locker step has given this account its
	-- free power-up (GameConfig.tutorial.lockerGiftPowerUpId; tutorial
	-- v2 seam 3). Set in the same mutation as the grant, so it gives
	-- once ever, however often the tutorial is replayed.
	tutorialGiftGiven: boolean,

	-- ===== schema v16, XP and account level ===============================

	-- Lifetime XP (design-decisions.md Q1, "a payoff for every round";
	-- payoff-loop-roadmap.md step 1). Only the XP is stored: the level is
	-- always LevelLogic.progressFor(xp), so the two can never disagree.
	-- Never resets. Written by the progression writer, in the same
	-- mutation as the round's streak result.
	xp: number,

	-- ===== schema v17, streak shields =====================================

	-- Streak shields held (design-decisions.md Q7, "finale guesses";
	-- payoff-loop-roadmap.md step 2). One is earned by a correct finale
	-- guess and spent by the progression writer on a loss of a streak of
	-- 1 or more, which then keeps the streak (ProgressionLogic
	-- .spendsShield). Stacks with no cap. Only ever shown to its owner.
	streakShields: number,

	-- ===== schema v18, banking a streak ===================================

	-- The longest streak ever banked in the Hub (payoff-loop step 4,
	-- CashOutLogic). Only goes up. Shown to its owner in the Hub.
	bestBanked: number,
	-- The streak the last buy-back or Streak Save brought back, so
	-- banking it pays only for the wins since (owner, 2026-10-17). 0 when
	-- the current streak holds no restore; the progression writer clears
	-- it whenever the streak goes back to 0.
	streakRestoredAt: number,

	-- ===== schema v19, the playtime pass ==================================

	-- Active seconds counted toward the free season pass this week of
	-- this season (payoff-loop step 5, PlaytimeLogic.State). nil = none
	-- counted yet. A stale week or season reads as 0, so nothing resets
	-- it on a schedule. Written only by PlaytimeService.
	playtime: PlaytimeState?,

	-- ===== schema v21, daily challenges ===================================

	-- Today's three daily challenges and their progress (payoff-loop
	-- step 8, DailyChallengeLogic.State). nil = never drawn. A list from
	-- an older UTC day is redrawn the next time it's read, so nothing
	-- resets it at midnight. Written only by the progression writer (a
	-- round's progress and pay) and DailyChallengeService (the reroll).
	dailyChallenges: DailyChallengeState?,

	-- ===== schema v23, the Locker's "new" dots ============================

	-- Per Locker tab, the ids the player has already looked at
	-- (LockerSeenLogic). Anything owned and not listed dots the tab.
	-- Written by DataService.markLockerSeen when the tab is opened.
	lockerSeen: LockerSeen,

	-- ===== schema v24, the playtime starter pack ==========================

	-- Lifetime active seconds toward the one-off free power-up starter
	-- pack (GameConfig.playtimeStarterPack, PlaytimeLogic.creditStarter),
	-- and whether it has been paid. Once claimed nothing counts again.
	-- Written only by PlaytimeService and StoreService's grant.
	starterPackSeconds: number,
	starterPackClaimed: boolean,

	-- ===== schema v25, the tutorial's level-up ============================

	-- The XP the tutorial reward paid (GameConfig.tutorial.rewardLevelUp;
	-- owner, 2026-10-18), set with it in claimTutorialReward's one
	-- mutation. The Hub reveal, shown later, animates the XP bar from
	-- `xp - tutorialRewardXp` up to `xp`. 0 = none paid.
	tutorialRewardXp: number,
}

-- Structurally LockerSeenLogic.Seen.
export type LockerSeen = { Power: { string }, Style: { string }, Titles: { string } }

-- Structurally DailyChallengeLogic.State.
export type DailyChallengeState = {
	day: string,
	slots: { { id: string, progress: number, done: boolean } },
	drawn: { string },
	rerollsUsed: number,
	allDonePaid: boolean,
}

-- Structurally PlaytimeLogic.State.
export type PlaytimeState = {
	seasonId: string,
	weekStart: number,
	activeSeconds: number,
}

-- Structurally StaffGrantLogic.UnseenGift: a unique id, who gave it
-- (display name) and what it was. Never a streak (Q7 condition 1).
export type UnseenGift = {
	id: string,
	from: string,
	kind: string,
	amount: number?,
	cosmeticId: string?,
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
	passSource: ("Purchase" | "Playtime")?, -- nil = bought; "Playtime" = earned (payoff-loop step 5)
	freeWins: number,
	premiumWins: number,
	freePaid: number,
	premiumPaid: number,
}

local CURRENT_SCHEMA_VERSION = 25

local function defaultStats(): Stats
	return {
		roundsPlayed = 0,
		qualifications = 0,
		steals = 0,
		shares = 0,
		wins = 0,
		losses = 0,
		betrayed = 0,
		stealWins = 0,
	}
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
		lastHuntDay = nil,
		streakSaves = 0,
		unlimitedNavigation = false,
		unseenGifts = {},
		tutorialRewarded = false,
		tutorialRewardUnseen = false,
		tutorialGiftGiven = false,
		xp = 0,
		streakShields = 0,
		bestBanked = 0,
		streakRestoredAt = 0,
		playtime = nil,
		dailyChallenges = nil,
		lockerSeen = { Power = {}, Style = {}, Titles = {} },
		starterPackSeconds = 0,
		starterPackClaimed = false,
		tutorialRewardXp = 0,
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

-- v8 -> v9 (the daily hunt): never claimed. Nothing before this version
-- could have claimed one.
migrations[8] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 9
	next.lastHuntDay = nil
	return next
end

-- v9 -> v10 (Streak Saves): none held. Nothing earlier sold or gave one.
migrations[9] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 10
	next.streakSaves = (old.streakSaves :: number?) or 0
	return next
end

-- v10 -> v11 (staff grants): no Unlimited Navigation held. Before this
-- the only way to own it was the game pass, which is never stored.
migrations[10] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 11
	next.unlimitedNavigation = (old.unlimitedNavigation :: boolean?) or false
	return next
end

-- v11 -> v12 (staff gift pop-up): nothing waiting to be shown. Gifts
-- given under v11 already showed their pop-up on the spot.
migrations[11] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 12
	next.unseenGifts = (old.unseenGifts :: { any }?) or {}
	return next
end

-- v12 -> v13 (the first-time tutorial): not yet rewarded. Nothing
-- before this version could have paid it.
migrations[12] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 13
	next.tutorialRewarded = (old.tutorialRewarded :: boolean?) or false
	return next
end

-- v13 -> v14 (the tutorial reward reveal): nothing waiting. A reward
-- paid under v13 already showed its pop-up at the round's Results.
migrations[13] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 14
	next.tutorialRewardUnseen = (old.tutorialRewardUnseen :: boolean?) or false
	return next
end

-- v14 -> v15 (the hub tutorial's Locker gift): not yet given. Nothing
-- before this version could have given it.
migrations[14] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 15
	next.tutorialGiftGiven = (old.tutorialGiftGiven :: boolean?) or false
	return next
end

-- v15 -> v16 (XP and account level): no XP. Nothing before this version
-- earned any, so every account starts at level 1.
migrations[15] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 16
	next.xp = (old.xp :: number?) or 0
	return next
end

-- v16 -> v17 (streak shields): none held. Nothing before this version
-- could have earned one.
migrations[16] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 17
	next.streakShields = (old.streakShields :: number?) or 0
	return next
end

-- v17 -> v18 (banking a streak): nothing banked. A streak restored
-- before this version isn't known to be one, so it reads as earned: 0.
migrations[17] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 18
	next.bestBanked = (old.bestBanked :: number?) or 0
	next.streakRestoredAt = (old.streakRestoredAt :: number?) or 0
	return next
end

-- v18 -> v19 (the playtime pass): nothing counted. `playtime` is
-- optional, so this step only moves the version on.
migrations[18] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 19
	return next
end

-- v19 -> v20 (times betrayed): none. Past Studio results weren't kept,
-- so every account starts its count here.
migrations[19] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 20
	if type(old.stats) == "table" then
		local stats = table.clone(old.stats)
		stats.betrayed = (stats.betrayed :: number?) or 0
		next.stats = stats
	end
	return next
end

-- v20 -> v21 (daily challenges): none drawn. `dailyChallenges` is
-- optional and drawn on first read, so this step only moves the version.
migrations[20] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 21
	return next
end

-- v21 -> v22 (steals that won): none. Past Studio results weren't kept,
-- so every account's StealWins ladder starts at 0 (owner, 2026-10-18).
migrations[21] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 22
	if type(old.stats) == "table" then
		local stats = table.clone(old.stats)
		stats.stealWins = (stats.stealWins :: number?) or 0
		next.stats = stats
	end
	return next
end

-- v22 -> v23 (the Locker's "new" dots): everything already owned counts
-- as seen, so an existing account doesn't open to every tab dotted.
migrations[22] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 23
	local held = {}
	if type(old.powerUpStock) == "table" then
		for id, count in old.powerUpStock do
			if type(count) == "number" and count > 0 then
				table.insert(held, id)
			end
		end
		table.sort(held)
	end
	next.lockerSeen = {
		Power = held,
		Style = if type(old.ownedCosmetics) == "table" then table.clone(old.ownedCosmetics) else {},
		Titles = if type(old.unlockedTitles) == "table" then table.clone(old.unlockedTitles) else {},
	}
	return next
end

-- v23 -> v24 (the playtime starter pack): nothing counted, not paid.
-- Time played before this version doesn't count (owner, 2026-10-18).
migrations[23] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 24
	next.starterPackSeconds = 0
	next.starterPackClaimed = false
	return next
end

-- v24 -> v25 (the tutorial's level-up): none paid. A tutorial reward
-- claimed before this version paid no XP, so its reveal has no bar.
migrations[24] = function(old: { [string]: any }): { [string]: any }
	local next: { [string]: any } = table.clone(old)
	next.schemaVersion = 25
	next.tutorialRewardXp = 0
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
