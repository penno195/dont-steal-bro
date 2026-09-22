--!strict
-- The root config: round/player counts, Decision Studio timers, and
-- bounty tiers. See Validate.luau for field provenance - most of these
-- numbers are locked design decisions, not guesses; the ones that aren't
-- are marked PLACEHOLDER, the same stance perf-budget.md and threat-
-- model.md take on their own unverified figures. ConfigValidator
-- (src/server/Services/ConfigValidator.luau) asserts this at boot -
-- edit a number here with confidence that a broken one fails loudly
-- instead of shipping quietly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local GameConfig: Validate.GameConfig = {
	playerCount = 6, -- gdd.md
	qualifierCount = 3, -- gdd.md
	tasksPerPlayer = 6, -- PLACEHOLDER: no locked value in docs/ yet
	qualificationFloorPercent = 0.5, -- design-decisions.md Q2
	streakLossWeight = 2, -- payoff-table.md §3's c0; Closs(n) = 2n
	npcSeatStreakCreditThreshold = 3, -- PLACEHOLDER: threat-model.md §8, playtest-tuned
	raceDurationSeconds = 300, -- PLACEHOLDER: no locked value in docs/ yet

	-- architecture.md §6's network trace, verbatim.
	studioTimers = {
		introSeconds = 5,
		negotiateSeconds = 45,
		chooseSeconds = 15,
		revealDelaySeconds = 1,
	},

	-- RoundService's (P2-1) own state durations. All PLACEHOLDER - no
	-- locked value in docs/ yet, same stance as raceDurationSeconds.
	roundTimers = {
		loadingSeconds = 5,
		introSeconds = 5,
		qualifiedSeconds = 3,
		resultsSeconds = 8,
		cleanupSeconds = 5,
	},

	-- payoff-table.md §3's table, with one fix found integrating P3-2:
	-- the doc's own "Tier 1: streak range 1-2" leaves streak 0 - a
	-- player's very first-ever qualification, before they've won
	-- anything - uncovered by every tier. ProfileLogic.resolveBountyTier
	-- (P1-5) errors loudly on an uncovered streak by design, which is
	-- correct behavior for a genuinely misconfigured table, but streak 0
	-- reaching the Decision Studio is not a misconfiguration - it's the
	-- ordinary first-time-winner case. Tier 1's floor is lowered to 0
	-- here (payoff-table.md itself should be updated to "0-2" to match).
	bountyTiers = {
		{ tier = 1, minStreak = 0, soleStealerVU = 20, loneSharerVU = 10, allShareVU = 5 },
		{ tier = 2, minStreak = 3, soleStealerVU = 24, loneSharerVU = 12, allShareVU = 6 },
		{ tier = 3, minStreak = 6, soleStealerVU = 28, loneSharerVU = 14, allShareVU = 7 },
		{ tier = 4, minStreak = 10, soleStealerVU = 32, loneSharerVU = 16, allShareVU = 8 },
		{ tier = 5, minStreak = 15, soleStealerVU = 36, loneSharerVU = 18, allShareVU = 9 },
	},

	-- P2-7: PowerUpService's own field-pickup inventory, distinct from
	-- powerups.md's separate pre-game Loadout selection. All PLACEHOLDER
	-- - no locked value in docs/ yet, same stance as raceDurationSeconds.
	powerUpInventorySlots = 1, -- powerups.md: "one inventory slot per player by default"
	powerUpFullInventoryPolicy = "Refuse", -- picking up while full is refused (the world pickup stays available) rather than swapping the held item
	powerUpUseRangeStuds = 24, -- max range for an Aimed/Nearest target
	powerUpTargetConeDegrees = 90, -- full cone width for smart-targeting an Aimed power-up with no explicit target hint

	-- Base respawn seconds per rarity tier - a MapDef may multiply these
	-- (Validate.PowerUpRarityWeights' own doc comment). Ordered so a
	-- rarer tier respawns more slowly by default, without any map needing
	-- to override anything.
	powerUpRotationTimers = {
		Common = 20,
		Uncommon = 40,
		Rare = 75,
	},

	-- P2-9: MovementWatch's thresholds. All PLACEHOLDER - no real logged
	-- data exists yet to tune against; docs/movement-watch-notes.md
	-- covers how to read the first week of logs before touching these.
	movementSampleIntervalSeconds = 0.5,
	movementSpeedTolerance = 1.25, -- 25% grace above the resolved max
	movementViolationDecayPerSecond = 0.5,
	movementViolationLogThreshold = 1.0,
	movementViolationFlagThreshold = 3.0,
	movementViolationActThreshold = 6.0, -- unused this version - LOG ONLY

	-- P3-2: design-decisions.md Q4, verbatim ("the leaver's substituted
	-- choice for the other two is Share") - locked, not a placeholder.
	decisionStudioDefaultChoice = "Share",

	-- P3-3: PLACEHOLDER - no locked value in docs/ yet. P3-4's podium
	-- layout is expected to fit comfortably inside this.
	decisionStudioChatRangeStuds = 30,

	-- P3-5: NPC fill. Every knob the bots have, in one block, so tuning
	-- them is a config edit and never a service edit (Ground Rule 2).
	npc = {
		-- architecture.md §4, verbatim ("a ~10s grace window so slow
		-- teleports aren't replaced by bots") - not a placeholder.
		fillGraceSeconds = 10,

		-- architecture.md §4 gives the 5-10 Hz band; 8 is the midpoint
		-- choice within it. docs/npc-notes.md derives the per-server
		-- cost from this exact number - change both together.
		tickHz = 8,

		-- PLACEHOLDER: the three profiles are architecture.md §4's
		-- (Casual/Average/Sweaty), but every number attached to them is
		-- a guess until there is real player telemetry to fit against -
		-- which is the whole point of the doc's "tuned from real player
		-- telemetry" note. The weights deliberately centre on Average.
		skillProfiles = {
			{ id = "Casual", weight = 0.3, durationScale = 1.35, moveSpeedScale = 0.9 },
			{ id = "Average", weight = 0.5, durationScale = 1.1, moveSpeedScale = 1.0 },
			{ id = "Sweaty", weight = 0.2, durationScale = 0.9, moveSpeedScale = 1.05 },
		},

		-- 1.0 = architecture.md §4's rule exactly: never faster than the
		-- median human. Locked by that rule, not a placeholder - raising
		-- it makes bots softer, lowering it below 1.0 fails validation.
		fairnessFloorScale = 1.0,

		-- PLACEHOLDER. 3 completions is enough for a median to stop
		-- swinging on a single outlier, and low enough to switch over
		-- from the catalogue-range fallback partway through a race.
		medianSampleMinimum = 3,

		-- PLACEHOLDER. Roughly a character's own width plus the stud or
		-- two of overshoot a Humanoid:MoveTo finish leaves behind.
		stationArrivalRadiusStuds = 6,

		-- 2 = the smallest value that stops every bot walking an
		-- identical route (see NPCLogic.chooseNextStation).
		nextStationTopK = 2,

		-- PLACEHOLDER, both. The stuck window has to be longer than a
		-- normal Humanoid stutter over a ramp or a doorway, or a bot
		-- repaths constantly for no reason - which is the single
		-- biggest NPC cost on the server (docs/npc-notes.md).
		repathAfterStuckSeconds = 1.5,
		maxRepathsPerStation = 5,
	},
}

return GameConfig
