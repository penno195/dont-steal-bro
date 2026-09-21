--!strict
-- Pure logic for MovementWatch (P2-9): how far an observed speed exceeds
-- what a player should be capable of, and the rolling violation-score
-- math that turns individual samples into a Log/Flag/Act judgement.
-- Self-contained on purpose - no requires, no Roblox API calls anywhere
-- - same shape as every other *Logic.luau/*Resolver.luau module in this
-- repo, for the same reason: Ground Rule 4 wants exactly this kind of
-- threshold/scoring logic unit-tested headlessly under Lune (tests/
-- MovementSanity.spec.luau). MovementWatch.luau is the thin Roblox-
-- touching wrapper that supplies real Character positions and timers
-- and acts on what this module decides.
--
-- WHY POSITIONS ARE PLAIN {x, y, z} TABLES, NOT Vector3: Vector3 is a
-- Roblox engine datatype, not part of vanilla Luau - confirmed
-- elsewhere in this repo (TaskAssignment.luau's RNG, PowerUpLogic.luau's
-- targeting) that Roblox-only datatypes simply don't exist under Lune.

local MovementSanity = {}

export type Vec3 = { x: number, y: number, z: number }
export type ViolationLevel = "Clean" | "Log" | "Flag" | "Act"

-- A single wild sample (a genuine teleport that slipped past
-- suppression, a one-frame replication glitch) shouldn't be able to
-- corrupt the rolling score with an unbounded number - clamped the same
-- way PowerUpLogic.cooldownRemaining clamps to a sane floor instead of
-- trusting arithmetic to stay reasonable on its own.
local MAX_EXCESS_RATIO = 20

-- Pure: how far `observedSpeed` exceeds the allowed cap
-- (`allowedSpeed * toleranceMultiplier`), as a ratio. 0 means exactly at
-- the cap; negative means comfortably under it; the caller only ever
-- accumulates the POSITIVE part as a violation (see applySample).
-- `allowedSpeed <= 0` (e.g. a ControlLock effect - the resolved max is
-- exactly zero) is handled as its own case rather than dividing by zero:
-- any observed movement at all is the maximum-severity violation, no
-- movement is clean.
function MovementSanity.excessRatio(observedSpeed: number, allowedSpeed: number, toleranceMultiplier: number): number
	local cap = allowedSpeed * toleranceMultiplier
	if cap <= 0 then
		return if observedSpeed > 0 then MAX_EXCESS_RATIO else 0
	end
	local ratio = (observedSpeed - cap) / cap
	return math.clamp(ratio, -1, MAX_EXCESS_RATIO)
end

export type ScoreState = {
	score: number,
	lastSampleAt: number,
}

-- Pure: folds one sample's excessRatio into a ROLLING score - "a rolling
-- violation score rather than instant judgement" (the task's own
-- requirement, verbatim). The score decays continuously between samples
-- (at `decayPerSecond`, floored at 0) before this sample's own
-- contribution (the positive part of excessRatio only - a comfortably-
-- clean sample never SUBTRACTS from the score beyond ordinary decay, it
-- just contributes nothing) is added, so a single clean sample doesn't
-- erase a real pattern, but a player who stops cheating still sees their
-- score fall back toward zero over time rather than staying flagged
-- forever from one past incident.
function MovementSanity.applySample(
	state: ScoreState,
	excessRatio: number,
	now: number,
	decayPerSecond: number
): ScoreState
	local elapsed = math.max(0, now - state.lastSampleAt)
	local decayed = math.max(0, state.score - decayPerSecond * elapsed)
	local contribution = if excessRatio > 0 then excessRatio else 0
	return { score = decayed + contribution, lastSampleAt = now }
end

-- Pure: which of the three separate thresholds (the task's own
-- requirement: "separate thresholds for log, flag and act") the current
-- score has crossed. Thresholds are expected to satisfy
-- log <= flag <= act; this function doesn't itself validate that
-- (GameConfig's own boot-time validator does - see Validate.
-- checkGameConfig) since a caller re-deriving that invariant on every
-- call would be pure waste.
function MovementSanity.levelFor(
	score: number,
	logThreshold: number,
	flagThreshold: number,
	actThreshold: number
): ViolationLevel
	if score >= actThreshold then
		return "Act"
	elseif score >= flagThreshold then
		return "Flag"
	elseif score >= logThreshold then
		return "Log"
	end
	return "Clean"
end

-- Pure: straight-line distance in the X/Z plane only, never Y - "falling"
-- is explicitly one of the legitimate causes of apparent speed this
-- system has to account for (the task's own requirement), and the
-- cleanest way to account for it isn't a special case at all: WalkSpeed
-- only ever governs HORIZONTAL movement in the first place, so a big
-- vertical drop during a normal jump arc or fall never contributes to
-- "observed speed" here regardless of how large the full 3D distance
-- moved was.
function MovementSanity.horizontalDistance(a: Vec3, b: Vec3): number
	local dx = a.x - b.x
	local dz = a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

-- Pure: horizontal speed implied by two positions `elapsedSeconds`
-- apart. Returns 0 for a non-positive interval rather than dividing by
-- zero or a negative number - "sample on a fixed interval" still means
-- clock jitter can occasionally hand this a near-zero or (very rarely,
-- across a server hiccup) even a slightly negative elapsed value, and
-- neither should ever read as an infinite or negative speed.
function MovementSanity.horizontalSpeed(previous: Vec3, current: Vec3, elapsedSeconds: number): number
	if elapsedSeconds <= 0 then
		return 0
	end
	return MovementSanity.horizontalDistance(previous, current) / elapsedSeconds
end

return MovementSanity
