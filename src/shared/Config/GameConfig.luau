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

	-- payoff-table.md §3's table, verbatim.
	bountyTiers = {
		{ tier = 1, minStreak = 1, soleStealerVU = 20, loneSharerVU = 10, allShareVU = 5 },
		{ tier = 2, minStreak = 3, soleStealerVU = 24, loneSharerVU = 12, allShareVU = 6 },
		{ tier = 3, minStreak = 6, soleStealerVU = 28, loneSharerVU = 14, allShareVU = 7 },
		{ tier = 4, minStreak = 10, soleStealerVU = 32, loneSharerVU = 16, allShareVU = 8 },
		{ tier = 5, minStreak = 15, soleStealerVU = 36, loneSharerVU = 18, allShareVU = 9 },
	},
}

return GameConfig
