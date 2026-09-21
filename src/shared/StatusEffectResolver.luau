--!strict
-- Pure logic for StatusEffects (P2-8): the stat resolver, per-effect
-- stacking rules, and the central hard-control anti-frustration gate
-- (immunity window, diminishing returns, the rolling per-round disable
-- cap). Self-contained on purpose - no requires, no Roblox API calls
-- anywhere - same shape as every other *Logic.luau/Qualification.luau
-- module in this repo, for the same reason: Ground Rule 4 wants exactly
-- this kind of logic (a resolver, stacking, ranking) unit-tested
-- headlessly under Lune (tests/StatusEffectResolver.spec.luau).
-- StatusEffects.luau is the thin Roblox-touching wrapper that supplies
-- real Players/Humanoids/timers and applies what this module decides.
--
-- WHY A STAT IS NEVER WRITTEN DIRECTLY BY ANYTHING BUT THE RESOLVER (the
-- task's own requirement): every stat StatusEffects owns - move speed,
-- jump, control lock, vision, task speed - starts at a fixed baseline
-- and is walked through every currently-active effect touching it, in
-- one deterministic order, right here in `resolve`. A power-up handler
-- (or anything else) that wants to change a stat has no other path in -
-- it can only ever ADD an effect to the active list and let this
-- function recompute the whole result from scratch, which is what makes
-- "what's my current speed and why" always answerable from data instead
-- of from whichever code path happened to touch it last.

local StatusEffectResolver = {}

export type Stat = "MoveSpeed" | "JumpPower" | "ControlLock" | "Vision" | "TaskSpeed"
export type StatOperation = "Add" | "Multiply" | "Override"
export type StackingRule = "Refresh" | "StackWithCap" | "Ignore" | "Replace"

-- One row of data per effect - "id, stat modified, operation, magnitude,
-- duration, stacking rule, priority, and a category" (the task's own
-- list, verbatim). `stackCap` only matters when stackingRule is
-- "StackWithCap" - the max number of simultaneous instances of THIS
-- effect id a player can have at once (see applyStacking below).
-- `hardControlSoftFallbackId`, only meaningful when category ==
-- "HardControl", names the softer effect id StatusEffects substitutes
-- in once the rolling disable cap is hit (powerups.md rule 3: "...is
-- automatically downgraded to a Slow-Field-equivalent soft effect
-- instead of applying").
export type EffectDef = {
	id: string,
	kind: "Buff" | "Debuff", -- powerups.md's own split; StatusEffects.luau's Second Wind cleanse uses this to know what counts as a debuff to strip - `category` alone can't (Movement holds both a buff, Sprint Boost, and a debuff, Slow Field)
	stat: Stat,
	operation: StatOperation,
	magnitude: number,
	durationSeconds: number,
	stackingRule: StackingRule,
	stackCap: number?,
	priority: number,
	category: string,
	hardControlSoftFallbackId: string?,
}

export type ActiveEffect = {
	instanceId: string, -- unique per APPLICATION, not per effect id - see applyStacking
	def: EffectDef,
	appliedAt: number,
	expiresAt: number,
	casterId: number?,
}

export type ResolvedStats = {
	MoveSpeed: number, -- multiplier, 1.0 = baseline
	JumpPower: number, -- multiplier, 1.0 = baseline
	ControlLock: boolean,
	Vision: number, -- 0 = clear, 1 = fully obscured
	TaskSpeed: number, -- multiplier, 1.0 = baseline
}

-- A plain record, not a `{[Stat]: number}` index-signature table -
-- Luau's type checker won't allow dot-access (`running.MoveSpeed`) on an
-- index-signature type even with a literal-union key, and every
-- reasonable rewrite of the running-totals arithmetic below ends up
-- wanting dot-access somewhere. `getStat`/`setStat` are the two places
-- that bridge a DYNAMIC `Stat` value (from effect data) to this record's
-- fixed named fields, so the awkwardness stays contained to just those
-- two small functions instead of leaking into `resolve` itself.
type RunningStats = {
	MoveSpeed: number,
	JumpPower: number,
	ControlLock: number,
	Vision: number,
	TaskSpeed: number,
}

local function newBaseline(): RunningStats
	return { MoveSpeed = 1.0, JumpPower = 1.0, ControlLock = 0, Vision = 0, TaskSpeed = 1.0 }
end

local function getStat(stats: RunningStats, stat: Stat): number
	if stat == "MoveSpeed" then
		return stats.MoveSpeed
	elseif stat == "JumpPower" then
		return stats.JumpPower
	elseif stat == "ControlLock" then
		return stats.ControlLock
	elseif stat == "Vision" then
		return stats.Vision
	else
		return stats.TaskSpeed
	end
end

local function setStat(stats: RunningStats, stat: Stat, value: number)
	if stat == "MoveSpeed" then
		stats.MoveSpeed = value
	elseif stat == "JumpPower" then
		stats.JumpPower = value
	elseif stat == "ControlLock" then
		stats.ControlLock = value
	elseif stat == "Vision" then
		stats.Vision = value
	else
		stats.TaskSpeed = value
	end
end

-- powerups.md rule 4's -70% combined Slow Field floor, applied as a
-- stat-level clamp rather than special-cased to one effect id - ANY
-- combination of Movement-affecting effects is bounded here, the same
-- way a real player can never be slowed to literally 0 regardless of how
-- many zones/attackers overlap. The only stat that currently needs a
-- clamp; add more `if` branches here if a future effect needs another.
local MOVE_SPEED_FLOOR = 0.3

-- Pure: which of `effects` are still active at `now`. An effect
-- expiring exactly AT `now` counts as already gone - "effects are
-- cleared correctly on... round end... with no orphaned modifiers" (the
-- task's own requirement) needs a defined answer for the same-frame
-- boundary case, not an off-by-one left to chance.
function StatusEffectResolver.activeAt(effects: { ActiveEffect }, now: number): { ActiveEffect }
	local active: { ActiveEffect } = {}
	for _, effect in effects do
		if effect.expiresAt > now then
			table.insert(active, effect)
		end
	end
	return active
end

-- Pure: final stats from every ACTIVE effect (caller is expected to have
-- already filtered with activeAt - this function doesn't re-check
-- expiry itself, so its own tests can exercise "resolve at this instant"
-- without needing a `now` argument too). Deterministic order: ascending
-- priority, then ascending instanceId as the tie-break - two effects
-- with equal priority always resolve in the same order regardless of
-- which one happened to be inserted first.
function StatusEffectResolver.resolve(activeEffects: { ActiveEffect }): ResolvedStats
	local sorted = table.clone(activeEffects)
	table.sort(sorted, function(a, b)
		if a.def.priority ~= b.def.priority then
			return a.def.priority < b.def.priority
		end
		return a.instanceId < b.instanceId
	end)

	local running = newBaseline()

	for _, effect in sorted do
		-- Explicit declared type, not inferred - confirmed locally that
		-- without it, `stat` loses its literal-union precision somewhere
		-- across this loop and getStat/setStat's calls below fail to
		-- type-check against their own `Stat`-typed parameter. Same class
		-- of gap RoundService.luau's own header comment documents for
		-- RoundStates.ALL - a declared local type clears it there too.
		local stat: Stat = effect.def.stat
		local current = getStat(running, stat)
		local magnitude = effect.def.magnitude

		if effect.def.operation == "Add" then
			setStat(running, stat, current + magnitude)
		elseif effect.def.operation == "Multiply" then
			setStat(running, stat, current * magnitude)
		else -- "Override"
			setStat(running, stat, magnitude)
		end
	end

	if running.MoveSpeed < MOVE_SPEED_FLOOR then
		running.MoveSpeed = MOVE_SPEED_FLOOR
	end

	return {
		MoveSpeed = running.MoveSpeed,
		JumpPower = running.JumpPower,
		ControlLock = running.ControlLock > 0,
		Vision = running.Vision,
		TaskSpeed = running.TaskSpeed,
	}
end

-- Pure: folds `newEffect` into `existing` per its own def.stackingRule,
-- against only the OTHER active effects sharing its exact id (Replace is
-- the one exception - see below). Returns the new full active-effect
-- list; never mutates `existing`.
function StatusEffectResolver.applyStacking(existing: { ActiveEffect }, newEffect: ActiveEffect): { ActiveEffect }
	local sameId: { ActiveEffect } = {}
	local others: { ActiveEffect } = {}
	for _, effect in existing do
		if effect.def.id == newEffect.def.id then
			table.insert(sameId, effect)
		else
			table.insert(others, effect)
		end
	end

	local rule = newEffect.def.stackingRule

	if rule == "Ignore" then
		-- Already active - "does not extend past its own duration if
		-- reapplied" (powerups.md, Freeze). The new application is
		-- wasted outright when one is already up; otherwise it's the
		-- first, so it applies normally.
		if #sameId > 0 then
			return existing
		end
		local result = table.clone(others)
		table.insert(result, newEffect)
		return result
	elseif rule == "Refresh" then
		-- At most one instance of this id at a time - the new
		-- application always replaces whatever's there, resetting
		-- duration ("reapplying refreshes duration, not magnitude" -
		-- powerups.md, Sprint Boost; magnitude is static per-def anyway,
		-- so there's nothing else for a refresh to change).
		local result = table.clone(others)
		table.insert(result, newEffect)
		return result
	elseif rule == "Replace" then
		-- The new effect replaces EVERY existing effect sharing its
		-- CATEGORY, not just its own id - for a category where only one
		-- effect should ever be "the current one" regardless of which
		-- specific id is landing.
		local result: { ActiveEffect } = {}
		for _, effect in others do
			if effect.def.category ~= newEffect.def.category then
				table.insert(result, effect)
			end
		end
		table.insert(result, newEffect)
		return result
	else -- "StackWithCap"
		local cap = newEffect.def.stackCap or math.huge
		local combined = table.clone(sameId)
		table.insert(combined, newEffect)

		if #combined > cap then
			-- Evict the OLDEST beyond the cap - a newly-cast instance
			-- should never be the one silently dropped in favor of one
			-- about to expire anyway.
			table.sort(combined, function(a, b)
				return a.appliedAt < b.appliedAt
			end)
			while #combined > cap do
				table.remove(combined, 1)
			end
		end

		local result = table.clone(others)
		for _, effect in combined do
			table.insert(result, effect)
		end
		return result
	end
end

-- ===== the central hard-control anti-frustration gate ====================
--
-- powerups.md's three HardControl-only rules, enforced here rather than
-- inside any individual effect - "no individual power-up can bypass it"
-- (the task's own requirement) is only true if this is the ONE place a
-- HardControl application is ever decided, which is exactly why
-- StatusEffects.luau routes every HardControl-category application
-- through this function before ever touching the active-effect list.

export type HardControlHistory = {
	lastEndedAt: number?, -- when this player's most recent HardControl effect last expired
	recentApplications: { number }, -- appliedAt timestamps within the diminishing-returns window; caller prunes old entries via the returned decision (see below)
	totalDisabledSeconds: number, -- cumulative, this round - not a sliding window, despite powerups.md's section heading; the rule body is explicit that it's a per-round total
}

export type HardControlDecision = {
	allowed: boolean, -- false only when blocked outright by the post-effect immunity window
	effectiveDurationSeconds: number, -- the duration to actually apply - shrunk by diminishing returns, floored at 0.5s; 0 when downgraded
	downgradedToSoft: boolean, -- true once the rolling per-round cap is reached - apply the effect's hardControlSoftFallbackId instead, not this one
	updatedHistory: HardControlHistory, -- the caller's new history to store - this function never mutates the one it's given
}

local IMMUNITY_WINDOW_SECONDS = 3 -- powerups.md rule 1
local DIMINISHING_RETURNS_WINDOW_SECONDS = 20 -- powerups.md rule 2
local DIMINISHING_RETURNS_FLOOR_SECONDS = 0.5 -- powerups.md rule 2
local ROUND_DISABLE_CAP_SECONDS = 15 -- powerups.md rule 3

-- Pure: decides whether/how a NEW HardControl-category application
-- against `history` should land, at time `now`, for an effect whose
-- undiminished duration is `baseDurationSeconds`. Constants above are
-- powerups.md's own locked numbers, not configurable per call - unlike
-- GameConfig's PLACEHOLDER fields, these are real design decisions
-- already reviewed and written down, so they're not parameters a caller
-- could plausibly want to vary.
function StatusEffectResolver.decideHardControlApplication(
	history: HardControlHistory,
	now: number,
	baseDurationSeconds: number
): HardControlDecision
	-- Rule 1: post-effect immunity.
	if history.lastEndedAt ~= nil and (now - history.lastEndedAt) < IMMUNITY_WINDOW_SECONDS then
		return {
			allowed = false,
			effectiveDurationSeconds = 0,
			downgradedToSoft = false,
			updatedHistory = history,
		}
	end

	-- Rule 2: diminishing returns, counted over applications still
	-- inside the 20s window as of `now`.
	local recentInWindow: { number } = {}
	for _, appliedAt in history.recentApplications do
		if now - appliedAt < DIMINISHING_RETURNS_WINDOW_SECONDS then
			table.insert(recentInWindow, appliedAt)
		end
	end

	local applicationIndex = #recentInWindow -- 0 = this is the 1st in the window, 1 = the 2nd, 2+ = the 3rd or later
	local multiplier = if applicationIndex <= 0 then 1.0 elseif applicationIndex == 1 then 0.5 else 0.25
	local effectiveDuration = math.max(DIMINISHING_RETURNS_FLOOR_SECONDS, baseDurationSeconds * multiplier)

	table.insert(recentInWindow, now)

	-- Rule 3: rolling (cumulative, per-round) disable cap.
	local downgradedToSoft = history.totalDisabledSeconds >= ROUND_DISABLE_CAP_SECONDS
	local newTotal = history.totalDisabledSeconds
	if not downgradedToSoft then
		newTotal += effectiveDuration
	end

	return {
		allowed = true,
		effectiveDurationSeconds = if downgradedToSoft then 0 else effectiveDuration,
		downgradedToSoft = downgradedToSoft,
		updatedHistory = {
			lastEndedAt = history.lastEndedAt,
			recentApplications = recentInWindow,
			totalDisabledSeconds = newTotal,
		},
	}
end

-- Pure: call once a HardControl effect actually ends (its expiresAt is
-- reached) to record the moment the immunity window starts counting
-- from. Never called for a downgraded (soft-fallback) application, since
-- that was never really a HardControl effect in the first place.
function StatusEffectResolver.recordHardControlEnded(history: HardControlHistory, endedAt: number): HardControlHistory
	return {
		lastEndedAt = endedAt,
		recentApplications = history.recentApplications,
		totalDisabledSeconds = history.totalDisabledSeconds,
	}
end

return StatusEffectResolver
