--!strict
-- Data-driven effect definitions StatusEffects.luau resolves (P2-8):
-- "Effects are data-driven: id, stat modified, operation, magnitude,
-- duration, stacking rule... priority, and a category" (the task's own
-- requirement, verbatim) - this is that data, one entry per effect.
--
-- SCOPE: sprint-boost, slow-field, freeze, push-trip and blind are
-- character-stat modifiers (plus one shared soft-control fallback, not
-- tied to any single power-up id). second-wind, phase-step and overclock
-- are WARDS - resolver stats StatusEffects and PowerUpService consult
-- rather than a Humanoid property (second-wind's entry is only its
-- post-cleanse immunity window; the cleanse itself is a bespoke action
-- in StatusEffects.applyEffectFor). The two task items stay out:
--
--   - task-insight: modifies a TASK CHALLENGE'S rolled difficulty
--     (TaskHandlerService's job, P2-5), not a character stat.
--   - task-scramble: an instant, one-off task-reroll with its own 15s
--     cumulative-EXPOSURE cap (powerups.md rule 5, measured in accrued
--     time cost, not disable time) - not a duration-bearing character-
--     stat effect at all, and a different cap shape than HardControl's.
--
-- Both live with the system that owns what they change: StatusEffects.
-- applyEffectFor hands them to TaskHandlerService (grantInsight,
-- scramble) rather than resolving a def from this table.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StatusEffectResolver = require(ReplicatedStorage.Shared.StatusEffectResolver)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)

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
		durationSeconds = 3.5,
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
		durationSeconds = 2,
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

	-- Second Wind's 2.5s post-cleanse immunity. The cleanse itself is a
	-- bespoke action in StatusEffects; this is the window it leaves.
	["second-wind"] = {
		id = "second-wind",
		kind = "Buff",
		stat = "DebuffImmunity",
		operation = "Override",
		magnitude = 1,
		durationSeconds = 2.5,
		stackingRule = "Refresh",
		stackCap = nil,
		priority = 0,
		category = "Ward",
		hardControlSoftFallbackId = nil,
	},

	["phase-step"] = {
		id = "phase-step",
		kind = "Buff",
		stat = "Untargetable",
		operation = "Override",
		magnitude = 1,
		durationSeconds = 3,
		stackingRule = "Refresh",
		stackCap = nil,
		priority = 0,
		category = "Ward",
		hardControlSoftFallbackId = nil,
	},

	overclock = {
		id = "overclock",
		kind = "Buff",
		stat = "CooldownRate",
		operation = "Multiply",
		magnitude = 0.5, -- powerups.md: "halves the cooldown on the player's other equipped power-ups"
		durationSeconds = 10,
		stackingRule = "Refresh", -- two Overclocks refresh, never quarter a cooldown
		stackCap = nil,
		priority = 0,
		category = "Utility",
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

-- The power-up config is the one source of every duration: a def named
-- after a power-up id takes that item's durationSeconds, so retuning
-- an item is still a one-file change (Ground Rule 2). The soft fallback
-- has no power-up of its own and keeps the number above.
for _, entry in PowerUps do
	local def = defs[entry.def.id]
	if def ~= nil then
		def.durationSeconds = entry.def.durationSeconds
	end
end

return defs
