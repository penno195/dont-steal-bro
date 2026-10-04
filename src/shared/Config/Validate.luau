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
-- P7-6. How this map draws the world-space marker on your stations
-- (docs/station-readability.md). nil = the defaults in
-- client/UI/StationMarkerLogic.luau. Only set it for a theme where the
-- default reads poorly. Colours are "#RRGGBB" strings so Lune can load
-- this, the same as lighting presets.
export type StationMarkerDef = {
	beam: boolean, -- the light shaft; off where it clips low ceilings or fights a landmark
	pad: boolean, -- the glowing floor ring
	beamHeight: number, -- studs, see STATION_MARKER_BEAM_HEIGHT_*
	tint: string?, -- nil = the theme's brand colour
}

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
	stationMarker: StationMarkerDef?, -- P7-6: nil = default marker
}

-- The shaft has to clear the tallest walkway dressing (~4 studs) to read
-- over clutter. It must also stop short of the ~16-stud floor spacing in
-- wave1-briefs.md, or a ground-floor shaft pokes up through the floor
-- above and marks a spot where there's no station.
Validate.STATION_MARKER_BEAM_HEIGHT_MIN = 4
Validate.STATION_MARKER_BEAM_HEIGHT_MAX = 14

-- P7-5. One file per preset in Config/LightingPresets/; a MapDef's
-- `lightingPreset` names one by `id`. Colours are "#RRGGBB" strings, not
-- Color3, so this module stays loadable by Lune. Every Lighting field is
-- required: LightingService writes all of them on every apply, so nothing
-- from the previous map's preset can survive into the next one.
--
-- No `technology` field: Lighting.Technology is deprecated and not
-- scriptable (set once in Studio). LightingStyle plus
-- PrioritizeLightingQuality replace it and can be written from a script.
-- docs/lighting-and-streaming.md has the reasoning and the per-effect
-- mobile cost behind each preset.
export type LightingStyleName = "Soft" | "Realistic"

export type ColorCorrectionDef = {
	brightness: number,
	contrast: number,
	saturation: number,
	tintColor: string,
}

export type BloomDef = {
	intensity: number,
	size: number,
	threshold: number,
}

