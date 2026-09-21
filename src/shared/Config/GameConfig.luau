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
}

return GameConfig
