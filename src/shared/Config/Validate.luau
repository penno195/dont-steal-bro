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
export type TitleDef = {
	id: string,
	displayName: string,
	colorHex: string, -- "#rrggbb" - a plain string, not Color3, so this file stays Lune-pure; a client controller converts it
	minStreak: number,
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

	-- P3-6: every probability and timing the NPC brain uses, "exposed
	-- for tuning without code changes" (the task's own requirement).
	-- The per-personality steal probabilities are NOT here - they live
	-- on each NPCPersonalityDef, so adding a personality stays a
	-- one-file change (Ground Rule 2).
	npcBrain: NPCBrainConfig,
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

	checkDuplicateIds("Map", input.maps :: any, issues)
	checkDuplicateIds("Task", input.tasks :: any, issues)
	checkDuplicateIds("PowerUp", input.powerUps :: any, issues)
	checkDuplicateIds("Title", input.titles :: any, issues)
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

	return issues
end

return Validate