export type LightingPresetDef = {
	id: string,
	lightingStyle: LightingStyleName,
	prioritizeLightingQuality: boolean,
	globalShadows: boolean,
	ambient: string,
	outdoorAmbient: string,
	brightness: number,
	clockTime: number, -- 0-24
	environmentDiffuseScale: number, -- 0-1
	environmentSpecularScale: number, -- 0-1
	exposureCompensation: number,
	fogColor: string,
	fogStart: number,
	fogEnd: number,
	colorCorrection: ColorCorrectionDef?, -- nil = no ColorCorrectionEffect at all
	bloom: BloomDef?, -- nil = no BloomEffect at all
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
-- The HUD/pickup colour family. Attack is exactly the Debuffs; Buffs
-- split into Defence (protects you) and Utility (speeds you up) - a
-- presentation split `kind` alone cannot express. Rarity is a secondary
-- ring, never the main colour.
export type PowerUpRole = "Attack" | "Defence" | "Utility"

local POWERUP_KINDS: { PowerUpKind } = { "Buff", "Debuff" }
local POWERUP_ROLES: { PowerUpRole } = { "Attack", "Defence", "Utility" }
local POWERUP_TARGETS: { PowerUpTarget } = { "Self", "Aimed", "Area", "Nearest" }
local POWERUP_RARITIES: { PowerUpRarity } = { "Common", "Uncommon", "Rare" }
local POWERUP_DESCRIPTION_MAX = 48

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

-- How a thrown (Aimed/Nearest) power-up travels and lands. The target is
-- still chosen on the server at throw time; the projectile homes on it,
-- and the effect applies when it arrives (distance / speed, capped).
export type PowerUpThrowConfig = {
	projectileSpeedStuds: number, -- studs/second
	maxFlightSeconds: number, -- cap on the flight, so a long throw can't sit uncommitted
	arcHeightStuds: number, -- peak height of the lob above the straight line
	explosionRadiusStuds: number, -- visual only; the effect still hits just the one target
	shuntSpeed: number, -- horizontal studs/second the victim is shoved away from the thrower
	shuntUpSpeed: number, -- small upward pop, so the shove clears the floor friction
	recoilSpeed: number, -- the thrower is nudged backwards by this much
}

export type PowerUpDef = {
	id: string,
	displayName: string,
	-- One plain line saying what it does, shown on first pickup, on
	-- long-press of the slot and in the "hit by" banner. Capped at
	-- POWERUP_DESCRIPTION_MAX chars so it fits one line on a phone.
	description: string,
	kind: PowerUpKind,
	role: PowerUpRole,
	target: PowerUpTarget,
	durationSeconds: number,
	cooldownSeconds: number,
	rarity: PowerUpRarity,
	hardControl: boolean, -- Freeze/Push-Trip = true; powerups.md's anti-frustration caps apply only to these
	-- Required for target "Area" (the zone's radius on the ground, in
	-- studs), and meaningless for anything else.
	areaRadiusStuds: number?,
	-- A thrown item (Aimed/Nearest) shoves the victim on impact by
	-- GameConfig.powerUpThrow's shunt; this scales it for this item
	-- (Push/Trip's whole point is the shove). nil = 1. Only on thrown items.
	shuntScale: number?,
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
-- gdd.md's cosmetics: a character skin, a trail, a victory emote, a
-- podium decoration and reveal burst for the Decision Studio, a thrown
-- power-up's look, streak and nameplate styling, and a calling card. One
-- file per item (Ground Rule 2) - adding one is adding a
-- src/shared/Config/Cosmetics/<Name>.luau and nothing else. (A new
-- CATEGORY is a service change too: something has to draw it.)
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
-- `id`, or unlocked on a season track (see Seasons/Season1.luau).
-- Duplicating a price
-- here would be a second source of truth for the same number, and the
-- two would eventually disagree. `rarity` stays here rather than on the
-- store entry because it's a property of the ITEM regardless of which
-- product happens to sell it (or whether one does yet), and because
-- P6-6's item grid reads it directly for rarity treatment.
--
-- `rarity` reuses PowerUpRarity rather than inventing a second tier
-- system - one ladder of "how special is this" for the whole game.
--
-- WHY "Reveal" AND "Projectile" HAVE NO COLOUR FIELD, unlike every other
-- visual category: their colour already MEANS something. A thrown
-- power-up is tinted by its role (PowerUpLogic.ROLE_RGB) so a victim can
-- read what's coming at them, and a Steal/Share reveal is coloured by the
-- outcome. A cosmetic that could repaint either would sell confusion, so
-- those two skins only ever change shape and texture - the renderer keeps
-- supplying the colour. The type has nowhere to put one, by design.
export type CosmeticCategory =
	"Skin"
	| "Trail"
	| "Emote"
	| "Podium"
	| "Reveal"
	| "Projectile"
	| "StreakFlair"
	| "Nameplate"
	| "CallingCard"

local COSMETIC_CATEGORIES: { CosmeticCategory } = {
	"Skin",
	"Trail",
	"Emote",
	"Podium",
	"Reveal",
	"Projectile",
	"StreakFlair",
	"Nameplate",
	"CallingCard",
}

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

	-- Category "Reveal": the burst on a finalist's podium the moment their
	-- Steal/Share is shown - never before, or it would leak the choice.
	-- Tinted by the outcome, not by this item (see the header above).
	revealTextureAssetId: number?,
	revealSoundAssetId: number?, -- optional; 0/nil = the default reveal sound

	-- Category "Projectile": what your thrown power-up looks like in the
	-- air and where it lands. Tinted by the power-up's role, and sized by
	-- ThrowController's own constant - a skin must never change how big
	-- a throw reads. Purely client-side; the server never reads either.
	projectileMeshAssetId: number?,
	explosionTextureAssetId: number?,

	-- Category "StreakFlair": the style of the win-streak counter above
	-- your head in the Hub (StreakTagController; Hub only, per Q7). The
	-- NUMBER is always the real streak - this only dresses it.
	flairTextureAssetId: number?,
	flairColorHex: string?,

	-- Category "Nameplate": the frame around your name and Title. Titles
	-- themselves stay earn-only (TitleDef) - this sells the frame, never
	-- the words inside it.
	nameplateFrameAssetId: number?,
	nameplateColorHex: string?,

	-- Category "CallingCard": the small card a victim sees for a moment
	-- when your sabotage lands on them.
	cardImageAssetId: number?,

	-- Store UI thumbnail (P6-6's item grid). Optional: falls back to
	-- whatever the category's own primary asset id would render as.
	previewIconAssetId: number?,

	-- Whether a win can drop this (design-decisions.md Q1, applied
	-- 2026-10-02). Opt-in, so founder, paid-only and limited cosmetics
	-- stay out of the win pool unless their own file says otherwise.
	-- Disabled cosmetics never drop, whatever this says.
	winDrop: boolean?,
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
-- CoinOffer (rewards step 6): bought with earned coins, not Robux. No
-- Roblox asset (assetId and robuxPrice are 0), priced by `coinPrice`, and
-- it may only grant power-up stock (user decision, 2026-10-02).
export type StoreProductKind = "GamePass" | "DeveloperProduct" | "CoinOffer"
export type StoreGrantKind = "Currency" | "PowerUpStock" | "Cosmetic" | "Title"

local STORE_PRODUCT_KINDS: { StoreProductKind } = { "GamePass", "DeveloperProduct", "CoinOffer" }
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
	coinPrice: number?, -- CoinOffer only: what it costs in coins, deducted server-side
	sortOrder: number,
	-- A DeveloperProduct grants at least one thing. A GamePass grants
	-- nothing here: every pass is a season pass, and what it unlocks is
	-- that season's premium track (SeasonDef below).
	grants: { StoreGrant },
}

-- ===== SeasonDef: rewards-roadmap.md step 5 ==============================
-- One file per season in src/shared/Config/Seasons/ (design-decisions.md
-- Q1's 2026-09-30 revision, applied 2026-10-02). A season runs between
-- two fixed UTC dates, and seasons replace each other, so no two windows
-- may overlap. It has two tracks of items unlocked at win counts:
--   * `free` counts every win in the window, for everyone (a retention
--     tool, so it's the less generous of the two);
--   * `premium` is unlocked by `passKey`, a Store GamePass, and counts
--     only wins after the pass was first seen owned.
-- Track items are track-only forever: a cosmetic on a track never drops,
-- is never sold, and appears on no other track or leaderboard band.
-- A power-up on a track must be freelyEarnable (Q8).
export type SeasonGrantKind = "Currency" | "PowerUpStock" | "Cosmetic"

local SEASON_GRANT_KINDS: { SeasonGrantKind } = { "Currency", "PowerUpStock", "Cosmetic" }

export type SeasonTrackItem = {
	wins: number, -- 0 = granted as soon as the track starts counting
	grant: StoreGrant, -- Title isn't allowed here; see SEASON_GRANT_KINDS
}

export type SeasonDef = {
	id: string,
	enabled: boolean,
	displayName: string,
	startsOn: string, -- "YYYY-MM-DD", 00:00 UTC, inclusive
	endsOn: string, -- "YYYY-MM-DD", 00:00 UTC, exclusive
	passKey: string, -- the Store GamePass that unlocks `premium`
	free: { SeasonTrackItem }, -- ascending `wins`
	premium: { SeasonTrackItem }, -- ascending `wins`
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
	studioEcho: boolean, -- Studio only: print each event, since Studio can't send them
}

-- ===== LiveOpsConfig: P8-5 ===============================================
-- Where the live config lives, who may edit it, and which paths an
-- override may touch. src/server/LiveConfigLogic.luau owns the rules.
export type LiveOpsConfig = {
	enabled: boolean, -- false = shipped defaults only, the DataStore is never read
	dataStoreName: string,
	envelopeKey: string,
	auditKey: string,
	refreshSeconds: number,
	auditLogCap: number,
	adminUserIds: { number },
	tunablePaths: { string }, -- "<root>.<seg>..."; "*" = one segment, trailing "**" = any depth
}

-- LiveConfigLogic.ROOTS, copied (this file has zero requires) - change
-- both together.
local LIVE_OPS_ROOTS = { "game", "powerUp", "effect", "map" }

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
	bagCopiesByRole: { [string]: number }, -- copies of each item per shuffled deck, by role
	dummyAttackSeconds: number, -- one training dummy throws at a player this often
	dummyAttackPowerUpIds: { string }, -- what dummies throw; Aimed or Area items only; empty = off
	dummyTaskAttackPowerUpIds: { string }, -- thrown only at a player mid-task at the practice station, same rule
	taskId: string, -- the task the HubPracticeTask station runs; must be a task id
}

-- Proximity doors. See GameConfig.doors.
export type DoorConfig = {
	openRadius: number,
	closeRadius: number, -- >= openRadius
	checkSeconds: number,
	swingSeconds: number,
	openAngle: number, -- degrees, default for doors without an OpenAngle attribute
}

-- StudioTestService: Studio-only auto-start. See GameConfig.studioTest.
export type StudioTestConfig = {
	enabled: boolean,
	mapId: string, -- model name in ServerStorage.Maps
	minHumans: number, -- 1..playerCount
	startDelaySeconds: number,
}

-- ===== GameConfig: round/player counts, Studio timers, win rewards =====
-- Studio phase timers are locked exactly by architecture.md §6's network
-- trace (Intro +5s, Negotiate +20s - 45s until 2026-09-25 - Choose
-- +15s, Reveal +1s). Fields with no locked value anywhere in docs/ yet
-- are marked PLACEHOLDER, the same stance perf-budget.md and
-- threat-model.md take on their own unverified figures - not a guess
-- presented as fact.

-- What a win pays: design-decisions.md Q1's 2026-09-30 revision and its
-- 2026-10-02 applied case. A "rung" is how many title-ladder rungs the
-- winner's streak reaches AFTER this win (0-21; RewardLogic.rungFor).
-- Every number is PLACEHOLDER until playtest. Replaced the VU
-- bountyTiers (rewards-roadmap.md step 2c).
export type WinCurrencyConfig = {
	-- The base for each outcome tier. Validate keeps soleStealer >
	-- loneSharer > allShare > 0, the ordering bountyTiers had, so Steal
	-- and Share both stay live choices (payoff-table.md §1).
	soleStealer: number,
	loneSharer: number,
	allShare: number,
	perRungBonus: number, -- paid = floor(base * (1 + perRungBonus * rung))
}

export type DropRarityWeight = {
	weight: number, -- relative weight at rung 0
	perRungGrowth: number, -- weight * (1 + perRungGrowth * rung); higher on rarer tiers so they catch up
}

export type WinDropConfig = {
	baseChance: number, -- chance of any drop at rung 0, 0-1
	perRungChance: number, -- added per rung
	maxChance: number, -- cap, 0-1
	rarityWeights: { Common: DropRarityWeight, Uncommon: DropRarityWeight, Rare: DropRarityWeight },
	powerUpAmount: number, -- loadout stock granted by a power-up drop
	duplicateCurrency: PowerUpRarityWeights, -- paid instead of a cosmetic the winner already owns
}

export type WinRewardsConfig = {
	currency: WinCurrencyConfig,
	drop: WinDropConfig,
}

export type StudioTimers = {
	introSeconds: number,
	introNewPlayerSeconds: number,
	introMinSeconds: number,
	newPlayerFinales: number,
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
	raceDurationSeconds: number, -- PLACEHOLDER: no locked value in docs/ yet
	studioTimers: StudioTimers,
	roundTimers: RoundTimers,
	winRewards: WinRewardsConfig,

	-- P2-7: the IN-ROUND inventory PowerUpService owns. The pre-game
	-- loadout (StoreService) starts in these slots; field pickups fill
	-- the empty ones.
	powerUpInventorySlots: number, -- default 3, powerups.md "Inventory and aiming"
	powerUpFullInventoryPolicy: "Swap" | "Refuse", -- picking up while full: swap the oldest held item, or refuse the new pickup (world pickup stays available)
	powerUpUseRangeStuds: number, -- max range for an Aimed/Nearest target
	powerUpTargetConeDegrees: number, -- full cone width (not half-angle) of an Aimed power-up's lock-on cone
	powerUpLockOnSlackStuds: number, -- extra range allowed when re-checking the client's locked target (latency)
	powerUpLockOnSlackDegrees: number, -- extra cone width allowed for the same re-check
	powerUpThrow: PowerUpThrowConfig, -- the projectile, explosion, recoil and shunt of a thrown item
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
	-- The shared Decision Studio set (StudioStageService): its model
	-- name in ServerStorage.Maps, and how far along +X it's moved so it
	-- can't overlap the race map loaded beside it.
	decisionStudioStage: { mapId: string, offsetStuds: number },

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

	-- Proximity doors. See DoorConfig above.
	doors: DoorConfig,

	-- Studio test mode. See StudioTestConfig above.
	studioTest: StudioTestConfig,

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

	-- P8-5: live operations. See LiveOpsConfig above.
	liveOps: LiveOpsConfig,
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
	-- leaderboard-scale.md §9: the shared copy of each period board.
	periodShare: LeaderboardPeriodShare,
	-- Rewards-roadmap step 4: period kind -> bands of places.
	-- Structurally LeaderboardPayoutLogic.PayoutTable.
	payouts: { [string]: { LeaderboardPayoutBand } },
}

export type LeaderboardPeriodShare = {
	mapName: string,
	shardCount: number,
	republishAfterSeconds: number,
	lockSeconds: number,
	shardTtlSeconds: number,
}

export type LeaderboardPayoutBand = {
	maxRank: number,
	currency: number,
	cosmeticId: string?,
}

-- The period kinds LeaderboardService rolls over. The all-time board
-- never pays (design-decisions.md Q1, applied 2026-10-02), so it is not
-- a valid key.
local PAYOUT_KINDS: { [string]: true } = { Daily = true, Weekly = true }

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
	-- How many past finales a bot's rolled reputation covers (inclusive).
	historyFinales: { min: number, max: number },
	appearance: NPCAppearance,
}

-- The pools a bot's avatar is drawn from - catalog asset ids, one of
-- each per bot. A hat is added only `hatChance` of the time. Skin tones
-- are 0-255 RGB triples so this stays free of the Color3 datatype.
export type NPCAppearance = {
	hair: { number },
	faces: { number },
	shirts: { number },
	pants: { number },
	hats: { number },
	hatChance: number,
	skinTones: { { number } },
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

	local marker = def.stationMarker
	if marker ~= nil then
		local height = marker.beamHeight
		if
			type(height) ~= "number"
			or height < Validate.STATION_MARKER_BEAM_HEIGHT_MIN
			or height > Validate.STATION_MARKER_BEAM_HEIGHT_MAX
		then
			issue(
				issues,
				"Map",
				fileName,
				"stationMarker.beamHeight",
				string.format(
					"expected %d-%d studs, got %s",
					Validate.STATION_MARKER_BEAM_HEIGHT_MIN,
					Validate.STATION_MARKER_BEAM_HEIGHT_MAX,
					tostring(height)
				)
			)
		end
		local tint = marker.tint
		if tint ~= nil and (type(tint) ~= "string" or string.match(tint, "^#%x%x%x%x%x%x$") == nil) then
			issue(
				issues,
				"Map",
				fileName,
				"stationMarker.tint",
				string.format('expected a "#RRGGBB" colour, got %s', tostring(tint))
			)
		end
	end
end

-- Readability guards for lighting presets (P7-5). These are design limits,
-- not engine limits, and they are stricter than the engine's. A preset
-- that trips one would look moody and play badly.
--
-- Fog must not start before the longest sightline wave1-briefs.md §1.5
-- allows (~120 studs). Otherwise an overtake the layout was built to
-- show would be hidden in haze.
Validate.LIGHTING_MIN_FOG_START_STUDS = 120
-- The brightest channel of Ambient/OutdoorAmbient must reach at least
-- this. It keeps the shaded side of a station off black on a dim phone
-- screen at low brightness.
Validate.LIGHTING_MIN_AMBIENT_CHANNEL = 64
-- Heavy grading hurts colour-blind readability (accessibility.md) and
-- fights P7-6's station highlight, so grading stays a light touch.
Validate.LIGHTING_MAX_GRADE = 0.3
-- Bloom may only catch emissive surfaces (Neon, lights), never ordinary
-- lit geometry. A lower threshold washes out station props.
Validate.LIGHTING_MIN_BLOOM_THRESHOLD = 1

-- The brightest of a "#RRGGBB" colour's three channels (0-255), or nil
-- if the string is malformed.
local function brightestHexChannel(value: any): number?
	if type(value) ~= "string" or string.match(value, "^#%x%x%x%x%x%x$") == nil then
		return nil
	end
	local hex = value :: string
	return math.max(
		tonumber(string.sub(hex, 2, 3), 16) :: number,
		tonumber(string.sub(hex, 4, 5), 16) :: number,
		tonumber(string.sub(hex, 6, 7), 16) :: number
	)
end

function Validate.checkLightingPreset(fileName: string, def: LightingPresetDef, issues: { Issue })
	local function bad(field: string, message: string)
		issue(issues, "LightingPreset", fileName, field, message)
	end
	local function range(field: string, value: any, min: number, max: number)
		if type(value) ~= "number" or value < min or value > max then
			bad(field, string.format("expected %s-%s, got %s", tostring(min), tostring(max), tostring(value)))
		end
	end
	local function color(field: string, value: any): number?
		local brightest = brightestHexChannel(value)
		if brightest == nil then
			bad(field, string.format('expected a "#RRGGBB" colour, got %s', tostring(value)))
		end
		return brightest
	end

	if not isNonEmptyString(def.id) then
		bad("id", "id must be a non-empty string")
	end
	if def.lightingStyle ~= "Soft" and def.lightingStyle ~= "Realistic" then
		bad("lightingStyle", string.format('expected "Soft" or "Realistic", got %s', tostring(def.lightingStyle)))
	end
	for _, field in { "prioritizeLightingQuality", "globalShadows" } do
		if type((def :: any)[field]) ~= "boolean" then
			bad(field, "must be a boolean")
		end
	end

	for _, field in { "ambient", "outdoorAmbient" } do
		local brightest = color(field, (def :: any)[field])
		if brightest ~= nil and brightest < Validate.LIGHTING_MIN_AMBIENT_CHANNEL then
			bad(
				field,
				string.format(
					"too dark to read a station in shadow: brightest channel must be at least %d",
					Validate.LIGHTING_MIN_AMBIENT_CHANNEL
				)
			)
		end
	end
	color("fogColor", def.fogColor)

	range("brightness", def.brightness, 0, 5)
	range("clockTime", def.clockTime, 0, 24)
	range("environmentDiffuseScale", def.environmentDiffuseScale, 0, 1)
	range("environmentSpecularScale", def.environmentSpecularScale, 0, 1)
	range("exposureCompensation", def.exposureCompensation, -1, 1)

	if type(def.fogStart) ~= "number" or def.fogStart < Validate.LIGHTING_MIN_FOG_START_STUDS then
		bad(
			"fogStart",
			string.format(
				"must be at least %d studs (the longest designed sightline), got %s",
				Validate.LIGHTING_MIN_FOG_START_STUDS,
				tostring(def.fogStart)
			)
		)
	end
	if type(def.fogEnd) ~= "number" or type(def.fogStart) ~= "number" or def.fogEnd <= def.fogStart then
		bad("fogEnd", "must be greater than fogStart")
	end

	local grade = def.colorCorrection
	if grade ~= nil then
		local max = Validate.LIGHTING_MAX_GRADE
		range("colorCorrection.brightness", grade.brightness, -max, max)
		range("colorCorrection.contrast", grade.contrast, -max, max)
		range("colorCorrection.saturation", grade.saturation, -max, max)
		color("colorCorrection.tintColor", grade.tintColor)
	end

	local bloom = def.bloom
	if bloom ~= nil then
		range("bloom.intensity", bloom.intensity, 0, 1)
		range("bloom.size", bloom.size, 0, 56)
		if type(bloom.threshold) ~= "number" or bloom.threshold < Validate.LIGHTING_MIN_BLOOM_THRESHOLD then
			bad(
				"bloom.threshold",
				string.format(
					"must be at least %d so only emissive surfaces bloom, got %s",
					Validate.LIGHTING_MIN_BLOOM_THRESHOLD,
					tostring(bloom.threshold)
				)
			)
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
	if not isNonEmptyString(def.description) then
		issue(issues, "PowerUp", fileName, "description", "description must be a non-empty string")
	elseif (utf8.len(def.description) or #def.description) > POWERUP_DESCRIPTION_MAX then
		issue(
			issues,
			"PowerUp",
			fileName,
			"description",
			string.format("must be at most %d chars to fit one phone line", POWERUP_DESCRIPTION_MAX)
		)
	end
	if not inSet(def.kind, POWERUP_KINDS) then
		issue(issues, "PowerUp", fileName, "kind", string.format("expected Buff or Debuff, got %s", tostring(def.kind)))
	end
	if not inSet(def.role, POWERUP_ROLES) then
		issue(
			issues,
			"PowerUp",
			fileName,
			"role",
			string.format("expected one of [%s], got %s", table.concat(POWERUP_ROLES, ", "), tostring(def.role))
		)
	elseif (def.role == "Attack") ~= (def.kind == "Debuff") then
		-- Attack <=> Debuff: the red colour promises "this hurts someone
		-- else", so a Buff wearing it (or a Debuff in blue/yellow) lies.
		issue(issues, "PowerUp", fileName, "role", "role Attack must be used exactly for kind Debuff")
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
	local radius = def.areaRadiusStuds
	if def.target == "Area" and (radius == nil or radius <= 0) then
		issue(issues, "PowerUp", fileName, "areaRadiusStuds", "an Area item needs a positive radius")
	elseif def.target ~= "Area" and radius ~= nil then
		issue(issues, "PowerUp", fileName, "areaRadiusStuds", "only an Area item has a radius")
	end
	local shuntScale = def.shuntScale
	if shuntScale ~= nil then
		if def.target ~= "Aimed" and def.target ~= "Nearest" then
			issue(issues, "PowerUp", fileName, "shuntScale", "only a thrown (Aimed/Nearest) item has a shunt")
		elseif shuntScale < 0 or shuntScale > 5 then
			issue(issues, "PowerUp", fileName, "shuntScale", "must be between 0 and 5")
		end
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

local function checkColorHex(issues: { Issue }, fileName: string, field: string, value: any)
	if not isNonEmptyString(value) or not string.match(value, "^#%x%x%x%x%x%x$") then
		issue(issues, "Cosmetic", fileName, field, string.format('expected "#rrggbb", got %s', tostring(value)))
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
		checkColorHex(issues, fileName, "trailColorHex", def.trailColorHex)
		if def.trailLifetime == nil or def.trailLifetime <= 0 then
			issue(issues, "Cosmetic", fileName, "trailLifetime", "must be a positive number of seconds")
		end
	elseif def.category == "Emote" then
		checkAssetId(issues, fileName, "animationAssetId", def.animationAssetId, def.enabled)
	elseif def.category == "Podium" then
		checkAssetId(issues, fileName, "podiumTextureAssetId", def.podiumTextureAssetId, def.enabled)
		checkColorHex(issues, fileName, "podiumColorHex", def.podiumColorHex)
	elseif def.category == "Reveal" then
		checkAssetId(issues, fileName, "revealTextureAssetId", def.revealTextureAssetId, def.enabled)
		if def.revealSoundAssetId ~= nil then
			-- Optional even when enabled: 0 means "keep the default sound".
			checkAssetId(issues, fileName, "revealSoundAssetId", def.revealSoundAssetId, false)
		end
	elseif def.category == "Projectile" then
		checkAssetId(issues, fileName, "projectileMeshAssetId", def.projectileMeshAssetId, def.enabled)
		checkAssetId(issues, fileName, "explosionTextureAssetId", def.explosionTextureAssetId, def.enabled)
	elseif def.category == "StreakFlair" then
		checkAssetId(issues, fileName, "flairTextureAssetId", def.flairTextureAssetId, def.enabled)
		checkColorHex(issues, fileName, "flairColorHex", def.flairColorHex)
	elseif def.category == "Nameplate" then
		checkAssetId(issues, fileName, "nameplateFrameAssetId", def.nameplateFrameAssetId, def.enabled)
		checkColorHex(issues, fileName, "nameplateColorHex", def.nameplateColorHex)
	elseif def.category == "CallingCard" then
		checkAssetId(issues, fileName, "cardImageAssetId", def.cardImageAssetId, def.enabled)
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
	elseif def.kind == "CoinOffer" and def.assetId ~= 0 then
		issue(issues, "Store", fileName, "assetId", "a CoinOffer has no Roblox asset - set assetId = 0")
	elseif def.enabled and def.assetId == 0 and def.kind ~= "CoinOffer" then
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

	if def.kind == "CoinOffer" then
		local price = def.coinPrice
		if type(price) ~= "number" or price <= 0 or price % 1 ~= 0 then
			issue(issues, "Store", fileName, "coinPrice", "a CoinOffer needs a positive integer coinPrice")
		end
		if def.robuxPrice ~= 0 then
			issue(issues, "Store", fileName, "robuxPrice", "a CoinOffer is bought with coins - set robuxPrice = 0")
		end
	elseif def.coinPrice ~= nil then
		issue(issues, "Store", fileName, "coinPrice", "only a CoinOffer has a coinPrice")
	end

	if type(def.grants) ~= "table" then
		issue(issues, "Store", fileName, "grants", "grants must be a list")
		return
	end

	-- Every pass is a season pass (rewards-roadmap.md step 5): it grants
	-- nothing itself, and its season's premium track holds what it
	-- unlocks. A grant here would be owned forever, outside any window.
	if def.kind == "GamePass" then
		if #def.grants > 0 then
			issue(
				issues,
				"Store",
				fileName,
				"grants",
				"a GamePass grants nothing itself - put its items on a season's premium track (Config/Seasons/)"
			)
		end
		return
	end

	if #def.grants == 0 then
		issue(issues, "Store", fileName, "grants", "a product must grant at least one thing")
		return
	end

	for index, grant in def.grants do
		local field = string.format("grants[%d]", index)

		-- Coins buy power-up stock only (user decision, 2026-10-02): no
		-- cosmetics, titles or currency, and never anything random.
		if def.kind == "CoinOffer" and grant.kind ~= "PowerUpStock" then
			issue(issues, "Store", fileName, field, "a CoinOffer may only grant PowerUpStock")
		end

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

-- "YYYY-MM-DD" that names a real calendar date. Two valid dates compare
-- correctly as strings, which is all the window checks below need;
-- SeasonLogic.parseUtcDate turns them into os.time() at runtime.
local function isCalendarDate(text: any): boolean
	if type(text) ~= "string" then
		return false
	end
	local ys, ms, ds = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if ys == nil then
		return false
	end
	local y, m, d = tonumber(ys) :: number, tonumber(ms) :: number, tonumber(ds) :: number
	if m < 1 or m > 12 or d < 1 then
		return false
	end
	local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
	local maxDay = ({ 31, if leap then 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
	return d <= maxDay
end

local function checkSeasonTrack(fileName: string, trackName: string, track: any, issues: { Issue })
	if type(track) ~= "table" then
		issue(issues, "Season", fileName, trackName, "expected a list of track items")
		return
	end
	local lastWins = -1
	for index, item in track do
		local field = string.format("%s[%d]", trackName, index)
		if type(item) ~= "table" then
			issue(issues, "Season", fileName, field, "expected a { wins, grant } table")
			continue
		end
		if type(item.wins) ~= "number" or item.wins < 0 or item.wins % 1 ~= 0 then
			issue(issues, "Season", fileName, field .. ".wins", "expected a non-negative integer")
		elseif item.wins < lastWins then
			-- SeasonLogic pays a track strictly in list order, so an
			-- out-of-order item would wait behind a higher one.
			issue(issues, "Season", fileName, field .. ".wins", "items must be listed in ascending `wins`")
		else
			lastWins = item.wins
		end

		local grant = item.grant
		if type(grant) ~= "table" or not inSet(grant.kind, SEASON_GRANT_KINDS) then
			issue(
				issues,
				"Season",
				fileName,
				field .. ".grant",
				string.format("expected a grant of kind %s", table.concat(SEASON_GRANT_KINDS, "/"))
			)
			continue
		end
		local amountOk = type(grant.amount) == "number" and grant.amount > 0 and grant.amount % 1 == 0
		if grant.kind == "Currency" and not amountOk then
			issue(issues, "Season", fileName, field .. ".grant", "a Currency grant needs a positive integer `amount`")
		elseif grant.kind == "PowerUpStock" and (not amountOk or not isNonEmptyString(grant.powerUpId)) then
			issue(
				issues,
				"Season",
				fileName,
				field .. ".grant",
				"a PowerUpStock grant needs a `powerUpId` and a positive integer `amount`"
			)
		elseif grant.kind == "Cosmetic" and not isNonEmptyString(grant.cosmeticId) then
			issue(issues, "Season", fileName, field .. ".grant", "a Cosmetic grant needs a `cosmeticId`")
		end
	end
end

function Validate.checkSeason(fileName: string, def: SeasonDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "Season", fileName, "id", "id must be a non-empty string")
	end
	if not isNonEmptyString(def.displayName) then
		issue(issues, "Season", fileName, "displayName", "displayName must be a non-empty string")
	end
	if type(def.enabled) ~= "boolean" then
		issue(issues, "Season", fileName, "enabled", "enabled must be a boolean")
	end
	if not isNonEmptyString(def.passKey) then
		issue(issues, "Season", fileName, "passKey", "passKey must name a Store GamePass")
	end

	local startsOk = isCalendarDate(def.startsOn)
	local endsOk = isCalendarDate(def.endsOn)
	if not startsOk then
		issue(issues, "Season", fileName, "startsOn", 'expected a real date as "YYYY-MM-DD" (UTC)')
	end
	if not endsOk then
		issue(issues, "Season", fileName, "endsOn", 'expected a real date as "YYYY-MM-DD" (UTC)')
	end
	if startsOk and endsOk and def.endsOn <= def.startsOn then
		issue(issues, "Season", fileName, "endsOn", "a season must end after it starts")
	end

	checkSeasonTrack(fileName, "free", def.free, issues)
	checkSeasonTrack(fileName, "premium", def.premium, issues)
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

	local history = npc.historyFinales
	if
		history == nil
		or history.min < 0
		or history.max < history.min
		or history.min % 1 ~= 0
		or history.max % 1 ~= 0
	then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"npc.historyFinales",
			"must be whole numbers with 0 <= min <= max"
		)
	end

	local appearance = npc.appearance
	if appearance == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "npc.appearance", "the NPC appearance block is missing")
	else
		-- Hats may be empty (then no bot wears one); every other slot
		-- needs at least one option.
		for _, slot in { "hair", "faces", "shirts", "pants", "hats" } do
			local ids = (appearance :: any)[slot] :: { number }
			if #ids == 0 and slot ~= "hats" then
				issue(
					issues,
					"GameConfig",
					"GameConfig.luau",
					"npc.appearance." .. slot,
					"must list at least one asset id"
				)
			end
			for index, id in ids do
				if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 then
					issue(
						issues,
						"GameConfig",
						"GameConfig.luau",
						string.format("npc.appearance.%s[%d]", slot, index),
						"must be a positive whole asset id"
					)
				end
			end
		end
		if appearance.hatChance < 0 or appearance.hatChance > 1 then
			issue(issues, "GameConfig", "GameConfig.luau", "npc.appearance.hatChance", "must be between 0 and 1")
		end
		if #appearance.skinTones == 0 then
			issue(issues, "GameConfig", "GameConfig.luau", "npc.appearance.skinTones", "must list at least one tone")
		end
		for index, tone in appearance.skinTones do
			local valid = #tone == 3
			for _, channel in tone do
				if type(channel) ~= "number" or channel < 0 or channel > 255 then
					valid = false
				end
			end
			if not valid then
				issue(
					issues,
					"GameConfig",
					"GameConfig.luau",
					string.format("npc.appearance.skinTones[%d]", index),
					"must be three 0-255 numbers"
				)
			end
		end
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

	-- The shared period-board copy. The order matters: a lock outliving
	-- the republish age would let a copy go stale with nobody allowed to
	-- replace it, and a copy expiring before it is due for replacement
	-- would blank the board between publishes. And staleness must not
	-- be reached by a copy that is merely awaiting its republish.
	local share = leaderboard.periodShare
	if type(share) ~= "table" then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.periodShare", "must be a table")
	else
		if not isNonEmptyString(share.mapName) then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				"leaderboard.periodShare.mapName",
				"must be a non-empty string"
			)
		end
		if share.shardCount < 1 or share.shardCount ~= math.floor(share.shardCount) then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				"leaderboard.periodShare.shardCount",
				"must be a whole number, at least 1"
			)
		end
		if share.lockSeconds <= 0 or share.lockSeconds > share.republishAfterSeconds then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				"leaderboard.periodShare.lockSeconds",
				"must be positive and no greater than republishAfterSeconds"
			)
		end
		if share.republishAfterSeconds + leaderboard.refreshMaxSeconds >= leaderboard.staleAfterSeconds then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				"leaderboard.periodShare.republishAfterSeconds",
				"plus refreshMaxSeconds must stay under staleAfterSeconds - a copy awaiting republish must not read as stale"
			)
		end
		if share.shardTtlSeconds <= share.republishAfterSeconds + leaderboard.refreshMaxSeconds then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				"leaderboard.periodShare.shardTtlSeconds",
				"must exceed republishAfterSeconds + refreshMaxSeconds, or the board blanks between publishes"
			)
		end
	end
	local payouts = leaderboard.payouts
	if type(payouts) ~= "table" then
		issue(issues, "GameConfig", "GameConfig.luau", "leaderboard.payouts", "must be a table of period kinds")
	else
		for kind, bands in payouts do
			local path = "leaderboard.payouts." .. tostring(kind)
			if not PAYOUT_KINDS[kind] then
				issue(
					issues,
					"GameConfig",
					"GameConfig.luau",
					path,
					"must be Daily or Weekly - the all-time board never pays (design-decisions.md Q1)"
				)
				continue
			end
			if type(bands) ~= "table" or #bands == 0 then
				issue(issues, "GameConfig", "GameConfig.luau", path, "must list at least one band")
				continue
			end
			local previousMax = 0
			for i, band in bands do
				local bandPath = string.format("%s[%d]", path, i)
				local maxRank = band.maxRank
				if type(maxRank) ~= "number" or maxRank ~= math.floor(maxRank) or maxRank <= previousMax then
					issue(
						issues,
						"GameConfig",
						"GameConfig.luau",
						bandPath .. ".maxRank",
						"must be a whole number above the previous band's maxRank"
					)
				elseif maxRank > leaderboard.topCount then
					issue(
						issues,
						"GameConfig",
						"GameConfig.luau",
						bandPath .. ".maxRank",
						string.format(
							"must not exceed topCount (%d): only that many places are read",
							leaderboard.topCount
						)
					)
				else
					previousMax = maxRank
				end
				local currency = band.currency
				if type(currency) ~= "number" or currency < 0 or currency ~= math.floor(currency) then
					issue(
						issues,
						"GameConfig",
						"GameConfig.luau",
						bandPath .. ".currency",
						"must be a whole number, 0 or more"
					)
				end
				if band.cosmeticId ~= nil and not isNonEmptyString(band.cosmeticId) then
					issue(
						issues,
						"GameConfig",
						"GameConfig.luau",
						bandPath .. ".cosmeticId",
						"must be a non-empty string"
					)
				end
				if currency == 0 and band.cosmeticId == nil then
					issue(
						issues,
						"GameConfig",
						"GameConfig.luau",
						bandPath,
						"pays nothing - give it currency or a cosmeticId"
					)
				end
			end
		end
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
local function checkDoorConfig(dc: DoorConfig, issues: { Issue })
	local function bad(field: string, message: string)
		issue(issues, "GameConfig", "GameConfig.luau", "doors." .. field, message)
	end

	if dc == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "doors", "the doors config block is missing entirely")
		return
	end

	if type(dc.openRadius) ~= "number" or dc.openRadius <= 0 then
		bad("openRadius", "must be positive")
	end
	-- Equal radii are allowed but flap on the boundary; smaller is a bug.
	if type(dc.closeRadius) ~= "number" or (type(dc.openRadius) == "number" and dc.closeRadius < dc.openRadius) then
		bad("closeRadius", "must be at least openRadius, or a door closes on someone it just opened for")
	end
	if type(dc.checkSeconds) ~= "number" or dc.checkSeconds <= 0 or dc.checkSeconds > 1 then
		bad("checkSeconds", "must be above 0 and at most 1 - it is the delay before a door reacts")
	end
	if type(dc.swingSeconds) ~= "number" or dc.swingSeconds <= 0 then
		bad("swingSeconds", "must be positive")
	end
	if type(dc.openAngle) ~= "number" or dc.openAngle <= 0 or dc.openAngle > 180 then
		bad("openAngle", "must be above 0 and at most 180 degrees")
	end
