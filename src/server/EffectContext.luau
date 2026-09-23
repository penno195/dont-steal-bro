--!strict
-- The context flag PowerUpService and StatusEffects run under (P5-5).
-- A server is in exactly one mode for its whole life: "Round" on a match
-- server, "Practice" on a hub server with a practice area. Round is the
-- default and changes nothing: every function below answers exactly as
-- if this module didn't exist, so round behaviour is untouched by P5-5.
--
-- WHY PRACTICE REUSES THE REAL SERVICES INSTEAD OF A COPY: the hub
-- practice area exists so a waiting player learns what a freeze feels
-- like, how far a push-trip reaches, how long a cooldown is. A second
-- implementation would teach whatever that copy happened to do, and the
-- two would drift the first time someone retuned a range, a stacking
-- rule or an immunity window in one and not the other. Then practice
-- would actively mistrain players for the real round. With one
-- implementation and this flag, a change to the real rules reaches
-- practice automatically. Only the deliberate differences below can
-- ever separate them, and they all live in this file.
--
-- Pure on purpose: no Roblox API calls, so tests/EffectContext.spec.luau
-- runs it headlessly. Where a participant is standing is the one thing
-- it can't know, so PracticeService injects that as a gate function.

local EffectContext = {}

export type Mode = "Round" | "Practice"

-- GameConfig.practice's effect half. See Validate.PracticeConfig.
export type PracticeRules = {
	durationScale: number, -- 0-1 multiplier on every effect's duration
	maxEffectSeconds: number, -- hard ceiling after scaling
	maxActiveEffects: number, -- per participant, at once
}

-- True when participant `id` is inside the practice area right now, out
-- of the queue pad's no-effect zone, and not about to leave for a match.
export type Gate = (id: number) -> boolean

local mode: Mode = "Round"
local rules: PracticeRules? = nil
local gate: Gate? = nil

function EffectContext.mode(): Mode
	return mode
end

function EffectContext.isPractice(): boolean
	return mode == "Practice"
end

-- Called once, by PracticeService on a hub server. There is no way back
-- to Round: a hub never runs a round, and a mode that could flip
-- mid-life is one more thing that could leave a real round running
-- under practice rules.
function EffectContext.enterPractice(practiceRules: PracticeRules, practiceGate: Gate)
	assert(mode == "Round", "EffectContext.enterPractice: already in practice mode")
	mode = "Practice"
	rules = practiceRules
	gate = practiceGate
end

-- A match server calls this as a round starts. Practice state is plain
-- server memory, and a teleport carries nothing but TeleportLogic's
-- hint (group id, map id, NPC seat count), so practice can't reach a
-- match server. This makes that a checked fact instead of an
-- assumption: a server that somehow runs a round in practice mode
-- stops here rather than running it with shortened, capped effects.
function EffectContext.assertRound(where: string)
	assert(mode == "Round", string.format("%s: practice rules are active on a server running a round", where))
end

-- Progression, stats and analytics writers check this. Nothing in the
-- power-up or effect path writes progression today, but anything added
-- later must call this, or a hub scuffle would count as a real round.
function EffectContext.recordsStats(): boolean
	return mode == "Round"
end

-- Inside the practice area, in practice mode. MovementWatch exempts
-- these players: speed buffs and knockback are the point of practice.
function EffectContext.inPracticeArea(id: number): boolean
	if mode ~= "Practice" or gate == nil then
		return false
	end
	return (gate :: Gate)(id)
end

-- May `id` pick up, cast, or be hit? Always yes in a round. In practice,
-- only inside the practice area, which is what keeps effects off the
-- rest of the hub and off the queue pad.
function EffectContext.mayAct(id: number): boolean
	if mode == "Round" then
		return true
	end
	return EffectContext.inPracticeArea(id)
end

-- ===== pure rules (exported for tests) ======================================

function EffectContext.scaledDuration(baseSeconds: number, practiceRules: PracticeRules): number
	return math.min(baseSeconds * practiceRules.durationScale, practiceRules.maxEffectSeconds)
end

-- Refreshing an effect the target already has never counts against the
-- cap. It adds nothing new to the pile, and refusing it would make
-- re-landing the same item mysteriously fail.
function EffectContext.admitsEffect(activeCount: number, refreshesExisting: boolean, cap: number): boolean
	return refreshesExisting or activeCount < cap
end

-- ===== the two questions StatusEffects asks =================================

function EffectContext.effectDuration(baseSeconds: number): number
	if mode == "Round" or rules == nil then
		return baseSeconds
	end
	return EffectContext.scaledDuration(baseSeconds, rules :: PracticeRules)
end

function EffectContext.admits(activeCount: number, refreshesExisting: boolean): boolean
	if mode == "Round" or rules == nil then
		return true
	end
	return EffectContext.admitsEffect(activeCount, refreshesExisting, (rules :: PracticeRules).maxActiveEffects)
end

-- Never call outside a test.
function EffectContext.resetForTesting()
	mode = "Round"
	rules = nil
	gate = nil
end

return EffectContext
