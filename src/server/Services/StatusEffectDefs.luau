--!strict
-- Data-driven effect definitions StatusEffects.luau resolves (P2-8):
-- "Effects are data-driven: id, stat modified, operation, magnitude,
-- duration, stacking rule... priority, and a category" (the task's own
-- requirement, verbatim) - this is that data, one entry per effect.
--
-- SCOPE: only the subset of powerups.md's 10 items that are genuinely
-- continuous CHARACTER-STAT modifiers get a real entry here - sprint-
-- boost, slow-field, freeze, push-trip, blind (plus one shared soft-
-- control fallback, not tied to any single power-up id). The other five
-- aren't character-stat effects at all, and forcing them through this
-- resolver would be the wrong shape for what they actually do:
--
--   - second-wind: a cleanse of active debuffs, not a stat modifier -
--     StatusEffects.luau handles it as a small bespoke action against
--     its own active-effect list (see applyEffectFor's own comment)
--     rather than as an EffectDef, since a "remove everything else"
--     action doesn't fit "one more row of stat data" at all.
--   - task-insight: modifies a TASK CHALLENGE'S rolled difficulty
--     (TaskHandlerService's job, P2-5), not a character stat - wiring
--     that up needs TaskHandlerService to query StatusEffects, which is
--     real cross-service integration this task doesn't do.
--   - phase-step: an "untargetable" flag PowerUpService's own
--     resolveTarget (P2-7) would need to consult - same kind of gap.
--   - overclock: modifies COOLDOWN duration, a PowerUpService concept
--     (P2-7's `cooldownSeconds`/`lastUsedAt`), not a character stat.
--   - task-scramble: an instant, one-off task-reroll with its own 15s
--     cumulative-EXPOSURE cap (powerups.md rule 5, measured in accrued
--     time cost, not disable time) - not a duration-bearing character-
--     stat effect at all, and a different cap shape than HardControl's.
--
-- Each of these belongs with whichever system actually owns the thing
-- it modifies, once that integration is built - not shoehorned in here
-- just to claim coverage of all 10.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StatusEffectResolver = require(ReplicatedStorage.Shared.StatusEffectResolver)

-- Freeze and Push/Trip share ONE soft-control fallback rather than each
-- getting a near-identical duplicate - both downgrade to the same
-- "Slow-Field-equivalent soft effect" powerups.md rule 3 describes,
-- verbatim, so there's nothing for a second copy to say differently.
local HARD_CONTROL_SOFT_FALLBACK_ID = "hard-control-soft-fallback"

local defs: { [string]: StatusEffectResolver.EffectDef } = {
	["sprint-boost"] = {
		id = "sprint-boost",
		kind = "Buff",
		stat = "MoveSpeed",
		operation = "Multiply",
		magnitude = 1.35, -- powerups.md: +35% move speed
		durationSeconds = 6,
		stackingRule = "Refresh", -- "doesn't stack with itself (reapplying refreshes duration, not magnitude)"
		stackCap = nil,
		priority = 0,
		category = "Movement",
		hardControlSoftFallbackId = nil,
	},

	["slow-field"] = {
		id = "slow-field",
		kind = "Debuff",
		stat = "MoveSpeed",
		operation = "Multiply",
		magnitude = 0.6, -- powerups.md: -40% move speed
		durationSeconds = 5,
		-- Multiple simultaneous zones (same or different casters) DO
		-- stack, multiplicatively - the resolver's own -70% MoveSpeed
		-- floor (powerups.md rule 4) is what actually bounds the
		-- combined result, not this cap; 6 is generous headroom, never
		-- expected to bind in a 6-player round.
		stackingRule = "StackWithCap",
		stackCap = 6,
		priority = 0,
		category = "Movement",
		hardControlSoftFallbackId = nil,
	},

	freeze = {
		id = "freeze",
		kind = "Debuff",
		stat = "ControlLock",
		operation = "Override",
		magnitude = 1,
		durationSeconds = 2.5,
		stackingRule = "Ignore", -- "does not extend past its own duration if reapplied"
		stackCap = nil,
		priority = 100, -- resolves after every Movement-category effect, so a lock always wins over a mere slow
		category = "HardControl",
		hardControlSoftFallbackId = HARD_CONTROL_SOFT_FALLBACK_ID,
	},

	["push-trip"] = {
		id = "push-trip",
		kind = "Debuff",
		stat = "ControlLock",
		operation = "Override",
		magnitude = 1,
		durationSeconds = 1,
		stackingRule = "Ignore",
		stackCap = nil,
		priority = 100,
		category = "HardControl",
		hardControlSoftFallbackId = HARD_CONTROL_SOFT_FALLBACK_ID,
	},

	blind = {
		id = "blind",
		kind = "Debuff",
		stat = "Vision",
		operation = "Override",
		magnitude = 1, -- fully obscured; "obscures screen, no movement lock" (powerups.md) is exactly ControlLock staying untouched by this def
		durationSeconds = 4,
		stackingRule = "Refresh", -- "reapplying refreshes duration only, never increases the visual obstruction magnitude"
		stackCap = nil,
		priority = 0,
		category = "Vision",
		hardControlSoftFallbackId = nil,
	},

	[HARD_CONTROL_SOFT_FALLBACK_ID] = {
		id = HARD_CONTROL_SOFT_FALLBACK_ID,
		kind = "Debuff",
		stat = "MoveSpeed",
		operation = "Multiply",
		magnitude = 0.6, -- "Slow-Field-equivalent" (powerups.md rule 3, verbatim) - same magnitude as slow-field itself
		durationSeconds = 5,
		stackingRule = "Refresh",
		stackCap = nil,
		priority = 0,
		category = "Movement",
		hardControlSoftFallbackId = nil,
	},
}

return defs