end

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

	-- Every role needs at least one copy, or its items would never spawn
	-- in the hub at all - that's removing them, which this knob isn't for.
	for _, role in { "Attack", "Defence", "Utility" } do
		local copies = if type(pc.bagCopiesByRole) == "table" then pc.bagCopiesByRole[role] else nil
		if type(copies) ~= "number" or copies < 1 or copies % 1 ~= 0 then
			bad("bagCopiesByRole." .. role, "must be a whole number, at least 1")
		end
	end

	if type(pc.dummyAttackSeconds) ~= "number" or pc.dummyAttackSeconds < 2 then
		bad("dummyAttackSeconds", "must be at least 2 - any faster and a player on the rug is never not hit")
	end
	-- Empty is allowed: it switches dummies fighting back off. Whether each
	-- id names a real Aimed/Area item is checked in Validate.run, which
	-- has the power-up list.
	if type(pc.dummyAttackPowerUpIds) ~= "table" then
		bad("dummyAttackPowerUpIds", "must be a list of power-up ids (empty turns dummy attacks off)")
	end
	if type(pc.dummyTaskAttackPowerUpIds) ~= "table" then
		bad("dummyTaskAttackPowerUpIds", "must be a list of power-up ids (empty turns them off)")
	end
	-- Whether it names a real task is checked in Validate.run.
	if type(pc.taskId) ~= "string" or pc.taskId == "" then
		bad("taskId", "must be the id of the task the practice station runs")
	end
