--!strict
-- Types and pure boot-time validation for the game's data-driven config
-- layer (Ground Rule 2: a map, task, power-up or title is one file in a
-- sibling folder here - never a service edit). Self-contained on
-- purpose, with zero requires of sibling files and no Roblox API calls
-- anywhere - the same shape as src/shared/Net.luau, and for the same
-- reason: this is the one file under Config/ that must stay requirable
-- under Lune for headless tests (tests/Config.spec.luau), and a Roblox
-- Instance-path require (`require(ReplicatedStorage.Shared...)`) can't
-- resolve under Lune. Every other file under Config/ - GameConfig.luau,
-- Tasks/*.luau, the registries, ConfigValidator.luau - is Roblox-only and
-- requires this module the normal way.
--
-- Everything below checks DEVELOPER-authored config content at server
-- boot, not adversarial network input - unlike Net.luau's schema system,
-- these are friendly assertions against a typo in a config file, not a
-- defense against a hostile payload, so plain imperative checks are the
-- right tool here, not Net.luau's exact-shape rejection.

local Validate = {}

-- Shared by MapDef (below) and GameConfig.powerUpRotationTimers (P2-7,
-- further down) - one number per PowerUpDef.rarity value. A weight in
-- MapDef is a MULTIPLIER against GameConfig's own base respawn seconds
-- (nil/omitted = {1,1,1}, no change); the same-shaped value in GameConfig
-- IS the base respawn seconds. Two different units sharing one shape,
-- documented at each use site rather than implied by the type alone.
export type PowerUpRarityWeights = {
	Common: number,
	Uncommon: number,
	Rare: number,
}

-- ===== MapDef: docs/map-kit-spec.md §2 ==================================
-- `taskStationCount` is NOT part of the original map-kit-spec.md type -
-- added here so this validator has a declared number to cross-check
-- against GameConfig.tasksPerPlayer (see checkStationCapacity below).
-- Maps are hand-built in Studio and never synced by Rojo (CLAUDE.md), so
-- this is the map author's own DECLARED count, not something
-- introspected from real geometry - the real TaskStation tag count
-- against the live .rbxl is P7-1's job, a separate Studio validator
-- plugin this module has no access to. Kept in sync with map-kit-
-- spec.md's type block; update both together.
export type MapDef = {
	id: string,
	displayName: string,
	description: string,
	thumbnailAssetId: string,
	lightingPreset: string,
	musicTrackId: string,
	enabledTaskIds: { string },
	npcDifficultyModifier: number, -- 0.5-2.0, 1.0 = baseline
	waveNumber: number, -- 1 | 2 | 3
	enabled: boolean,
	taskStationCount: number, -- see note above
	powerUpRarityWeightMultipliers: PowerUpRarityWeights?, -- P2-7: nil = {1,1,1}, no change from GameConfig.powerUpRotationTimers' base respawn seconds - see PowerUpService.luau's own header comment for why "per-map rarity weights" lands here rather than as a map-kit-spec.md tag/attribute
}

-- ===== TaskDef: docs/tasks-catalogue.md =================================
export type TaskVerb = "Tap" | "Hold" | "Drag" | "Sequence" | "Timing" | "Aim"

local TASK_VERBS: { TaskVerb } = { "Tap", "Hold", "Drag", "Sequence", "Timing", "Aim" }

export type TaskDef = {
	id: string,
	displayName: string,
	verb: TaskVerb,
	expectedDurationSeconds: { min: number, max: number }, -- architecture.md's NPC timing sample range
	mobileFeasibility: number, -- 1-5, tasks-catalogue.md's rating
}

-- ===== PowerUpDef: docs/powerups.md ======================================
export type PowerUpKind = "Buff" | "Debuff"
export type PowerUpTarget = "Self" | "Aimed" | "Area" | "Nearest"
export type PowerUpRarity = "Common" | "Uncommon" | "Rare"

local POWERUP_KINDS: { PowerUpKind } = { "Buff", "Debuff" }
local POWERUP_TARGETS: { PowerUpTarget } = { "Self", "Aimed", "Area", "Nearest" }
local POWERUP_RARITIES: { PowerUpRarity } = { "Common", "Uncommon", "Rare" }

-- Two acquisition paths per powerups.md's intro. `robuxPrice` is only
-- ever a convenience purchase, never exclusive - design-decisions.md Q8:
-- "every purchasable item is also earnable for free through normal
-- play." checkPowerUp enforces that rule at boot rather than leaving it
-- to code review, per Q8's own downstream note ("should fail config
-- validation per Ground Rule 2, not just fail review").
export type PowerUpAcquisition = {
	fieldPickup: boolean,
	loadoutEligible: boolean,
	freelyEarnable: boolean, -- earnable via Studio wins / loyalty / event drops
	robuxPrice: number?, -- nil = not purchasable with Robux
}

export type PowerUpDef = {
	id: string,
	displayName: string,
	kind: PowerUpKind,
	target: PowerUpTarget,
	durationSeconds: number,
	cooldownSeconds: number,
	rarity: PowerUpRarity,
	hardControl: boolean, -- Freeze/Push-Trip = true; powerups.md's anti-frustration caps apply only to these
	acquisition: PowerUpAcquisition,
}

-- ===== TitleDef: gdd.md §3, architecture.md's folder skeleton ===========
-- "players unlock permanent Titles based on their highest achieved
-- rank/streak... Titles are never revoked when a streak resets" (gdd.md)
-- - a title's threshold is checked against a profile's bestStreak, never
-- its current streak (src/server/DataMigrations.luau's schema, P1-5).
-- P4-2's optional "effect flag for the top tiers": a named visual
-- treatment the nametag applies on top of the colour. A string enum
-- rather than a boolean, because "the top tiers are special" stops
-- being expressible the moment there is more than one kind of special -
-- and the client needs to know WHICH, not just THAT.
export type TitleEffect = "Glow" | "Pulse" | "Rainbow"

local TITLE_EFFECTS: { TitleEffect } = { "Glow", "Pulse", "Rainbow" }

export type TitleDef = {
	id: string,
	displayName: string,
	colorHex: string, -- "#rrggbb" - a plain string, not Color3, so this file stays Lune-pure; a client controller converts it
	minStreak: number,
	effect: TitleEffect?, -- nil for most of the ladder; only the top tiers earn one
}

-- ===== CosmeticDef: P4-6 ==================================================
-- gdd.md's cosmetics: a character skin, a trail, a victory emote, and a
-- podium decoration for the Decision Studio. One file per item (Ground
-- Rule 2) - adding a skin, trail, emote or podium flair is adding a
-- src/shared/Config/Cosmetics/<Name>.luau and nothing else.
--
-- WHY THIS IS A FLAT TYPE WITH PER-CATEGORY OPTIONAL FIELDS, same
-- reasoning as StoreGrant above: Luau doesn't narrow a union through a
-- table field cleanly, so checkCosmeticItem enforces which fields each
-- category actually requires and CosmeticService reads only the ones its
-- own branch needs.
--
-- WHY THERE IS NO `robuxPrice`/`currency` FIELD HERE, even though a
-- cosmetic is a purchasable thing: P4-5 already owns pricing entirely -
-- a cosmetic is sold by a StoreItemDef whose `grants` names this item's
-- `id` (see FounderPass.luau, VictoryEmotePass.luau). Duplicating a price
-- here would be a second source of truth for the same number, and the
-- two would eventually disagree. `rarity` stays here rather than on the
-- store entry because it's a property of the ITEM regardless of which
-- product happens to sell it (or whether one does yet), and because
-- P6-6's item grid reads it directly for rarity treatment.
--
-- `rarity` reuses PowerUpRarity rather than inventing a second tier
-- system - one ladder of "how special is this" for the whole game.
export type CosmeticCategory = "Skin" | "Trail" | "Emote" | "Podium"

local COSMETIC_CATEGORIES: { CosmeticCategory } = { "Skin", "Trail", "Emote", "Podium" }

export type CosmeticDef = {
	id: string,
	category: CosmeticCategory,
	displayName: string,
	description: string,
	rarity: PowerUpRarity,
	sortOrder: number,

	-- `enabled = false` + an asset id of 0 is the same "not built yet"
	-- stance MapDef and StoreItemDef take - a cosmetic may be written,
	-- validated and referenced by a (disabled) store grant before a
	-- single Roblox asset behind it exists.
	enabled: boolean,

	-- Category "Skin": a full outfit, so both fields are required
	-- together - half a skin swapped in is a worse bug than none.
	shirtAssetId: number?,
	pantsAssetId: number?,

	-- Category "Trail": a Trail instance's texture and tuning. Colour is
	-- a plain "#rrggbb" string, not Color3, for the same Lune-purity
	-- reason TitleDef.colorHex is - a client/service converts it.
	trailTextureAssetId: number?,
	trailColorHex: string?,
	trailLifetime: number?, -- seconds; CosmeticService clamps to a sane range

	-- Category "Emote": played on victory, never persistently worn -
	-- see CosmeticService's own note on why this category has nothing to
	-- "apply" on spawn.
	animationAssetId: number?,

	-- Category "Podium": a small decoration shown only on a finalist's
	-- podium slot during the Decision Studio (design-decisions.md's
	-- podium circle) - see CosmeticService for why it's gated on round
	-- state the same way TitleLogic.isVisibleInState gates a title.
	podiumTextureAssetId: number?,
	podiumColorHex: string?,

	-- Store UI thumbnail (P6-6's item grid). Optional: falls back to
	-- whatever the category's own primary asset id would render as.
	previewIconAssetId: number?,
}

-- ===== StoreItemDef: P4-5 ================================================
-- One file per purchasable thing, per Ground Rule 2 - adding a product
-- is adding a src/shared/Config/Store/<Name>.luau and nothing else.
--
-- WHY `key` EXISTS ALONGSIDE `assetId`: the assetId is Roblox's number,
-- and it does not exist until somebody creates the pass or product in
-- the Creator Dashboard. Every internal reference - a profile field, a
-- log line, a remote payload, a support ticket - uses `key` instead, so
-- the whole catalogue can be written, validated and tested before a
-- single asset exists, and so a product that has to be recreated (a new
-- Roblox id for the same thing) doesn't orphan anything already stored.
--
-- `assetId = 0` means "not created on the Roblox side yet." That's a
-- legal state for a DISABLED entry and an error for an enabled one -
-- exactly the stance MapDef.enabled takes against ServerStorage.Maps.
export type StoreProductKind = "GamePass" | "DeveloperProduct"
export type StoreGrantKind = "Currency" | "PowerUpStock" | "Cosmetic" | "Title"

local STORE_PRODUCT_KINDS: { StoreProductKind } = { "GamePass", "DeveloperProduct" }
local STORE_GRANT_KINDS: { StoreGrantKind } = { "Currency", "PowerUpStock", "Cosmetic", "Title" }

-- A single thing a purchase hands over. One flat type with optional
-- fields rather than a tagged union, because Luau doesn't narrow a union
-- through a table field cleanly enough to be worth the friction here -
-- checkStoreItem enforces which field each kind actually requires, and
-- StoreLogic.applyGrants reads only the field its own branch needs.
export type StoreGrant = {
	kind: StoreGrantKind,
	amount: number?, -- Currency: how much. PowerUpStock: how many.
	powerUpId: string?, -- PowerUpStock: which power-up, cross-checked against the PowerUps registry
	cosmeticId: string?, -- Cosmetic: which item, cross-checked against the Cosmetics registry (P4-6)
	titleId: string?, -- Title: which title, cross-checked against the Titles registry
}

export type StoreItemDef = {
	key: string, -- stable internal id; never Roblox's number
	kind: StoreProductKind,
	assetId: number, -- Roblox game pass / developer product id; 0 = not created yet
	enabled: boolean,
	displayName: string,
	description: string,
	robuxPrice: number, -- DISPLAY ONLY - see checkStoreItem for why a grant never reads this
	sortOrder: number,
	grants: { StoreGrant },
}

-- ===== StoreConfig: P4-5 =================================================
export type StoreConfig = {
	-- How many recent PurchaseIds a profile remembers. This bounds the
	-- receipt replay window: a purchase older than the oldest id still
	-- held would be granted a second time if Roblox ever re-offered it.
	-- ProfileStore's own devproducts example uses 100.
	purchaseIdCacheSize: number,

	-- How long a yielding ProcessReceipt waits between re-checking
	-- whether the grant has actually reached the DataStore, and how long
	-- it keeps waiting before giving up and returning NotProcessedYet
	-- (which asks Roblox to re-offer the receipt later).
	receiptSaveRetrySeconds: number,
	receiptMaxWaitSeconds: number,

	-- How long to wait for a profile that hasn't finished loading before
	-- declining the receipt. Deliberately short: declining is free and
	-- safe, because the receipt comes back. Blocking isn't.
	receiptProfileWaitSeconds: number,

	-- Game pass ownership cache. A positive answer is cached far longer
	-- than a negative one: "owns it" almost never becomes false, while
	-- "doesn't own it" becomes false the moment they buy it - and that
	-- is precisely the case a player is watching impatiently.
	passCacheOwnedTtlSeconds: number,
	passCacheUnownedTtlSeconds: number,

	-- design-decisions.md Q8, verbatim: "Loadouts are capped at 3 items
	-- regardless of spend." LOCKED, not a placeholder - raising it means
	-- amending Q8, not editing a number.
	loadoutSlots: number,
}

-- ===== TelemetryConfig: P4-7 =============================================
-- All PLACEHOLDER (see GameConfig.telemetry). `enabled` is the kill
-- switch for a broken or slow analytics sink.
export type TelemetryConfig = {
	enabled: boolean,
	batchSize: number,
	flushIntervalSeconds: number,
	perMinuteLimit: number, -- 0 = no limit
}

-- ===== MatchmakingConfig: P5-1 ===========================================
-- Cross-server queue timings and MemoryStore names. The ORDERINGS
-- between these (checked in checkMatchmakingConfig) are what keep
-- the queue live. docs/matchmaking.md explains each one. Correctness
-- (no double-booking) doesn't depend on any of these numbers.
export type MatchmakingConfig = {
	hubPlaceId: number, -- 0 = unset: matchmaking then runs only in Studio
	queueMapName: string, -- SortedMap: userId -> entry, sorted by enqueue time
	groupMapName: string, -- HashMap: groupId -> group record (the commit point)
	recentMapName: string, -- HashMap: userId -> recent opponents
	metaMapName: string, -- HashMap: the formation lease
	groupSize: number, -- must equal playerCount
	partialGroupTimeoutSeconds: number,
	partialGroupMinPlayers: number,
	formationTickSeconds: number,
	queuePageSize: number, -- GetRangeAsync count per tick
	entryTtlSeconds: number,
	refreshIntervalSeconds: number,
	claimCommitDeadlineSeconds: number, -- former gives up on its own claims past this
	staleClaimRevertSeconds: number, -- owner reverts an uncommitted claim past this
	groupRecordTtlSeconds: number,
	leaseTtlSeconds: number,
	departedTtlSeconds: number,
	rematchCooldownSeconds: number,
	recentOpponentsCap: number,
	backoffBaseSeconds: number,
	backoffCapSeconds: number,
	unavailableAfterFailures: number,
}

-- ===== TeleportConfig: P5-2 ==============================================
-- Hub-to-match travel. docs/teleport.md explains each number.
export type TeleportConfig = {
	matchPlaceId: number, -- 0 = unset: teleporting is disabled
	maxAttempts: number, -- per player, including the first
	retryBaseSeconds: number,
	retryCapSeconds: number,
	travelWatchdogSeconds: number,
	profileLoadGraceSeconds: number,
	manifestReadAttempts: number,
}

-- P5-3: the hub map vote. See docs/voting.md.
export type VoteConfig = {
	ballotSize: number,
	voteSeconds: number,
	revealSeconds: number,
	pollSeconds: number,
	lockGraceSeconds: number,
	recentMapName: string,
	recentMapsCap: number,
	recentMapsTtlSeconds: number,
	recentFloorWeight: number,
	recentDecay: number,
}

-- P5-5: the hub practice area, which runs the real power-up and status
-- effect services under EffectContext's practice flag. The first three
-- fields are EffectContext.PracticeRules.
export type PracticeConfig = {
	durationScale: number, -- 0-1 multiplier on every effect's duration
	maxEffectSeconds: number, -- ceiling on any one effect after scaling
	maxActiveEffects: number, -- per player, at once (a refresh doesn't count)
	itemSpawnRarities: { string }, -- cycled over HubPracticeItemSpawn parts, sorted by name
	respawnMultipliers: PowerUpRarityWeights, -- on GameConfig.powerUpRotationTimers
	zoneCheckSeconds: number, -- how often zone exits are noticed and effects cleared
}

-- ===== GameConfig: round/player counts, Studio timers, bounty tiers ====
-- Studio phase timers are locked exactly by architecture.md §6's network
-- trace (Intro +5s, Negotiate +45s, Choose +15s, Reveal +1s). Bounty
-- tiers are payoff-table.md §3's table verbatim (VU = the internal
-- balancing currency that doc explains is never shown to a player - see
-- its §1 for why L > M > S > 0 must hold at every tier). Fields with no
-- locked value anywhere in docs/ yet are marked PLACEHOLDER, the same
-- stance perf-budget.md and threat-model.md take on their own
-- unverified figures - not a guess presented as fact.
export type BountyTier = {
	tier: number, -- 1-5, ascending
	minStreak: number, -- payoff-table.md §3's streak-range floor for this tier
	soleStealerVU: number, -- L
	loneSharerVU: number, -- M
	allShareVU: number, -- S
}

export type StudioTimers = {
	introSeconds: number,
	negotiateSeconds: number,
	chooseSeconds: number,
	revealDelaySeconds: number,
}

-- Fixed durations for RoundService's (P2-1) own states that aren't
-- covered by `raceDurationSeconds` or `studioTimers` above. All
-- PLACEHOLDER - no locked value anywhere in docs/ yet, same stance as
-- `raceDurationSeconds`. `waitingForPlayers` and `decisionStudio` have
-- no entry here on purpose: the first ends when a matchmaking system
-- (not built yet) says the server is full, the second ends when a
-- future DecisionService's own inner phase machine resolves - neither
-- is a fixed RoundService-owned timer.
export type RoundTimers = {
	loadingSeconds: number,
	introSeconds: number, -- the top-level "Intro" round STATE (pre-race beat) - distinct from studioTimers.introSeconds, the Decision Studio's own separate inner phase
	qualifiedSeconds: number, -- brief hold/teleport buffer before Decision Studio
	resultsSeconds: number, -- reveal-hold before Cleanup
	cleanupSeconds: number, -- teardown window
}

export type GameConfig = {
	playerCount: number, -- 6, gdd.md
	qualifierCount: number, -- 3, gdd.md
	tasksPerPlayer: number, -- cross-checked against every MapDef.taskStationCount
	qualificationFloorPercent: number, -- design-decisions.md Q2: 0.5
	streakLossWeight: number, -- payoff-table.md §3's c0; Closs(n) = streakLossWeight * n
	npcSeatStreakCreditThreshold: number, -- PLACEHOLDER: threat-model.md §8, playtest-tuned
	raceDurationSeconds: number, -- PLACEHOLDER: no locked value in docs/ yet
	studioTimers: StudioTimers,
	roundTimers: RoundTimers,
	bountyTiers: { BountyTier },

	-- P2-7: the IN-ROUND field-pickup inventory PowerUpService owns - not
	-- to be confused with powerups.md's separate pre-game 3-item Loadout
	-- slot selection (a future Hub/StoreService concern, unbuilt).
	powerUpInventorySlots: number, -- default 1, powerups.md: "one inventory slot per player by default, configurable"
	powerUpFullInventoryPolicy: "Swap" | "Refuse", -- picking up while full: swap the oldest held item, or refuse the new pickup (world pickup stays available)
	powerUpUseRangeStuds: number, -- max range for an Aimed/Nearest target
	powerUpTargetConeDegrees: number, -- full cone width (not half-angle) for smart-targeting an Aimed power-up with no explicit target hint
	powerUpRotationTimers: PowerUpRarityWeights, -- base respawn seconds per rarity tier; a MapDef may multiply these (see PowerUpRarityWeights' own doc comment)

	-- P2-9: MovementWatch's thresholds - "configurable... not hard-coded"
	-- (the task's own requirement, verbatim). All PLACEHOLDER, same
	-- stance raceDurationSeconds takes - no real logged data exists yet
	-- to tune these against (see docs/movement-watch-notes.md).
	movementSampleIntervalSeconds: number, -- fixed sampling interval, not every frame
	movementSpeedTolerance: number, -- multiplier grace above the resolved max (e.g. 1.25 = 25% headroom) before a sample counts as any violation at all
	movementViolationDecayPerSecond: number, -- how fast the rolling score falls back toward 0 between violations
	movementViolationLogThreshold: number,
	movementViolationFlagThreshold: number,
	movementViolationActThreshold: number, -- unused for now - this version is LOG ONLY (the task's own requirement) - reserved for when enforcement is ever enabled

	-- P3-2: the Decision Studio's "configured default choice" - applied
	-- to any qualifier who never locks in by the Choose deadline (the
	-- task's own requirement, verbatim: "anyone who never submitted
	-- takes the configured default choice"). Locked at "Share" per
	-- design-decisions.md Q4 ("the leaver's substituted choice for the
	-- other two is Share") - this single field satisfies both a
	-- disconnected qualifier's Q4 substitution AND a still-connected but
	-- indecisive one with the same mechanism, deliberately.
	decisionStudioDefaultChoice: "Steal" | "Share",

	-- P3-3: how close two finalists' Characters must be for the Negotiate
	-- text channel to deliver between them (ShouldDeliverCallback) - also
	-- the number P3-4's podium layout has to comfortably fit inside,
	-- since it "must state the stud distance chosen and why" against
	-- this same figure. Spatial voice's own falloff is a separate,
	-- Audio-API-managed curve (AudioEmitter.DistanceAttenuation) this
	-- field does NOT control - see StudioChat.luau's own header comment.
	decisionStudioChatRangeStuds: number,

	-- P3-5: every NPC-fill tuning knob, in one block. All PLACEHOLDER
	-- except where noted - no real telemetry exists to tune against yet,
	-- same stance raceDurationSeconds takes.
	npc: NPCConfig,

	-- P4-3: the all-time leaderboard. See LeaderboardConfig below.
	leaderboard: LeaderboardConfig,

	-- P4-5: the store's own timings and caps. See StoreConfig above.
	store: StoreConfig,

	-- P5-1: the cross-server queue. See MatchmakingConfig above.
	matchmaking: MatchmakingConfig,

	-- P5-2: hub-to-match teleport. See TeleportConfig above.
	teleport: TeleportConfig,

	-- P5-3: the hub map vote. See VoteConfig above.
	vote: VoteConfig,

	-- P5-5: the hub practice area. See PracticeConfig above.
	practice: PracticeConfig,

	-- P4-7: analytics batching. See TelemetryConfig above.
	telemetry: TelemetryConfig,

	-- P4-2: whether a title may be shown while a round is live. False
	-- per design-decisions.md Q7 condition 1 - see GameConfig's own note
	-- and TitleLogic.isVisibleInState.
	titleDisplayDuringRound: boolean,
	npcTitleNoneChance: number, -- 0-1: how often a bot wears no title at all
	npcTitleTopRungsExcluded: number, -- how many of the rarest rungs a bot can never wear

	-- P3-6: every probability and timing the NPC brain uses, "exposed
	-- for tuning without code changes" (the task's own requirement).
	-- The per-personality steal probabilities are NOT here - they live
	-- on each NPCPersonalityDef, so adding a personality stays a
	-- one-file change (Ground Rule 2).
	npcBrain: NPCBrainConfig,
}

-- ===== LeaderboardConfig: P4-3 ===========================================
-- The per-server DataStore request budget, as this game's own policy.
-- NOT a statement of Roblox's actual limits - those are a formula
-- involving player count that must be verified against current
-- documentation (docs/leaderboard-scale.md), and LeaderboardService
-- consults the engine's own GetRequestBudgetForRequestType as the hard
-- gate regardless. A wrong figure here degrades policy, not correctness.
export type LeaderboardBudget = {
	perWindow: number,
	windowSeconds: number,
	-- Fraction of the budget past which READS are refused but writes
	-- still go through. A stale board is invisible; a dropped write is a
	-- player's record silently not counting.
	softCeiling: number,
}

export type LeaderboardConfig = {
	storeName: string,
	storeScope: string,
	topCount: number,
	refreshMinSeconds: number,
	refreshMaxSeconds: number,
	staleAfterSeconds: number,
	nameCacheTtlSeconds: number,
	maxWriteAttempts: number,
	backoffBaseSeconds: number,
	backoffCapSeconds: number,
	budget: LeaderboardBudget,
	-- P4-4: daily/weekly boards.
	snapshotStoreName: string,
	periodGraceSeconds: number,
	rewardTopN: number,
}

-- ===== NPCBrainConfig: P3-6 ==============================================
-- The utility AI's weights. A score is assembled as
--   base + deficit component + situation component
-- and the item is used when the total reaches `useThreshold` - so these
-- are all in the same arbitrary unit, and only their RATIOS matter. See
-- NPCBrainLogic.scoreAction for exactly where each one lands.
export type NPCUtilityWeights = {
	-- Floor score for an item that COULD legally be used right now.
	-- Below useThreshold on its own, so a bot never fires purely
	-- because it happens to be holding something.
	baseScore: number,
	-- How much "I am N tasks behind the leader" pushes toward using it.
	-- The rubber-band instinct: a bot that's losing gets less patient.
	deficitWeight: number,
	-- Offensive items only: how much a target being close (rather than
	-- at the edge of range) pushes toward firing now.
	proximityWeight: number,
	-- Self-buff items only: how much a long walk to the next station
	-- pushes toward using it now - a Sprint Boost is worth most at the
	-- start of a long leg, not at the end of a short one.
	travelWeight: number,
	-- The deficit at which deficitWeight is fully applied. Above it the
	-- component saturates rather than growing without bound.
	deficitSaturation: number,
	-- The walk length at which travelWeight is fully applied, in studs.
	travelSaturationStuds: number,
	-- Total score at which the bot commits.
	useThreshold: number,
}

export type NPCBrainConfig = {
	-- How often the brain re-scores, in Hz. Deliberately far slower than
	-- NPCService's own movement tick - a power-up decision that's a
	-- second late is invisible, and this is the cheaper knob to turn.
	decisionHz: number,
	utility: NPCUtilityWeights,

	-- Decision Studio timings, all as FRACTIONS of the phase window
	-- rather than absolute seconds, so retuning studioTimers doesn't
	-- silently push a bot's lock-in outside the Choose phase.
	lockInEarliestFraction: number, -- never locks before this much of Choose has passed
	lockInLatestFraction: number, -- always locked by this much (< 1, so never at the buzzer)
	-- How many lines a bot posts across the whole Negotiate window, and
	-- the minimum gap between two of them so a bot never spams.
	negotiationLineCount: number,
	minSecondsBetweenLines: number,
	-- Probability that a bot posts a final wobble line during Choose,
	-- after Negotiate has ended - the "last-second wobble" beat.
	chooseWobbleChance: number,
}

-- ===== NPCConfig: architecture.md §4 =====================================
-- One profile an NPC can draw. `durationScale` > 1 means it works
-- SLOWER than the task's catalogue range (a weaker bot), < 1 faster -
-- though never fast enough to break the fairness floor below, which is
-- checked here at boot rather than left to the service to remember.
export type NPCSkillProfile = {
	id: string,
	weight: number, -- relative draw weight; the list need not sum to 1
	durationScale: number,
	moveSpeedScale: number,
}

export type NPCConfig = {
	-- architecture.md §4's "~10s grace window so slow teleports aren't
	-- replaced by bots."
	fillGraceSeconds: number,
	-- architecture.md §4: "AI tick at 5-10 Hz - never on Heartbeat."
	-- Validated into that range, because the whole per-server cost
	-- analysis in docs/npc-notes.md is derived from it.
	tickHz: number,
	skillProfiles: { NPCSkillProfile },
	-- Multiple of the median human time an NPC may never finish faster
	-- than. 1.0 = architecture.md's rule verbatim ("an NPC never
	-- finishes faster than the median human time for that task"); above
	-- 1.0 makes bots strictly slower still. Below 1.0 would let a bot
	-- beat the median, so it fails validation.
	fairnessFloorScale: number,
	-- How many human completions of a task are needed before its
	-- observed median replaces the catalogue-range fallback.
	medianSampleMinimum: number,
	-- How close the rig must get to a station part to count as arrived.
	stationArrivalRadiusStuds: number,
	-- How many of the nearest unfinished stations an NPC picks its next
	-- target from (architecture.md §4's "nearest unfinished, with
	-- randomness"). 1 = always the nearest, and every bot moves in
	-- lockstep.
	nextStationTopK: number,
	-- Blocked-path handling: how long a rig may make no progress before
	-- the path is recomputed, and how many recomputes it gets for one
	-- station before it gives up and teleports to the station instead of
	-- stalling the round forever.
	repathAfterStuckSeconds: number,
	maxRepathsPerStation: number,
}

-- ===== NPCPersonalityDef: architecture.md §4 =============================
-- One personality an NPC can be assigned for the Decision Studio (P3-6).
-- The four line categories are not decoration: NPCBrain escalates
-- through them as the negotiation window runs down (promises early,
-- pressure and accusations in the middle, wobbles at the end), so a
-- personality that dropped a category would simply go quiet during that
-- stretch. checkNPCPersonality enforces all four are populated.
export type NPCPersonalityLines = {
	promises: { string },
	pressure: { string },
	accusations: { string },
	wobbles: { string },
}

export type NPCPersonalityDef = {
	id: string,
	displayName: string,
	stealProbability: number, -- 0-1; architecture.md §4's Greedy 0.7 / Loyal 0.2 / Chaotic 0.5
	weight: number, -- relative draw weight when assigning one to a bot
	lines: NPCPersonalityLines,
}

-- ===== Issues ============================================================

export type Issue = {
	category: string, -- "Map" | "Task" | "PowerUp" | "Title" | "GameConfig"
	fileName: string,
	field: string,
	message: string,
}

local function issue(issues: { Issue }, category: string, fileName: string, field: string, message: string)
	table.insert(issues, { category = category, fileName = fileName, field = field, message = message })
end

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and #(value :: string) > 0
end

local function inSet<T>(value: T, set: { T }): boolean
	return table.find(set, value) ~= nil
end

-- ===== per-item checks ===================================================

function Validate.checkMap(fileName: string, def: MapDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "Map", fileName, "id", "id must be a non-empty string")
	end
	if not isNonEmptyString(def.displayName) then
		issue(issues, "Map", fileName, "displayName", "displayName must be a non-empty string")
	end
	if not isNonEmptyString(def.thumbnailAssetId) then
		issue(issues, "Map", fileName, "thumbnailAssetId", "thumbnailAssetId must be a non-empty string")
	end
	if #def.enabledTaskIds == 0 then
		issue(issues, "Map", fileName, "enabledTaskIds", "a map must enable at least one task id")
	end
	if def.npcDifficultyModifier < 0.5 or def.npcDifficultyModifier > 2.0 then
		issue(
			issues,
			"Map",
			fileName,
			"npcDifficultyModifier",
			string.format("expected 0.5-2.0, got %s", tostring(def.npcDifficultyModifier))
		)
	end
	if def.waveNumber ~= 1 and def.waveNumber ~= 2 and def.waveNumber ~= 3 then
		issue(
			issues,
			"Map",
			fileName,
			"waveNumber",
			string.format("expected 1, 2 or 3, got %s", tostring(def.waveNumber))
		)
	end
	if def.taskStationCount < 12 or def.taskStationCount > 24 then
		issue(
			issues,
			"Map",
			fileName,
			"taskStationCount",
			string.format("expected 12-24 per map-kit-spec.md §1, got %s", tostring(def.taskStationCount))
		)
	end

	if def.powerUpRarityWeightMultipliers ~= nil then
		local weights = def.powerUpRarityWeightMultipliers
		for _, rarity in { "Common", "Uncommon", "Rare" } do
			local multiplier = (weights :: any)[rarity]
			if type(multiplier) ~= "number" or multiplier <= 0 then
				issue(
					issues,
					"Map",
					fileName,
					"powerUpRarityWeightMultipliers." .. rarity,
					string.format("must be a positive number, got %s", tostring(multiplier))
				)
			end
		end
	end
end

function Validate.checkTask(fileName: string, def: TaskDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "Task", fileName, "id", "id must be a non-empty string")
	end
	if not isNonEmptyString(def.displayName) then
		issue(issues, "Task", fileName, "displayName", "displayName must be a non-empty string")
	end
	if not inSet(def.verb, TASK_VERBS) then
		issue(
			issues,
			"Task",
			fileName,
			"verb",
			string.format("expected one of [%s], got %s", table.concat(TASK_VERBS, ", "), tostring(def.verb))
		)
	end
	local range = def.expectedDurationSeconds
	if range.min <= 0 or range.max <= 0 then
		issue(issues, "Task", fileName, "expectedDurationSeconds", "min and max must both be positive")
	elseif range.min > range.max then
		issue(
			issues,
			"Task",
			fileName,
			"expectedDurationSeconds",
			string.format("min (%s) must be <= max (%s)", tostring(range.min), tostring(range.max))
		)
	end
	if def.mobileFeasibility < 1 or def.mobileFeasibility > 5 then
		issue(
			issues,
			"Task",
			fileName,
			"mobileFeasibility",
			string.format("expected 1-5, got %s", tostring(def.mobileFeasibility))
		)
	end
end

function Validate.checkPowerUp(fileName: string, def: PowerUpDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "PowerUp", fileName, "id", "id must be a non-empty string")
	end
	if not inSet(def.kind, POWERUP_KINDS) then
		issue(issues, "PowerUp", fileName, "kind", string.format("expected Buff or Debuff, got %s", tostring(def.kind)))
	end
	if not inSet(def.target, POWERUP_TARGETS) then
		issue(
			issues,
			"PowerUp",
			fileName,
			"target",
			string.format("expected one of [%s], got %s", table.concat(POWERUP_TARGETS, ", "), tostring(def.target))
		)
	end
	if not inSet(def.rarity, POWERUP_RARITIES) then
		issue(
			issues,
			"PowerUp",
			fileName,
			"rarity",
			string.format("expected one of [%s], got %s", table.concat(POWERUP_RARITIES, ", "), tostring(def.rarity))
		)
	end
	if def.durationSeconds <= 0 then
		issue(issues, "PowerUp", fileName, "durationSeconds", "must be positive")
	end
	if def.cooldownSeconds <= 0 then
		issue(issues, "PowerUp", fileName, "cooldownSeconds", "must be positive")
	end

	-- design-decisions.md Q8: a Robux price is only ever a convenience
	-- purchase. A power-up with no free acquisition path fails boot,
	-- rather than shipping a pay-to-win item past review.
	local acquisition = def.acquisition
	if acquisition.robuxPrice ~= nil and acquisition.robuxPrice > 0 then
		local hasFreePath = acquisition.fieldPickup or acquisition.freelyEarnable
		if not hasFreePath then
			issue(
				issues,
				"PowerUp",
				fileName,
				"acquisition",
				"has a robuxPrice but no free acquisition path (fieldPickup or freelyEarnable) - design-decisions.md Q8 forbids Robux-exclusive power-ups"
			)
		end
	end
end

function Validate.checkTitle(fileName: string, def: TitleDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "Title", fileName, "id", "id must be a non-empty string")
	end
	if not isNonEmptyString(def.colorHex) or not string.match(def.colorHex, "^#%x%x%x%x%x%x$") then
		issue(
			issues,
			"Title",
			fileName,
			"colorHex",
			string.format('expected "#rrggbb", got %s', tostring(def.colorHex))
		)
	end
	if def.minStreak < 0 or def.minStreak % 1 ~= 0 then
		issue(
			issues,
			"Title",
			fileName,
			"minStreak",
			string.format("expected a non-negative integer, got %s", tostring(def.minStreak))
		)
	end
	if not isNonEmptyString(def.displayName) then
		issue(issues, "Title", fileName, "displayName", "displayName must be a non-empty string")
	end
	if def.effect ~= nil and table.find(TITLE_EFFECTS, def.effect) == nil then
		issue(
			issues,
			"Title",
			fileName,
			"effect",
			string.format("expected one of %s, got %s", table.concat(TITLE_EFFECTS, "/"), tostring(def.effect))
		)
	end
end

-- P4-6. Per-item cosmetic checks. The cross-registry half (a Store
-- Cosmetic grant naming an id that exists here, and is enabled) lives in
-- Validate.run below, the same split checkStoreItem/Validate.run already
-- use for PowerUpStock and Title grants.
local function checkAssetId(issues: { Issue }, fileName: string, field: string, value: any, enabled: boolean)
	if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
		issue(
			issues,
			"Cosmetic",
			fileName,
			field,
			string.format("expected a non-negative integer, got %s", tostring(value))
		)
	elseif enabled and value == 0 then
		issue(
			issues,
			"Cosmetic",
			fileName,
			field,
			"enabled = true but this asset id is 0 - upload the asset and paste its id here, or set enabled = false"
		)
	end
end

function Validate.checkCosmeticItem(fileName: string, def: CosmeticDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "Cosmetic", fileName, "id", "id must be a non-empty string")
	end
	if not inSet(def.category, COSMETIC_CATEGORIES) then
		issue(
			issues,
			"Cosmetic",
			fileName,
			"category",
			string.format("expected one of %s, got %s", table.concat(COSMETIC_CATEGORIES, "/"), tostring(def.category))
		)
		return -- nothing below is checkable without knowing which fields apply
	end
	if not isNonEmptyString(def.displayName) then
		issue(issues, "Cosmetic", fileName, "displayName", "displayName must be a non-empty string")
	end
	if not isNonEmptyString(def.description) then
		issue(issues, "Cosmetic", fileName, "description", "description must be a non-empty string")
	end
	if not inSet(def.rarity, POWERUP_RARITIES) then
		issue(
			issues,
			"Cosmetic",
			fileName,
			"rarity",
			string.format("expected one of [%s], got %s", table.concat(POWERUP_RARITIES, ", "), tostring(def.rarity))
		)
	end

	if def.category == "Skin" then
		checkAssetId(issues, fileName, "shirtAssetId", def.shirtAssetId, def.enabled)
		checkAssetId(issues, fileName, "pantsAssetId", def.pantsAssetId, def.enabled)
	elseif def.category == "Trail" then
		checkAssetId(issues, fileName, "trailTextureAssetId", def.trailTextureAssetId, def.enabled)
		if not isNonEmptyString(def.trailColorHex) or not string.match(def.trailColorHex :: any, "^#%x%x%x%x%x%x$") then
			issue(
				issues,
				"Cosmetic",
				fileName,
				"trailColorHex",
				string.format('expected "#rrggbb", got %s', tostring(def.trailColorHex))
			)
		end
		if def.trailLifetime == nil or def.trailLifetime <= 0 then
			issue(issues, "Cosmetic", fileName, "trailLifetime", "must be a positive number of seconds")
		end
	elseif def.category == "Emote" then
		checkAssetId(issues, fileName, "animationAssetId", def.animationAssetId, def.enabled)
	elseif def.category == "Podium" then
		checkAssetId(issues, fileName, "podiumTextureAssetId", def.podiumTextureAssetId, def.enabled)
		if
			not isNonEmptyString(def.podiumColorHex) or not string.match(def.podiumColorHex :: any, "^#%x%x%x%x%x%x$")
		then
			issue(
				issues,
				"Cosmetic",
				fileName,
				"podiumColorHex",
				string.format('expected "#rrggbb", got %s', tostring(def.podiumColorHex))
			)
		end
	end
end

-- P4-5. Per-item store checks. The cross-registry half (a PowerUpStock
-- grant naming a power-up that exists, is loadout-eligible, and has a
-- free acquisition path per design-decisions.md Q8) needs the whole
-- PowerUps registry, so it lives in Validate.run below rather than here.
--
-- WHY `robuxPrice` IS NEVER TRUSTED FOR A GRANT, only displayed: the
-- real price lives on the Roblox product listing, and this field is a
-- copy of it for a store UI to render without a GetProductInfoAsync
-- round-trip per tile. If the two ever disagree, Roblox's is the one
-- that charged the player. Nothing in StoreService reads this to decide
-- what to hand over - a grant is driven entirely by `grants` below,
-- which is why a stale price here is a cosmetic bug and not a
-- give-away-the-shop bug.
function Validate.checkStoreItem(fileName: string, def: StoreItemDef, issues: { Issue })
	if not isNonEmptyString(def.key) then
		issue(issues, "Store", fileName, "key", "key must be a non-empty string")
	end
	if not isNonEmptyString(def.displayName) then
		issue(issues, "Store", fileName, "displayName", "displayName must be a non-empty string")
	end
	if not isNonEmptyString(def.description) then
		issue(
			issues,
			"Store",
			fileName,
			"description",
			"description must be a non-empty string - the store UI has nowhere else to get one"
		)
	end
	if not inSet(def.kind, STORE_PRODUCT_KINDS) then
		issue(
			issues,
			"Store",
			fileName,
			"kind",
			string.format("expected one of %s, got %s", table.concat(STORE_PRODUCT_KINDS, "/"), tostring(def.kind))
		)
	end

	if type(def.assetId) ~= "number" or def.assetId < 0 or def.assetId % 1 ~= 0 then
		issue(
			issues,
			"Store",
			fileName,
			"assetId",
			string.format("expected a non-negative integer, got %s", tostring(def.assetId))
		)
	elseif def.enabled and def.assetId == 0 then
		-- The MapDef.enabled stance, applied to monetisation: an entry
		-- may be written and validated before its Roblox asset exists,
		-- but it may not be SOLD before then. An enabled product with no
		-- id would prompt a purchase for asset 0 and fail in front of a
		-- player holding their Robux.
		issue(
			issues,
			"Store",
			fileName,
			"assetId",
			"enabled = true but assetId is 0 - create the pass/product in the Creator Dashboard and paste its id here, or set enabled = false"
		)
	end

	if type(def.robuxPrice) ~= "number" or def.robuxPrice < 0 or def.robuxPrice % 1 ~= 0 then
		issue(
			issues,
			"Store",
			fileName,
			"robuxPrice",
			string.format("expected a non-negative integer, got %s", tostring(def.robuxPrice))
		)
	end

	if type(def.grants) ~= "table" or #def.grants == 0 then
		issue(issues, "Store", fileName, "grants", "a product must grant at least one thing")
		return
	end

	for index, grant in def.grants do
		local field = string.format("grants[%d]", index)

		if not inSet(grant.kind, STORE_GRANT_KINDS) then
			issue(
				issues,
				"Store",
				fileName,
				field,
				string.format("expected one of %s, got %s", table.concat(STORE_GRANT_KINDS, "/"), tostring(grant.kind))
			)
			continue
		end

		-- P4-5 frames game passes as PERMANENT cosmetics and developer
		-- products as consumables, and the split is enforced rather than
		-- assumed. A pass that grants a consumable is one of two bugs
		-- and there is no way to tell which from the config: either a
		-- one-shot purchase the player can never repeat, or - if its
		-- grants are re-applied on every join the way a pass's
		-- permanent unlocks must be - an infinite free tap on currency
		-- or power-up stock. Refusing the shape closes both.
		if def.kind == "GamePass" and (grant.kind == "Currency" or grant.kind == "PowerUpStock") then
			issue(
				issues,
				"Store",
				fileName,
				field,
				string.format(
					"a GamePass cannot grant %s - a pass is permanent and its grants re-apply on every join, so a consumable grant here is either a one-shot purchase or an infinite tap. Sell consumables as a DeveloperProduct.",
					grant.kind
				)
			)
		end

		if grant.kind == "Currency" then
			if type(grant.amount) ~= "number" or (grant.amount :: number) <= 0 or (grant.amount :: number) % 1 ~= 0 then
				issue(issues, "Store", fileName, field, "a Currency grant needs a positive integer `amount`")
			end
		elseif grant.kind == "PowerUpStock" then
			if not isNonEmptyString(grant.powerUpId) then
				issue(issues, "Store", fileName, field, "a PowerUpStock grant needs a `powerUpId`")
			end
			if type(grant.amount) ~= "number" or (grant.amount :: number) <= 0 or (grant.amount :: number) % 1 ~= 0 then
				issue(issues, "Store", fileName, field, "a PowerUpStock grant needs a positive integer `amount`")
			end
		elseif grant.kind == "Cosmetic" then
			if not isNonEmptyString(grant.cosmeticId) then
				issue(issues, "Store", fileName, field, "a Cosmetic grant needs a `cosmeticId`")
			end
		elseif grant.kind == "Title" then
			if not isNonEmptyString(grant.titleId) then
				issue(issues, "Store", fileName, field, "a Title grant needs a `titleId`")
			end
		end
	end
end

-- P3-5. Split out of checkGameConfig purely for length - it's called
-- from there, not separately, so a new NPC knob can't be added without
-- passing through this.
--
-- Note on what is deliberately NOT checked here: that a profile's
-- durationScale sits above fairnessFloorScale. It's tempting (a bot
-- that's always floored is a profile that means nothing), but it isn't
-- decidable at boot - whether a given draw is floored depends on where
-- in that task's expected range the sample landed and on the observed
-- human median at the time, neither of which exists yet. A profile
-- below the floor scale is floored on its FASTER draws only, which is
-- exactly what a rubber band is supposed to do. The runtime signal for
-- "this profile never means anything" is NPCLogic.sampleWorkSeconds'
-- own `flooredBy` return, which NPCService logs - see docs/npc-notes.md.
local function checkNPCConfig(npc: NPCConfig, issues: { Issue })
	-- A whole missing block is a config file that predates P3-5 rather
	-- than a bad value, and it reads far better as one named issue than
	-- as "attempt to index nil" from the first field below.
	if npc == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "npc", "the NPC config block is missing entirely")
		return
	end

	if npc.fillGraceSeconds < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npc.fillGraceSeconds", "must not be negative")
	end
	if npc.tickHz < 5 or npc.tickHz > 10 then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"npc.tickHz",
			string.format("architecture.md §4 requires 5-10 Hz, got %s", tostring(npc.tickHz))
		)
	end
	if npc.fairnessFloorScale < 1 then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"npc.fairnessFloorScale",
			string.format(
				"must be >= 1 - below 1 lets an NPC finish faster than the median human, which architecture.md §4 forbids (got %s)",
				tostring(npc.fairnessFloorScale)
			)
		)
	end
	if npc.medianSampleMinimum < 1 then
		issue(issues, "GameConfig", "GameConfig.luau", "npc.medianSampleMinimum", "must be at least 1")
	end
	if npc.stationArrivalRadiusStuds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npc.stationArrivalRadiusStuds", "must be positive")
	end
	if npc.nextStationTopK < 1 then
		issue(issues, "GameConfig", "GameConfig.luau", "npc.nextStationTopK", "must be at least 1")
	end
	if npc.repathAfterStuckSeconds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npc.repathAfterStuckSeconds", "must be positive")
	end
	if npc.maxRepathsPerStation < 1 then
		issue(issues, "GameConfig", "GameConfig.luau", "npc.maxRepathsPerStation", "must be at least 1")
	end

	if #npc.skillProfiles == 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npc.skillProfiles", "must declare at least one profile")
		return
	end

	local totalWeight = 0
	local seenIds: { [string]: boolean } = {}
	for index, profile in npc.skillProfiles do
		local field = string.format("npc.skillProfiles[%d]", index)
		if profile.id == "" then
			issue(issues, "GameConfig", "GameConfig.luau", field .. ".id", "must not be empty")
		elseif seenIds[profile.id] then
			issue(issues, "GameConfig", "GameConfig.luau", field .. ".id", "duplicate profile id " .. profile.id)
		end
		seenIds[profile.id] = true

		if profile.weight <= 0 then
			issue(issues, "GameConfig", "GameConfig.luau", field .. ".weight", "must be positive")
		end
		totalWeight += profile.weight

		if profile.durationScale <= 0 then
			issue(issues, "GameConfig", "GameConfig.luau", field .. ".durationScale", "must be positive")
		end
		if profile.moveSpeedScale <= 0 then
			issue(issues, "GameConfig", "GameConfig.luau", field .. ".moveSpeedScale", "must be positive")
		end
	end

	if totalWeight <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npc.skillProfiles", "weights must sum to more than zero")
	end
end

-- P3-6. Same split-for-length reasoning as checkNPCConfig above.
--
-- The one rule here that's a real invariant rather than a range check:
-- lockInEarliestFraction < lockInLatestFraction < 1. The upper bound
-- matters because a bot that locks in at fraction 1.0 is racing the
-- phase deadline, and whichever of the two fires first decides whether
-- its choice or the configured default is what counts - a coin flip
-- between two different outcomes, decided by scheduler ordering.
local function checkNPCBrainConfig(npcBrain: NPCBrainConfig, issues: { Issue })
	if npcBrain == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "npcBrain", "the NPC brain config block is missing entirely")
		return
	end

	if npcBrain.decisionHz <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npcBrain.decisionHz", "must be positive")
	end

	if
		not (npcBrain.lockInEarliestFraction >= 0 and npcBrain.lockInEarliestFraction < npcBrain.lockInLatestFraction)
	then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"npcBrain.lockInEarliestFraction",
			string.format(
				"must be >= 0 and below lockInLatestFraction (%s), got %s",
				tostring(npcBrain.lockInLatestFraction),
				tostring(npcBrain.lockInEarliestFraction)
			)
		)
	end
	if npcBrain.lockInLatestFraction >= 1 then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"npcBrain.lockInLatestFraction",
			string.format(
				"must be below 1 - locking at the deadline itself races the phase timer for whether the bot's own choice or the default counts (got %s)",
				tostring(npcBrain.lockInLatestFraction)
			)
		)
	end

	if npcBrain.negotiationLineCount < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npcBrain.negotiationLineCount", "must not be negative")
	end
	if npcBrain.minSecondsBetweenLines < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npcBrain.minSecondsBetweenLines", "must not be negative")
	end
	if npcBrain.chooseWobbleChance < 0 or npcBrain.chooseWobbleChance > 1 then
		issue(issues, "GameConfig", "GameConfig.luau", "npcBrain.chooseWobbleChance", "must be between 0 and 1")
	end

	local utility = npcBrain.utility
	if utility == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "npcBrain.utility", "the utility weight block is missing")
		return
	end

	if utility.useThreshold <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npcBrain.utility.useThreshold", "must be positive")
	end
	if utility.baseScore >= utility.useThreshold then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"npcBrain.utility.baseScore",
			string.format(
				"must be below useThreshold (%s) - at or above it, a bot fires the instant it can legally do so and the situation weights mean nothing",
				tostring(utility.useThreshold)
			)
		)
	end
	if utility.deficitSaturation <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npcBrain.utility.deficitSaturation", "must be positive")
	end
	if utility.travelSaturationStuds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npcBrain.utility.travelSaturationStuds", "must be positive")
	end
	for _, field in { "deficitWeight", "proximityWeight", "travelWeight" } do
		local value = (utility :: any)[field] :: number
		if type(value) ~= "number" or value < 0 then
			issue(issues, "GameConfig", "GameConfig.luau", "npcBrain.utility." .. field, "must not be negative")
		end
	end
end

-- P3-6. The four line categories are all required and all non-empty -
-- NPCBrain picks a category by how far through the negotiation window
-- it is, so an empty one is a stretch of silence, not a smaller pool.
function Validate.checkNPCPersonality(fileName: string, def: NPCPersonalityDef, issues: { Issue })
	if def.id == "" then
		issue(issues, "NPCPersonality", fileName, "id", "must not be empty")
	end
	if def.displayName == "" then
		issue(issues, "NPCPersonality", fileName, "displayName", "must not be empty")
	end
	if def.stealProbability < 0 or def.stealProbability > 1 then
		issue(
			issues,
			"NPCPersonality",
			fileName,
			"stealProbability",
			string.format("expected 0-1, got %s", tostring(def.stealProbability))
		)
	end
	if def.weight <= 0 then
		issue(issues, "NPCPersonality", fileName, "weight", "must be positive")
	end

	local lines = def.lines
	if lines == nil then
		issue(issues, "NPCPersonality", fileName, "lines", "must declare a lines block")
		return
	end

	for _, category in { "promises", "pressure", "accusations", "wobbles" } do
		local pool = (lines :: any)[category] :: { string }?
		if pool == nil or #pool == 0 then
			issue(
				issues,
				"NPCPersonality",
				fileName,
				"lines." .. category,
				"must declare at least one line - an empty category is a silent stretch of the negotiation, not a smaller pool"
			)
			continue
		end

		for index, line in pool do
			if line == "" then
				issue(
					issues,
					"NPCPersonality",
					fileName,
					string.format("lines.%s[%d]", category, index),
					"must not be empty"
				)
			end
		end
	end
end

-- P4-3. Same split-for-length reasoning as the NPC blocks above.
local function checkLeaderboardConfig(leaderboard: LeaderboardConfig, issues: { Issue })
	if leaderboard == nil then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"leaderboard",
			"the leaderboard config block is missing entirely"
		)
		return
	end

	if not isNonEmptyString(leaderboard.storeName) then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.storeName", "must be a non-empty string")
	end
	if leaderboard.topCount <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.topCount", "must be positive")
	end

	-- The refresh band is P4-3's own "60 to 120 seconds" requirement.
	-- Checked as an ORDER rather than against those exact numbers, so
	-- retuning stays possible, but an inverted band would silently make
	-- every interval the same value and undo the anti-synchronisation
	-- the jitter exists for.
	if leaderboard.refreshMinSeconds <= 0 or leaderboard.refreshMaxSeconds < leaderboard.refreshMinSeconds then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"leaderboard.refreshMinSeconds",
			string.format(
				"must be positive and no greater than refreshMaxSeconds (%s)",
				tostring(leaderboard.refreshMaxSeconds)
			)
		)
	end

	-- Staleness must outlast a normal refresh cycle, or a board that
	-- simply hasn't ticked yet gets labelled stale and the indicator
	-- cries wolf until players stop reading it.
	if leaderboard.staleAfterSeconds <= leaderboard.refreshMaxSeconds then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"leaderboard.staleAfterSeconds",
			string.format(
				"must exceed refreshMaxSeconds (%s) - one skipped cycle is normal and must not read as stale",
				tostring(leaderboard.refreshMaxSeconds)
			)
		)
	end

	if leaderboard.nameCacheTtlSeconds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.nameCacheTtlSeconds", "must be positive")
	end
	if leaderboard.maxWriteAttempts < 1 then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.maxWriteAttempts", "must be at least 1")
	end
	if leaderboard.backoffBaseSeconds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.backoffBaseSeconds", "must be positive")
	end
	if leaderboard.backoffCapSeconds < leaderboard.backoffBaseSeconds then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"leaderboard.backoffCapSeconds",
			"must not be below backoffBaseSeconds"
		)
	end

	if not isNonEmptyString(leaderboard.snapshotStoreName) then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.snapshotStoreName", "must be a non-empty string")
	end
	if leaderboard.periodGraceSeconds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.periodGraceSeconds", "must be positive")
	end
	if leaderboard.rewardTopN < 1 then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.rewardTopN", "must be at least 1")
	end

	local budget = leaderboard.budget
	if budget == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.budget", "the budget block is missing")
		return
	end
	if budget.perWindow <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.budget.perWindow", "must be positive")
	end
	if budget.windowSeconds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.budget.windowSeconds", "must be positive")
	end
	if budget.softCeiling <= 0 or budget.softCeiling > 1 then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"leaderboard.budget.softCeiling",
			"must be above 0 and at most 1 - it is the fraction of the budget past which reads yield to writes"
		)
	end
end

-- P4-5. Same split as checkLeaderboardConfig above, for the same reason
-- (length) - called from checkGameConfig, never separately.
local function checkStoreConfig(store: StoreConfig, issues: { Issue })
	if store == nil then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"store",
			"the whole `store` block is missing - a config file predating P4-5"
		)
		return
	end

	local positiveFields: { [string]: number } = {
		purchaseIdCacheSize = store.purchaseIdCacheSize,
		receiptSaveRetrySeconds = store.receiptSaveRetrySeconds,
		receiptMaxWaitSeconds = store.receiptMaxWaitSeconds,
		receiptProfileWaitSeconds = store.receiptProfileWaitSeconds,
		passCacheOwnedTtlSeconds = store.passCacheOwnedTtlSeconds,
		passCacheUnownedTtlSeconds = store.passCacheUnownedTtlSeconds,
		loadoutSlots = store.loadoutSlots,
	}
	for field, value in positiveFields do
		if type(value) ~= "number" or value <= 0 then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				"store." .. field,
				string.format("must be a positive number, got %s", tostring(value))
			)
		end
	end

	-- A cache of 1 would "remember" only the most recent purchase, so
	-- two purchases in quick succession could each look new to the
	-- other's arrival order. The real floor is judgement, but a cache
	-- that can't hold a handful of receipts isn't protecting anything.
	if store.purchaseIdCacheSize < 10 then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"store.purchaseIdCacheSize",
			"must be at least 10 - this is the replay window, and a purchase that falls out of it would be granted twice"
		)
	end

	if store.receiptMaxWaitSeconds <= store.receiptSaveRetrySeconds then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"store.receiptMaxWaitSeconds",
			"must exceed store.receiptSaveRetrySeconds, or the receipt handler gives up before its first retry"
		)
	end

	-- design-decisions.md Q8: "Loadouts are capped at 3 items regardless
	-- of spend." Enforced at boot, not left to review, for the same
	-- reason checkPowerUp enforces Q8's free-path rule - a monetisation
	-- decision that only lives in a document is one a later edit can
	-- quietly undo.
	if store.loadoutSlots ~= 3 then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"store.loadoutSlots",
			string.format(
				"design-decisions.md Q8 caps the loadout at 3 items regardless of spend, got %s - changing this means amending Q8, not editing a number",
				tostring(store.loadoutSlots)
			)
		)
	end

	if store.passCacheUnownedTtlSeconds > store.passCacheOwnedTtlSeconds then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"store.passCacheUnownedTtlSeconds",
			"must not exceed store.passCacheOwnedTtlSeconds - a player who just bought a pass is the one waiting on this cache, so the negative answer is the one that has to expire sooner"
		)
	end
end

-- P5-1. Every ordering here protects LIVENESS, not the no-double-booking
-- guarantee (that rests on per-key compare-and-set alone - see
-- MatchmakingLogic.luau's header). Getting one wrong strands players or
-- splits groups needlessly, which is why they fail at boot.
local MEMORYSTORE_MAX_EXPIRATION_SECONDS = 3888000 -- 45 days; verify, see docs/matchmaking.md
local MEMORYSTORE_MAX_RANGE_COUNT = 200 -- GetRangeAsync; verify, see docs/matchmaking.md

local function checkMatchmakingConfig(mm: MatchmakingConfig, playerCount: number, issues: { Issue })
	local function bad(field: string, message: string)
		issue(issues, "GameConfig", "GameConfig.luau", "matchmaking." .. field, message)
	end

	if mm == nil then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"matchmaking",
			"the matchmaking config block is missing entirely"
		)
		return
	end

	for _, field in { "queueMapName", "groupMapName", "recentMapName", "metaMapName" } do
		if not isNonEmptyString((mm :: any)[field]) then
			bad(field, "must be a non-empty string")
		end
	end
	if type(mm.hubPlaceId) ~= "number" or mm.hubPlaceId < 0 then
		bad("hubPlaceId", "must be a place id, or 0 for unset")
	end

	if mm.groupSize ~= playerCount then
		bad("groupSize", string.format("must equal playerCount (%d) - a group is one match", playerCount))
	end
	if mm.partialGroupMinPlayers < 1 or mm.partialGroupMinPlayers > mm.groupSize then
		bad("partialGroupMinPlayers", "must be between 1 and groupSize")
	end
	if mm.queuePageSize < mm.groupSize or mm.queuePageSize > MEMORYSTORE_MAX_RANGE_COUNT then
		bad(
			"queuePageSize",
			string.format("must be between groupSize and %d (GetRangeAsync's cap)", MEMORYSTORE_MAX_RANGE_COUNT)
		)
	end

	for _, field in
		{
			"partialGroupTimeoutSeconds",
			"formationTickSeconds",
			"entryTtlSeconds",
			"refreshIntervalSeconds",
			"claimCommitDeadlineSeconds",
			"staleClaimRevertSeconds",
			"groupRecordTtlSeconds",
			"leaseTtlSeconds",
			"departedTtlSeconds",
			"rematchCooldownSeconds",
			"backoffBaseSeconds",
			"backoffCapSeconds",
		}
	do
		local value = (mm :: any)[field]
		if type(value) ~= "number" or value <= 0 or value > MEMORYSTORE_MAX_EXPIRATION_SECONDS then
			bad(field, "must be positive and within MemoryStore's maximum expiration")
		end
	end

	-- Two missed heartbeats in a row must not be enough to expire a
	-- live player's entry.
	if mm.refreshIntervalSeconds * 2 >= mm.entryTtlSeconds then
		bad(
			"refreshIntervalSeconds",
			"must be under half of entryTtlSeconds, so one missed refresh can't drop a live entry"
		)
	end
	-- The owner must not revert a claim the former could still commit.
	if mm.claimCommitDeadlineSeconds >= mm.staleClaimRevertSeconds then
		bad(
			"claimCommitDeadlineSeconds",
			"must be shorter than staleClaimRevertSeconds, or owners revert claims whose groups are about to commit"
		)
	end
	-- An owner that is slow to look must still find the group record.
	if mm.groupRecordTtlSeconds <= mm.staleClaimRevertSeconds then
		bad("groupRecordTtlSeconds", "must outlive staleClaimRevertSeconds, or a committed group can look uncommitted")
	end
	-- A lease that lapses between two of the holder's own ticks would
	-- hand formation to another server every tick.
	if mm.leaseTtlSeconds <= mm.formationTickSeconds then
		bad("leaseTtlSeconds", "must be longer than formationTickSeconds")
	end
	if mm.backoffCapSeconds < mm.backoffBaseSeconds then
		bad("backoffCapSeconds", "must be at least backoffBaseSeconds")
	end
	if mm.recentOpponentsCap < mm.groupSize - 1 then
		bad("recentOpponentsCap", "must hold at least one full group's worth of co-players (groupSize - 1)")
	end
	if mm.unavailableAfterFailures < 1 then
		bad("unavailableAfterFailures", "must be at least 1")
	end
end

-- P5-2. Like matchmaking's, these protect liveness: a bad value strands
-- or bounces players, it can't let anyone into the wrong match.
local function checkTeleportConfig(tp: TeleportConfig, mm: MatchmakingConfig?, issues: { Issue })
	local function bad(field: string, message: string)
		issue(issues, "GameConfig", "GameConfig.luau", "teleport." .. field, message)
	end

	if tp == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "teleport", "the teleport config block is missing entirely")
		return
	end
	local issuesBefore = #issues

	if type(tp.matchPlaceId) ~= "number" or tp.matchPlaceId < 0 then
		bad("matchPlaceId", "must be a place id, or 0 for unset")
	elseif mm ~= nil and tp.matchPlaceId ~= 0 and tp.matchPlaceId == mm.hubPlaceId then
		bad("matchPlaceId", "must differ from matchmaking.hubPlaceId - the hub would teleport players to itself")
	end

	for _, field in { "maxAttempts", "manifestReadAttempts" } do
		local value = (tp :: any)[field]
		if type(value) ~= "number" or value < 1 or value > 10 or value % 1 ~= 0 then
			bad(field, "must be a whole number from 1 to 10")
		end
	end
	for _, field in { "retryBaseSeconds", "retryCapSeconds", "travelWatchdogSeconds" } do
		local value = (tp :: any)[field]
		if type(value) ~= "number" or value <= 0 then
			bad(field, "must be positive")
		end
	end
	if type(tp.profileLoadGraceSeconds) ~= "number" or tp.profileLoadGraceSeconds < 0 then
		bad("profileLoadGraceSeconds", "must be zero or positive")
	end
	if #issues > issuesBefore then
		return -- the orderings below would compare garbage
	end
	if tp.retryCapSeconds < tp.retryBaseSeconds then
		bad("retryCapSeconds", "must be at least retryBaseSeconds")
	end

	-- The match server boots when its FIRST player arrives, which can be
	-- as late as that player's last attempt. The group record must still
	-- be there for it to read, or the server runs without a manifest.
	if mm ~= nil then
		local worstTravel = tp.maxAttempts * (tp.travelWatchdogSeconds + tp.retryCapSeconds)
		if mm.groupRecordTtlSeconds <= worstTravel then
			bad(
				"maxAttempts",
				string.format(
					"maxAttempts x (travelWatchdogSeconds + retryCapSeconds) = %ds must be under matchmaking.groupRecordTtlSeconds, or the match server can boot after its group record expired",
					worstTravel
				)
			)
		end
	end
end

-- P5-3. Like teleport's, these protect liveness and the ballot's shape;
-- nothing here can let a player vote twice or change a locked result
-- (that rests on VoteLogic's compare-and-set transforms).
local function checkPracticeConfig(pc: PracticeConfig, issues: { Issue })
	local function bad(field: string, message: string)
		issue(issues, "GameConfig", "GameConfig.luau", "practice." .. field, message)
	end

	if pc == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "practice", "the practice config block is missing entirely")
		return
	end

	if type(pc.durationScale) ~= "number" or pc.durationScale <= 0 or pc.durationScale > 1 then
		bad("durationScale", "must be above 0 and at most 1 - practice effects are never longer than real ones")
	end
	if type(pc.maxEffectSeconds) ~= "number" or pc.maxEffectSeconds <= 0 then
		bad("maxEffectSeconds", "must be positive")
	end
	if type(pc.maxActiveEffects) ~= "number" or pc.maxActiveEffects < 1 or pc.maxActiveEffects % 1 ~= 0 then
		bad("maxActiveEffects", "must be a whole number, at least 1")
	end
	-- Leaving the area or reaching the queue pad clears effects on the
	-- next check, so a slow check is a frozen player walking onto the pad.
	if type(pc.zoneCheckSeconds) ~= "number" or pc.zoneCheckSeconds <= 0 or pc.zoneCheckSeconds > 1 then
		bad("zoneCheckSeconds", "must be above 0 and at most 1")
	end

	if type(pc.itemSpawnRarities) ~= "table" or #pc.itemSpawnRarities == 0 then
		bad("itemSpawnRarities", "must list at least one rarity")
	else
		for i, rarity in pc.itemSpawnRarities do
			if rarity ~= "Common" and rarity ~= "Uncommon" and rarity ~= "Rare" then
				bad(
					string.format("itemSpawnRarities[%d]", i),
					string.format('expected "Common", "Uncommon" or "Rare", got %s', tostring(rarity))
				)
			end
		end
	end

	for _, rarity in { "Common", "Uncommon", "Rare" } do
		local multiplier = if type(pc.respawnMultipliers) == "table"
			then (pc.respawnMultipliers :: any)[rarity]
			else nil
		if type(multiplier) ~= "number" or multiplier <= 0 then
			bad("respawnMultipliers." .. rarity, "must be positive")
		end
	end
end

local function checkVoteConfig(vc: VoteConfig, mm: MatchmakingConfig?, tp: TeleportConfig?, issues: { Issue })
	local function bad(field: string, message: string)
		issue(issues, "GameConfig", "GameConfig.luau", "vote." .. field, message)
	end

	if vc == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "vote", "the vote config block is missing entirely")
		return
	end
	local issuesBefore = #issues

	if type(vc.ballotSize) ~= "number" or vc.ballotSize < 3 or vc.ballotSize > 4 or vc.ballotSize % 1 ~= 0 then
		bad("ballotSize", "must be 3 or 4 - more is miserable to choose from on a phone (P5-3)")
	end
	if
		type(vc.recentMapsCap) ~= "number"
		or vc.recentMapsCap < 1
		or vc.recentMapsCap > 10
		or vc.recentMapsCap % 1 ~= 0
	then
		bad("recentMapsCap", "must be a whole number from 1 to 10")
	end
	for _, field in { "voteSeconds", "revealSeconds", "pollSeconds", "lockGraceSeconds" } do
		local value = (vc :: any)[field]
		if type(value) ~= "number" or value <= 0 then
			bad(field, "must be positive")
		end
	end
	if
		type(vc.recentMapsTtlSeconds) ~= "number"
		or vc.recentMapsTtlSeconds < 1
		or vc.recentMapsTtlSeconds > MEMORYSTORE_MAX_EXPIRATION_SECONDS
	then
		bad("recentMapsTtlSeconds", "must be from 1 to the MemoryStore expiration limit")
	end
	if type(vc.recentFloorWeight) ~= "number" or vc.recentFloorWeight <= 0 or vc.recentFloorWeight > 1 then
		bad("recentFloorWeight", "must be above 0 (0 would ban a recent map outright) and at most 1")
	end
	if type(vc.recentDecay) ~= "number" or vc.recentDecay < 0 or vc.recentDecay > 1 then
		bad("recentDecay", "must be from 0 to 1")
	end
	if type(vc.recentMapName) ~= "string" or vc.recentMapName == "" then
		bad("recentMapName", "must be a non-empty MemoryStore name")
	elseif mm ~= nil then
		for _, other in { mm.queueMapName, mm.groupMapName, mm.recentMapName, mm.metaMapName } do
			if vc.recentMapName == other then
				bad("recentMapName", "must not share a name with a matchmaking MemoryStore structure")
			end
		end
	end
	if #issues > issuesBefore then
		return -- the orderings below would compare garbage
	end

	if vc.pollSeconds >= vc.voteSeconds then
		bad("pollSeconds", "must be under voteSeconds, or players never see a live count")
	end

	-- The group record carries the vote AND is the match server's
	-- manifest, read when the first player arrives. It must outlast the
	-- whole vote plus the slowest possible travel.
	if mm ~= nil and tp ~= nil then
		local worst = vc.voteSeconds
			+ vc.lockGraceSeconds
			+ vc.revealSeconds
			+ tp.maxAttempts * (tp.travelWatchdogSeconds + tp.retryCapSeconds)
		if mm.groupRecordTtlSeconds <= worst then
			bad(
				"voteSeconds",
				string.format(
					"voteSeconds + lockGraceSeconds + revealSeconds + the worst teleport retry chain = %ds must be under matchmaking.groupRecordTtlSeconds, or the match server can boot after its group record expired",
					worst
				)
			)
		end
	end
end

function Validate.checkGameConfig(config: GameConfig, issues: { Issue })
	if config.playerCount <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "playerCount", "must be positive")
	end
	if config.qualifierCount <= 0 or config.qualifierCount > config.playerCount then
		issue(issues, "GameConfig", "GameConfig.luau", "qualifierCount", "must be positive and <= playerCount")
	end
	if config.tasksPerPlayer <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "tasksPerPlayer", "must be positive")
	end
	if config.qualificationFloorPercent < 0 or config.qualificationFloorPercent > 1 then
		issue(issues, "GameConfig", "GameConfig.luau", "qualificationFloorPercent", "must be between 0 and 1")
	end
	if config.raceDurationSeconds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "raceDurationSeconds", "must be positive")
	end

	if config.powerUpInventorySlots <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "powerUpInventorySlots", "must be positive")
	end
	if config.powerUpFullInventoryPolicy ~= "Swap" and config.powerUpFullInventoryPolicy ~= "Refuse" then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"powerUpFullInventoryPolicy",
			string.format('expected "Swap" or "Refuse", got %s', tostring(config.powerUpFullInventoryPolicy))
		)
	end
	if config.powerUpUseRangeStuds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "powerUpUseRangeStuds", "must be positive")
	end
	if config.powerUpTargetConeDegrees <= 0 or config.powerUpTargetConeDegrees > 360 then
		issue(issues, "GameConfig", "GameConfig.luau", "powerUpTargetConeDegrees", "must be > 0 and <= 360")
	end
	for _, rarity in { "Common", "Uncommon", "Rare" } do
		local seconds = (config.powerUpRotationTimers :: any)[rarity]
		if type(seconds) ~= "number" or seconds <= 0 then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				"powerUpRotationTimers." .. rarity,
				"must be a positive number"
			)
		end
	end

	if config.movementSampleIntervalSeconds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "movementSampleIntervalSeconds", "must be positive")
	end
	if config.movementSpeedTolerance <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "movementSpeedTolerance", "must be positive")
	end
	if config.movementViolationDecayPerSecond < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "movementViolationDecayPerSecond", "must not be negative")
	end
	if
		not (
			config.movementViolationLogThreshold <= config.movementViolationFlagThreshold
			and config.movementViolationFlagThreshold <= config.movementViolationActThreshold
		)
	then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"movementViolation*Threshold",
			string.format(
				"expected log (%s) <= flag (%s) <= act (%s)",
				tostring(config.movementViolationLogThreshold),
				tostring(config.movementViolationFlagThreshold),
				tostring(config.movementViolationActThreshold)
			)
		)
	end

	if config.decisionStudioDefaultChoice ~= "Steal" and config.decisionStudioDefaultChoice ~= "Share" then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"decisionStudioDefaultChoice",
			string.format('expected "Steal" or "Share", got %s', tostring(config.decisionStudioDefaultChoice))
		)
	end
	if config.decisionStudioChatRangeStuds <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "decisionStudioChatRangeStuds", "must be positive")
	end

	checkNPCConfig(config.npc, issues)
	checkNPCBrainConfig(config.npcBrain, issues)

	checkLeaderboardConfig(config.leaderboard, issues)
	checkStoreConfig(config.store, issues)
	checkMatchmakingConfig(config.matchmaking, config.playerCount, issues)
	checkTeleportConfig(config.teleport, config.matchmaking, issues)
	checkVoteConfig(config.vote, config.matchmaking, config.teleport, issues)
	checkPracticeConfig(config.practice, issues)

	local telemetry = config.telemetry
	if telemetry == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "telemetry", "the telemetry config block is missing entirely")
	else
		if type(telemetry.enabled) ~= "boolean" then
			issue(issues, "GameConfig", "GameConfig.luau", "telemetry.enabled", "must be a boolean")
		end
		if telemetry.batchSize < 1 then
			issue(issues, "GameConfig", "GameConfig.luau", "telemetry.batchSize", "must be at least 1")
		end
		if telemetry.flushIntervalSeconds <= 0 then
			issue(issues, "GameConfig", "GameConfig.luau", "telemetry.flushIntervalSeconds", "must be positive")
		end
		if telemetry.perMinuteLimit < 0 then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				"telemetry.perMinuteLimit",
				"must not be negative (0 means no limit)"
			)
		end
	end

	if config.npcTitleNoneChance < 0 or config.npcTitleNoneChance > 1 then
		issue(issues, "GameConfig", "GameConfig.luau", "npcTitleNoneChance", "must be between 0 and 1")
	end
	if config.npcTitleTopRungsExcluded < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "npcTitleTopRungsExcluded", "must not be negative")
	end

	for _, field in { "loadingSeconds", "introSeconds", "qualifiedSeconds", "resultsSeconds", "cleanupSeconds" } do
		local value = (config.roundTimers :: any)[field]
		if type(value) ~= "number" or value <= 0 then
			issue(issues, "GameConfig", "GameConfig.luau", "roundTimers." .. field, "must be a positive number")
		end
	end

	if #config.bountyTiers == 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "bountyTiers", "must declare at least one tier")
	end

	-- P3-2 found this the hard way: ProfileLogic.resolveBountyTier errors
	-- loudly when no tier covers a given streak, and a brand-new
	-- qualifier's streak really can be 0 (their first-ever win, before
	-- currentStreak has incremented at all) - so the lowest tier's own
	-- floor must reach down to 0, not just "the lowest streak anyone
	-- expects to see."
	local coversZero = false
	for _, tier in config.bountyTiers do
		if tier.minStreak <= 0 then
			coversZero = true
		end
	end
	if #config.bountyTiers > 0 and not coversZero then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"bountyTiers",
			"no tier's minStreak is <= 0 - a streak-0 qualifier (a first-ever win) would have no covering tier"
		)
	end

	local previousMinStreak: number? = nil
	for _, tier in config.bountyTiers do
		local label = string.format("bountyTiers[tier=%s]", tostring(tier.tier))

		-- The central invariant the P1-4 task asks for by name: sole-
		-- stealer bounty > lone-sharer bounty > all-share bounty > 0,
		-- checked at every tier (payoff-table.md §1's asymmetric payoff
		-- shape is what keeps Steal and Share both live options).
		if
			not (tier.soleStealerVU > tier.loneSharerVU and tier.loneSharerVU > tier.allShareVU and tier.allShareVU > 0)
		then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				label,
				string.format(
					"bounty ordering broken: expected soleStealer (%s) > loneSharer (%s) > allShare (%s) > 0",
					tostring(tier.soleStealerVU),
					tostring(tier.loneSharerVU),
					tostring(tier.allShareVU)
				)
			)
		end

		if previousMinStreak ~= nil and tier.minStreak <= previousMinStreak then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				label,
				"bountyTiers must be sorted by strictly ascending minStreak"
			)
		end
		previousMinStreak = tier.minStreak
	end
end

-- ===== cross-registry checks =============================================
-- Duplicate ids and cross-references need the WHOLE set of a category,
-- not one item at a time, so they live here rather than in the per-item
-- checks above.

local function checkDuplicateIds(
	category: string,
	entries: { { fileName: string, def: { id: string } } },
	issues: { Issue }
)
	local seenAt: { [string]: string } = {}
	for _, entry in entries do
		local existingFile = seenAt[entry.def.id]
		if existingFile ~= nil then
			issue(
				issues,
				category,
				entry.fileName,
				"id",
				string.format("duplicate id %q also declared by %s", entry.def.id, existingFile)
			)
		else
			seenAt[entry.def.id] = entry.fileName
		end
	end
end

export type RegistryInput = {
	gameConfig: GameConfig,
	maps: { { fileName: string, def: MapDef } },
	tasks: { { fileName: string, def: TaskDef } },
	powerUps: { { fileName: string, def: PowerUpDef } },
	titles: { { fileName: string, def: TitleDef } },
	-- P3-6. Optional so every existing caller and test fixture that
	-- predates NPC personalities keeps working unchanged - an omitted
	-- registry is "none registered," which is exactly what a repo with
	-- no personality files has.
	npcPersonalities: { { fileName: string, def: NPCPersonalityDef } }?,

	-- P4-5. Optional for the same reason npcPersonalities is - a test
	-- fixture or a caller predating the store passes no store registry,
	-- which is exactly "nothing is for sale."
	store: { { fileName: string, def: StoreItemDef } }?,

	-- P4-6. Optional for the same reason - a test fixture or a caller
	-- predating the cosmetics registry passes none, which is exactly
	-- "every Cosmetic grant's id stays opaque," the stance StoreGrant's
	-- own comment already documents.
	cosmetics: { { fileName: string, def: CosmeticDef } }?,
}

function Validate.run(input: RegistryInput): { Issue }
	local issues: { Issue } = {}

	Validate.checkGameConfig(input.gameConfig, issues)

	for _, entry in input.maps do
		Validate.checkMap(entry.fileName, entry.def, issues)
	end
	for _, entry in input.tasks do
		Validate.checkTask(entry.fileName, entry.def, issues)
	end
	for _, entry in input.powerUps do
		Validate.checkPowerUp(entry.fileName, entry.def, issues)
	end
	for _, entry in input.titles do
		Validate.checkTitle(entry.fileName, entry.def, issues)
	end
	local npcPersonalities = input.npcPersonalities
	if npcPersonalities ~= nil then
		for _, entry in npcPersonalities do
			Validate.checkNPCPersonality(entry.fileName, entry.def, issues)
		end
	end
	local cosmetics = input.cosmetics
	if cosmetics ~= nil then
		for _, entry in cosmetics do
			Validate.checkCosmeticItem(entry.fileName, entry.def, issues)
		end
	end

	checkDuplicateIds("Map", input.maps :: any, issues)
	checkDuplicateIds("Task", input.tasks :: any, issues)
	checkDuplicateIds("PowerUp", input.powerUps :: any, issues)
	checkDuplicateIds("Title", input.titles :: any, issues)
	checkDuplicateIds("Cosmetic", (cosmetics or {}) :: any, issues)

	-- P4-2: two titles at the same threshold make "the highest title
	-- you've unlocked" ambiguous, and which one a player sees would then
	-- depend on registry iteration order - i.e. on a filename. The
	-- ladder has to be a total order to be a ladder.
	local titleByStreak: { [number]: string } = {}
	for _, entry in input.titles do
		local existing = titleByStreak[entry.def.minStreak]
		if existing ~= nil then
			issue(
				issues,
				"Title",
				entry.fileName,
				"minStreak",
				string.format(
					"threshold %d is already claimed by %s - each rung of the ladder needs its own",
					entry.def.minStreak,
					existing
				)
			)
		end
		titleByStreak[entry.def.minStreak] = entry.def.id
	end
	checkDuplicateIds("NPCPersonality", (input.npcPersonalities or {}) :: any, issues)

	local knownTaskIds: { [string]: boolean } = {}
	for _, entry in input.tasks do
		knownTaskIds[entry.def.id] = true
	end

	for _, entry in input.maps do
		for _, taskId in entry.def.enabledTaskIds do
			if not knownTaskIds[taskId] then
				issue(
					issues,
					"Map",
					entry.fileName,
					"enabledTaskIds",
					string.format("references unregistered task id %q", taskId)
				)
			end
		end

		-- The invariant the P1-4 task names explicitly: every map has at
		-- least as many task stations as tasks assigned per player.
		if entry.def.taskStationCount < input.gameConfig.tasksPerPlayer then
			issue(
				issues,
				"Map",
				entry.fileName,
				"taskStationCount",
				string.format(
					"%d stations is fewer than GameConfig.tasksPerPlayer (%d)",
					entry.def.taskStationCount,
					input.gameConfig.tasksPerPlayer
				)
			)
		end
	end

	-- ===== P4-5's store cross-checks ====================================
	local store = input.store
	if store ~= nil then
		for _, entry in store do
			Validate.checkStoreItem(entry.fileName, entry.def, issues)
		end

		-- Not checkDuplicateIds: a store entry's stable id is `key`, not
		-- `id`, precisely because it is deliberately not Roblox's number.
		local storeKeyAt: { [string]: string } = {}
		for _, entry in store do
			local existing = storeKeyAt[entry.def.key]
			if existing ~= nil then
				issue(
					issues,
					"Store",
					entry.fileName,
					"key",
					string.format("duplicate key %q also declared by %s", entry.def.key, existing)
				)
			else
				storeKeyAt[entry.def.key] = entry.fileName
			end
		end

		-- Two products sharing one Roblox asset id is the monetisation
		-- equivalent of a duplicate key, and far easier to do by accident
		-- (copy a file, change the name, forget the number). The damage
		-- is specific: ProcessReceipt dispatches on ProductId, so the
		-- second product would silently grant the first one's contents.
		-- Id 0 is exempt - it means "not created yet," and every
		-- unfinished entry legitimately shares it.
		local assetIdAt: { [number]: string } = {}
		for _, entry in store do
			if entry.def.assetId == 0 then
				continue
			end
			local existing = assetIdAt[entry.def.assetId]
			if existing ~= nil then
				issue(
					issues,
					"Store",
					entry.fileName,
					"assetId",
					string.format(
						"asset id %d is already claimed by %s - ProcessReceipt dispatches on this number, so one of these two products would grant the other's contents",
						entry.def.assetId,
						existing
					)
				)
			else
				assetIdAt[entry.def.assetId] = entry.fileName
			end
		end

		local powerUpAt: { [string]: PowerUpDef } = {}
		for _, entry in input.powerUps do
			powerUpAt[entry.def.id] = entry.def
		end
		local knownTitleIds: { [string]: boolean } = {}
		for _, entry in input.titles do
			knownTitleIds[entry.def.id] = true
		end
		-- P4-6: nil (not just missing-key) when no cosmetics registry was
		-- passed at all, which keeps every caller/fixture that predates
		-- P4-6 exactly as unchecked as StoreGrant's own comment promises.
		local cosmeticAt: { [string]: CosmeticDef }? = if input.cosmetics ~= nil then {} else nil
		if cosmeticAt ~= nil and input.cosmetics ~= nil then
			for _, entry in input.cosmetics do
				(cosmeticAt :: { [string]: CosmeticDef })[entry.def.id] = entry.def
			end
		end

		for _, entry in store do
			-- `grants` is non-optional in the type, but checkStoreItem
			-- above tolerates a config file that predates it, so this
			-- loop checks rather than assumes - it runs over the same
			-- registry and must not be the thing that throws.
			if type(entry.def.grants) ~= "table" then
				continue
			end
			for index, grant in entry.def.grants do
				local field = string.format("grants[%d]", index)

				if grant.kind == "PowerUpStock" then
					local powerUp = powerUpAt[grant.powerUpId or ""]
					if powerUp == nil then
						issue(
							issues,
							"Store",
							entry.fileName,
							field,
							string.format("references unregistered power-up id %q", tostring(grant.powerUpId))
						)
						continue
					end

					-- Stock only means anything if the item can actually
					-- go in a loadout slot - a field-pickup-only power-up
					-- bought in bulk is a purchase that does nothing.
					if not powerUp.acquisition.loadoutEligible then
						issue(
							issues,
							"Store",
							entry.fileName,
							field,
							string.format(
								"power-up %q is not loadoutEligible, so stock of it can never be equipped - this product would sell nothing",
								powerUp.id
							)
						)
					end

					-- design-decisions.md Q8's whole rule, checked from
					-- the selling side. checkPowerUp already refuses a
					-- power-up whose own robuxPrice has no matching free
					-- path; this catches the same violation arriving
					-- through a bundle instead, where the power-up's own
					-- config looks innocent because it names no price.
					if not (powerUp.acquisition.fieldPickup or powerUp.acquisition.freelyEarnable) then
						issue(
							issues,
							"Store",
							entry.fileName,
							field,
							string.format(
								"power-up %q has no free acquisition path - design-decisions.md Q8 forbids selling an item players cannot also earn, whether it is priced on its own config or bundled here",
								powerUp.id
							)
						)
					end
				elseif grant.kind == "Cosmetic" then
					if cosmeticAt ~= nil then
						local cosmetic = cosmeticAt[grant.cosmeticId or ""]
						if cosmetic == nil then
							issue(
								issues,
								"Store",
								entry.fileName,
								field,
								string.format("references unregistered cosmetic id %q", tostring(grant.cosmeticId))
							)
						elseif entry.def.enabled and not cosmetic.enabled then
							-- Only checked when the PRODUCT itself is
							-- enabled - a disabled product forward-
							-- referencing a not-yet-built cosmetic
							-- (FounderPass.luau, VictoryEmotePass.luau) is
							-- the same legitimate bootstrap state
							-- checkStoreItem's own "enabled = true but
							-- assetId is 0" check allows for a disabled
							-- entry.
							issue(
								issues,
								"Store",
								entry.fileName,
								field,
								string.format(
									"cosmetic %q is not enabled - it has no Roblox asset yet, so this ENABLED product would grant something invisible",
									cosmetic.id
								)
							)
						end
					end
				elseif grant.kind == "Title" then
					if not knownTitleIds[grant.titleId or ""] then
						issue(
							issues,
							"Store",
							entry.fileName,
							field,
							string.format("references unregistered title id %q", tostring(grant.titleId))
						)
					end
				end
			end
		end
	end

	return issues
end

return Validate