end

-- Only shape is checked here. Whether `mapId` names a real model needs
-- the Instance tree, so StudioTestService warns about that at runtime.
local function checkStudioTestConfig(st: StudioTestConfig, playerCount: number, issues: { Issue })
	local function bad(field: string, message: string)
		issue(issues, "GameConfig", "GameConfig.luau", "studioTest." .. field, message)
	end

	if st == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "studioTest", "the studioTest config block is missing entirely")
		return
	end

	if type(st.enabled) ~= "boolean" then
		bad("enabled", "must be a boolean")
	end
	if not isNonEmptyString(st.mapId) then
		bad("mapId", "must be a non-empty string")
	end
	if type(st.minHumans) ~= "number" or st.minHumans < 1 or st.minHumans > playerCount or st.minHumans % 1 ~= 0 then
		bad("minHumans", string.format("must be a whole number from 1 to playerCount (%s)", tostring(playerCount)))
	end
	if type(st.startDelaySeconds) ~= "number" or st.startDelaySeconds < 0 then
		bad("startDelaySeconds", "must be zero or more")
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
	elseif config.store ~= nil and config.powerUpInventorySlots < config.store.loadoutSlots then
		-- The loadout starts in these slots, and its stock is spent as it
		-- is granted - a loadout that can't fit would burn items.
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"powerUpInventorySlots",
			string.format("must be at least store.loadoutSlots (%d)", config.store.loadoutSlots)
		)
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
	if config.powerUpLockOnSlackStuds < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "powerUpLockOnSlackStuds", "must not be negative")
	end
	if config.powerUpLockOnSlackDegrees < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "powerUpLockOnSlackDegrees", "must not be negative")
	end
	local throw = config.powerUpThrow
	if type(throw) ~= "table" then
		issue(issues, "GameConfig", "GameConfig.luau", "powerUpThrow", "must be a table")
	else
		if throw.projectileSpeedStuds <= 0 then
			issue(issues, "GameConfig", "GameConfig.luau", "powerUpThrow.projectileSpeedStuds", "must be positive")
		end
		-- The effect lands when the projectile does, so this is also the
		-- longest a use can sit between being committed and applied.
		if throw.maxFlightSeconds <= 0 or throw.maxFlightSeconds > 1 then
			issue(issues, "GameConfig", "GameConfig.luau", "powerUpThrow.maxFlightSeconds", "must be > 0 and <= 1")
		end
		for _, key in { "arcHeightStuds", "shuntSpeed", "shuntUpSpeed", "recoilSpeed", "explosionRadiusStuds" } do
			local v = (throw :: any)[key]
			if type(v) ~= "number" or v < 0 then
				issue(issues, "GameConfig", "GameConfig.luau", "powerUpThrow." .. key, "must be a non-negative number")
			end
		end
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
	local stage = config.decisionStudioStage
	if stage == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "decisionStudioStage", "missing")
	else
		if stage.mapId == "" then
			issue(issues, "GameConfig", "GameConfig.luau", "decisionStudioStage.mapId", "must not be empty")
		end
		-- A race map spans a few hundred studs; closer than this and the
		-- set can land inside one.
		if stage.offsetStuds < 1000 then
			issue(issues, "GameConfig", "GameConfig.luau", "decisionStudioStage.offsetStuds", "must be at least 1000")
		end
	end

	checkNPCConfig(config.npc, issues)
	checkNPCBrainConfig(config.npcBrain, issues)

	checkLeaderboardConfig(config.leaderboard, issues)
	checkStoreConfig(config.store, issues)
	checkMatchmakingConfig(config.matchmaking, config.playerCount, issues)
	checkTeleportConfig(config.teleport, config.matchmaking, issues)
	checkVoteConfig(config.vote, config.matchmaking, config.teleport, issues)
	checkPracticeConfig(config.practice, issues)
	checkDoorConfig(config.doors, issues)
	checkStudioTestConfig(config.studioTest, config.playerCount, issues)

	local telemetry = config.telemetry
	if telemetry == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "telemetry", "the telemetry config block is missing entirely")
	else
		if type(telemetry.enabled) ~= "boolean" then
			issue(issues, "GameConfig", "GameConfig.luau", "telemetry.enabled", "must be a boolean")
		end
		if type(telemetry.studioEcho) ~= "boolean" then
			issue(issues, "GameConfig", "GameConfig.luau", "telemetry.studioEcho", "must be a boolean")
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

	local liveOps = config.liveOps
	if liveOps == nil then
		issue(issues, "GameConfig", "GameConfig.luau", "liveOps", "the liveOps config block is missing entirely")
	else
		if type(liveOps.enabled) ~= "boolean" then
			issue(issues, "GameConfig", "GameConfig.luau", "liveOps.enabled", "must be a boolean")
		end
		for _, field in { "dataStoreName", "envelopeKey", "auditKey" } do
			if not isNonEmptyString((liveOps :: any)[field]) then
				issue(issues, "GameConfig", "GameConfig.luau", "liveOps." .. field, "must be a non-empty string")
			end
		end
		if liveOps.envelopeKey == liveOps.auditKey then
			issue(issues, "GameConfig", "GameConfig.luau", "liveOps.auditKey", "must differ from envelopeKey")
		end
		-- One GetAsync per server per refresh: faster than this spends
		-- the DataStore read budget on polling.
		if liveOps.refreshSeconds < 15 then
			issue(issues, "GameConfig", "GameConfig.luau", "liveOps.refreshSeconds", "must be at least 15")
		end
		if liveOps.auditLogCap < 1 then
			issue(issues, "GameConfig", "GameConfig.luau", "liveOps.auditLogCap", "must be at least 1")
		end
		for i, userId in liveOps.adminUserIds do
			if type(userId) ~= "number" or userId <= 0 or userId ~= math.floor(userId) then
				issue(
					issues,
					"GameConfig",
					"GameConfig.luau",
					string.format("liveOps.adminUserIds[%d]", i),
					"must be a positive integer user id"
				)
			end
		end
		for i, pattern in liveOps.tunablePaths do
			local label = string.format("liveOps.tunablePaths[%d]", i)
			if not isNonEmptyString(pattern) then
				issue(issues, "GameConfig", "GameConfig.luau", label, "must be a non-empty string")
				continue
			end
			local segments = string.split(pattern, ".")
			if not inSet(segments[1], LIVE_OPS_ROOTS) then
				issue(issues, "GameConfig", "GameConfig.luau", label, pattern .. " must start with a known root")
			end
			if #segments < 2 then
				issue(issues, "GameConfig", "GameConfig.luau", label, pattern .. " must name something under the root")
			end
			for s, segment in segments do
				if segment == "" or (segment == "**" and s ~= #segments) then
					issue(
						issues,
						"GameConfig",
						"GameConfig.luau",
						label,
						pattern .. " has an empty segment or a non-trailing **"
					)
					break
				end
			end
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

	-- The early start can't come before the floor, and a new player's
	-- window can't be shorter than a veteran's.
	local studio = config.studioTimers
	if not (studio.introMinSeconds >= 0 and studio.introMinSeconds <= studio.introSeconds) then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"studioTimers.introMinSeconds",
			"must be between 0 and introSeconds"
		)
	end
	if studio.introNewPlayerSeconds < studio.introSeconds then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"studioTimers.introNewPlayerSeconds",
			"must be at least introSeconds"
		)
	end
	if studio.newPlayerFinales < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "studioTimers.newPlayerFinales", "must not be negative")
	end

	-- The central invariant the P1-4 task asked for by name, carried over
	-- from the retired bountyTiers (design-decisions.md Q1, applied
	-- 2026-10-02): sole stealer > lone sharer > all share > 0.
	-- payoff-table.md §1's asymmetric payoff shape is what keeps Steal
	-- and Share both live options. All three bases share one per-rung
	-- multiplier, so the ordering carries up the ladder.
	local winCurrency = config.winRewards.currency
	if
		not (
			winCurrency.soleStealer > winCurrency.loneSharer
			and winCurrency.loneSharer > winCurrency.allShare
			and winCurrency.allShare > 0
		)
	then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"winRewards.currency",
			string.format(
				"ordering broken: expected soleStealer (%s) > loneSharer (%s) > allShare (%s) > 0",
				tostring(winCurrency.soleStealer),
				tostring(winCurrency.loneSharer),
				tostring(winCurrency.allShare)
			)
		)
	end
	if winCurrency.perRungBonus < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "winRewards.currency.perRungBonus", "must not be negative")
	end

	local drop = config.winRewards.drop
	for _, field in { "baseChance", "maxChance" } do
		local value = (drop :: any)[field] :: number
		if value < 0 or value > 1 then
			issue(issues, "GameConfig", "GameConfig.luau", "winRewards.drop." .. field, "must be between 0 and 1")
		end
	end
	if drop.baseChance > drop.maxChance then
		issue(issues, "GameConfig", "GameConfig.luau", "winRewards.drop.baseChance", "must not exceed maxChance")
	end
	if drop.perRungChance < 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "winRewards.drop.perRungChance", "must not be negative")
	end
	local totalWeight = 0
	for _, rarity in { "Common", "Uncommon", "Rare" } do
		local entry = (drop.rarityWeights :: any)[rarity] :: DropRarityWeight
		local label = "winRewards.drop.rarityWeights." .. rarity
		if entry.weight < 0 or entry.perRungGrowth < 0 then
			issue(issues, "GameConfig", "GameConfig.luau", label, "weight and perRungGrowth must not be negative")
		end
		totalWeight += entry.weight
		if ((drop.duplicateCurrency :: any)[rarity] :: number) <= 0 then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				"winRewards.drop.duplicateCurrency." .. rarity,
				"must be positive - a duplicate cosmetic must still pay something"
			)
		end
	end
	if totalWeight <= 0 then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"winRewards.drop.rarityWeights",
			"at least one rarity needs a positive weight"
		)
	end
	if drop.powerUpAmount < 1 or drop.powerUpAmount % 1 ~= 0 then
		issue(
			issues,
			"GameConfig",
			"GameConfig.luau",
			"winRewards.drop.powerUpAmount",
			"must be a whole number, at least 1"
		)
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

	-- P7-5. Optional for the same reason. When it is passed, every
	-- ENABLED map must name a registered preset. A disabled map may still
	-- carry a placeholder name, because wave 2/3 maps are lit when they
	-- are built.
	lightingPresets: { { fileName: string, def: LightingPresetDef } }?,

	-- Rewards step 5. Optional for the same reason - none passed is "no
	-- seasons", and then every GamePass is left unchecked against them.
	seasons: { { fileName: string, def: SeasonDef } }?,
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

	-- A leaderboard band's limited item must be a real cosmetic. The
	-- field can only hold a cosmetic id, which is what keeps leaderboard
	-- prizes cosmetic only (Q8). Unchecked when no cosmetics registry is
	-- passed at all, the same as a store product's Cosmetic grant.
	local leaderboard = input.gameConfig.leaderboard
	if cosmetics ~= nil and leaderboard ~= nil and type(leaderboard.payouts) == "table" then
		local cosmeticIds: { [string]: true } = {}
		for _, entry in cosmetics do
			cosmeticIds[entry.def.id] = true
		end
		for kind, bands in leaderboard.payouts do
			if type(bands) ~= "table" then
				continue
			end
			for i, band in bands do
				local cosmeticId = band.cosmeticId
				if type(cosmeticId) == "string" and not cosmeticIds[cosmeticId] then
					issue(
						issues,
						"GameConfig",
						"GameConfig.luau",
						string.format("leaderboard.payouts.%s[%d].cosmeticId", tostring(kind), i),
						string.format("%q is not a cosmetic id", cosmeticId)
					)
				end
			end
		end
	end

	-- A training dummy can only throw something that lands on someone
	-- else: an Aimed item, or an Area one dropped at its feet.
	local practice = input.gameConfig.practice
	if practice ~= nil then
		local targetById: { [string]: string } = {}
		for _, entry in input.powerUps do
			targetById[entry.def.id] = entry.def.target
		end
		for _, field in { "dummyAttackPowerUpIds", "dummyTaskAttackPowerUpIds" } do
			local ids = (practice :: any)[field]
			if type(ids) ~= "table" then
				continue
			end
			for i, id in ids do
				local target = targetById[id]
				if target ~= "Aimed" and target ~= "Area" then
					issue(
						issues,
						"GameConfig",
						"GameConfig.luau",
						string.format("practice.%s[%d]", field, i),
						if target == nil
							then string.format("%q is not a power-up id", tostring(id))
							else string.format(
								"%q targets %s - a dummy can only throw Aimed or Area items",
								id,
								target
							)
					)
				end
			end
		end

		-- No task registry at all means nothing to check it against.
		if type(practice.taskId) == "string" and #input.tasks > 0 then
			local known = false
			for _, entry in input.tasks do
				known = known or entry.def.id == practice.taskId
			end
			if not known then
				issue(
					issues,
					"GameConfig",
					"GameConfig.luau",
					"practice.taskId",
					string.format("%q is not a task id", practice.taskId)
				)
			end
		end
	end

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

	local lightingPresets = input.lightingPresets
	if lightingPresets ~= nil then
		local knownPresets: { [string]: boolean } = {}
		for _, entry in lightingPresets do
			Validate.checkLightingPreset(entry.fileName, entry.def, issues)
			knownPresets[entry.def.id] = true
		end
		checkDuplicateIds("LightingPreset", lightingPresets :: any, issues)

		for _, entry in input.maps do
			if entry.def.enabled and not knownPresets[entry.def.lightingPreset] then
				issue(
					issues,
					"Map",
					entry.fileName,
					"lightingPreset",
					string.format("references unregistered lighting preset %q", tostring(entry.def.lightingPreset))
				)
			end
		end
	end

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
							-- referencing a not-yet-built cosmetic is
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

	-- ===== rewards step 5's season cross-checks =========================
	local seasons = input.seasons
	if seasons ~= nil then
		for _, entry in seasons do
			Validate.checkSeason(entry.fileName, entry.def, issues)
		end
		checkDuplicateIds("Season", seasons :: any, issues)

		-- Seasons replace each other, so no two windows overlap. Valid
		-- dates compare correctly as strings.
		local ordered = table.clone(seasons)
		table.sort(ordered, function(a, b)
			return tostring(a.def.startsOn) < tostring(b.def.startsOn)
		end)
		for i = 2, #ordered do
			local before, after = ordered[i - 1], ordered[i]
			if
				isCalendarDate(before.def.endsOn)
				and isCalendarDate(after.def.startsOn)
				and after.def.startsOn < before.def.endsOn
			then
				issue(
					issues,
					"Season",
					after.fileName,
					"startsOn",
					string.format(
						"overlaps %s, which ends %s - seasons run one at a time",
						before.fileName,
						before.def.endsOn
					)
				)
			end
		end

		-- Each season's pass is a real GamePass, no two seasons share
		-- one, and no GamePass is left without a season (it would sell
		-- nothing, since a pass grants nothing itself).
		if store ~= nil then
			local passByKey: { [string]: StoreItemDef } = {}
			for _, entry in store do
				if entry.def.kind == "GamePass" then
					passByKey[entry.def.key] = entry.def
				end
			end
			local seasonForPass: { [string]: string } = {}
			for _, entry in seasons do
				local key = entry.def.passKey
				if type(key) ~= "string" then
					continue
				end
				if passByKey[key] == nil then
					issue(
						issues,
						"Season",
						entry.fileName,
						"passKey",
						string.format("%q is not a GamePass in Config/Store/", key)
					)
				elseif seasonForPass[key] ~= nil then
					issue(
						issues,
						"Season",
						entry.fileName,
						"passKey",
						string.format(
							"%q already unlocks %s - a new season needs a new pass, because a pass is owned forever",
							key,
							seasonForPass[key]
						)
					)
				else
					seasonForPass[key] = entry.fileName
				end
			end
			for _, entry in store do
				if entry.def.kind == "GamePass" and seasonForPass[entry.def.key] == nil then
					issue(
						issues,
						"Store",
						entry.fileName,
						"key",
						"no season names this pass as its passKey, so it would unlock nothing"
					)
				end
			end
		end

		local powerUpById: { [string]: PowerUpDef } = {}
		for _, entry in input.powerUps do
			powerUpById[entry.def.id] = entry.def
		end
		local cosmeticById: { [string]: CosmeticDef }? = nil
		if cosmetics ~= nil then
			local byId: { [string]: CosmeticDef } = {}
			for _, entry in cosmetics do
				byId[entry.def.id] = entry.def
			end
			cosmeticById = byId
		end

		-- Where else a cosmetic is handed out, for "track-only forever".
		local elsewhere: { [string]: string } = {}
		if store ~= nil then
			for _, entry in store do
				if type(entry.def.grants) == "table" then
					for _, grant in entry.def.grants do
						if grant.kind == "Cosmetic" and type(grant.cosmeticId) == "string" then
							elsewhere[grant.cosmeticId] = "sold by " .. entry.fileName
						end
					end
				end
			end
		end
		if leaderboard ~= nil and type(leaderboard.payouts) == "table" then
			for kind, bands in leaderboard.payouts do
				if type(bands) == "table" then
					for _, band in bands do
						if type(band.cosmeticId) == "string" then
							elsewhere[band.cosmeticId] = string.format("paid by the %s leaderboard", tostring(kind))
						end
					end
				end
			end
		end

		for _, entry in seasons do
			for _, trackName in { "free", "premium" } do
				local track = (entry.def :: any)[trackName]
				if type(track) ~= "table" then
					continue
				end
				for index, item in track do
					local grant = if type(item) == "table" then item.grant else nil
					if type(grant) ~= "table" then
						continue
					end
					local field = string.format("%s[%d].grant", trackName, index)

					if grant.kind == "PowerUpStock" then
						local powerUp = powerUpById[grant.powerUpId or ""]
						if powerUp == nil then
							issue(
								issues,
								"Season",
								entry.fileName,
								field,
								string.format("references unregistered power-up id %q", tostring(grant.powerUpId))
							)
						elseif not (powerUp.acquisition.freelyEarnable and powerUp.acquisition.loadoutEligible) then
							-- Q8: a power-up on a track (premium is paid
							-- for) must also be earnable free, and stock
							-- only means anything if it fits a loadout.
							issue(
								issues,
								"Season",
								entry.fileName,
								field,
								string.format(
									"power-up %q must be freelyEarnable and loadoutEligible to sit on a track (design-decisions.md Q8)",
									powerUp.id
								)
							)
						end
					elseif grant.kind == "Cosmetic" and cosmeticById ~= nil and type(grant.cosmeticId) == "string" then
						local id = grant.cosmeticId :: string
						local cosmetic = cosmeticById[id]
						if cosmetic == nil then
							issue(
								issues,
								"Season",
								entry.fileName,
								field,
								string.format("references unregistered cosmetic id %q", id)
							)
							continue
						end
						-- Track-only forever (Q1, applied 2026-10-02).
						local where = elsewhere[id]
						if cosmetic.winDrop == true then
							where = "a win drop (winDrop = true)"
						end
						if where ~= nil then
							issue(
								issues,
								"Season",
								entry.fileName,
								field,
								string.format("cosmetic %q is also %s - a track item is track-only forever", id, where)
							)
						end
						elsewhere[id] = string.format("on %s's %s track", entry.fileName, trackName)
						if entry.def.enabled == true and not cosmetic.enabled then
							issue(
								issues,
								"Season",
								entry.fileName,
								field,
								string.format(
									"cosmetic %q is not enabled - it has no Roblox asset yet, so this ENABLED season would grant something invisible",
									id
								)
							)
						end
					end
				end
			end
		end
	end

	return issues
end

return Validate
