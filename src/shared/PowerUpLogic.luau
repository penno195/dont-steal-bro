--!strict
-- Pure logic for PowerUpService (P2-7): cooldown math, inventory-full
-- policy, weighted pool selection, and range/cone targeting geometry.
-- Self-contained on purpose - no requires, no Roblox API calls anywhere
-- - same shape as Qualification.luau/TaskAssignment.luau, for the same
-- reason: Ground Rule 4 wants this kind of logic (validation, ranking,
-- selection) unit-tested headlessly under Lune (tests/PowerUpLogic.spec.
-- luau). PowerUpService.luau is the thin Roblox-touching wrapper that
-- supplies real Players/Characters/CollectionService state and applies
-- what this module decides.
--
-- WHY RANGE/CONE TARGETING IS EXPRESSED WITH PLAIN {x,y,z} TABLES, NOT
-- Vector3: Vector3 is a Roblox engine datatype, not part of vanilla
-- Luau (the same reason TaskAssignment.luau hand-rolls its own RNG
-- instead of using Random.new() - confirmed there that Roblox-only
-- datatypes simply don't exist under Lune). Smart targeting is exactly
-- the kind of security-relevant logic worth testing in isolation, so it
-- stays here as plain-number vector math rather than moving to the
-- Roblox-touching wrapper just to get to use Vector3's operators.

local PowerUpLogic = {}

export type Vec3 = { x: number, y: number, z: number }

local function subtract(a: Vec3, b: Vec3): Vec3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function dot(a: Vec3, b: Vec3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

local function magnitude(v: Vec3): number
	return math.sqrt(dot(v, v))
end

-- ===== cooldowns =========================================================

-- Pure: is a power-up still cooling down? `lastUsedAt` nil means "never
-- used" - never on cooldown.
function PowerUpLogic.isOnCooldown(lastUsedAt: number?, cooldownSeconds: number, now: number): boolean
	if lastUsedAt == nil then
		return false
	end
	return now - lastUsedAt < cooldownSeconds
end

-- Pure: seconds remaining, clamped to 0 - never negative, so a caller can
-- always show/log this directly without its own clamping.
function PowerUpLogic.cooldownRemaining(lastUsedAt: number?, cooldownSeconds: number, now: number): number
	if lastUsedAt == nil then
		return 0
	end
	return math.max(0, cooldownSeconds - (now - lastUsedAt))
end

-- ===== inventory ==========================================================

-- Pure: could a character whose root is at `root` really have touched a
-- pickup at `pickup`? (P8-1.) Touched is reported by whichever machine
-- simulates the touching part, and a player's own character is simulated
-- on THEIR client - so an exploit can report a touch against a pickup on
-- the far side of the map. The server re-measures instead of believing
-- it. `reachStuds` covers the pickup's radius plus a character's
-- half-extent plus latency slack; see PowerUpService.PICKUP_REACH_STUDS.
function PowerUpLogic.isWithinPickupReach(root: Vec3, pickup: Vec3, reachStuds: number): boolean
	return magnitude(subtract(root, pickup)) <= reachStuds
end

-- Pure: picking up a power-up while holding `currentSlotCount` of
-- `maxSlots`. Returns (allowed, shouldSwapOldest) - "Swap" always allows
-- and signals the caller to evict the oldest held item first; "Refuse"
-- only allows when there's already free space (powerups.md: "either
-- swap or is refused, per config").
function PowerUpLogic.canPickUp(
	currentSlotCount: number,
	maxSlots: number,
	fullPolicy: "Swap" | "Refuse"
): (boolean, boolean)
	if currentSlotCount < maxSlots then
		return true, false
	end
	if fullPolicy == "Swap" then
		return true, true
	end
	return false, false
end

-- ===== weighted pool selection ===========================================

-- Pure: uniform selection over `pool`, given an external `roll` in
-- [0, 1) the caller supplies (so this stays deterministic and testable -
-- the caller decides whether that roll is math.random() or a seeded
-- stream). Errors on an empty pool rather than returning nil - a
-- dispatcher calling this should already have filtered to a non-empty
-- eligible pool; an empty one reaching here is a caller bug, not a
-- runtime condition to silently swallow.
function PowerUpLogic.selectUniform<T>(pool: { T }, roll: number): T
	assert(#pool > 0, "PowerUpLogic.selectUniform: pool is empty")
	local clampedRoll = math.clamp(roll, 0, 0.9999999)
	local index = math.floor(clampedRoll * #pool) + 1
	return pool[index]
end

-- ===== targeting ==========================================================

-- Pure: is `target` within `maxRangeStuds` of `caster`, AND within
-- `maxConeDegrees` (the FULL cone width, not the half-angle) of
-- `casterForward`? A caster with a zero-length forward vector (shouldn't
-- happen for a real Character, but never trust an input blindly) is
-- treated as having no facing constraint - range alone decides.
function PowerUpLogic.isWithinRangeAndCone(
	caster: Vec3,
	casterForward: Vec3,
	target: Vec3,
	maxRangeStuds: number,
	maxConeDegrees: number
): boolean
	local offset = subtract(target, caster)
	local distance = magnitude(offset)
	if distance > maxRangeStuds then
		return false
	end
	if distance == 0 then
		return true -- standing exactly on the caster's own position - trivially "in front"
	end

	local forwardMagnitude = magnitude(casterForward)
	if forwardMagnitude == 0 then
		return true
	end

	local cosAngle = dot(offset, casterForward) / (distance * forwardMagnitude)
	local clampedCosAngle = math.clamp(cosAngle, -1, 1) -- guards float drift pushing this just past [-1, 1]
	local angleDegrees = math.deg(math.acos(clampedCosAngle))

	return angleDegrees <= maxConeDegrees / 2
end

export type TargetCandidate = {
	id: number,
	position: Vec3,
}

-- Pure: the nearest candidate within range AND cone, or nil if none
-- qualify - "the server picks the nearest valid target in a forward
-- cone" (P2-7's own requirement, verbatim). Ties (exactly equal
-- distance) resolve to the lower id, purely for determinism - a
-- real-world exact tie is vanishingly unlikely, but a test shouldn't
-- have to depend on table iteration order to be reproducible.
function PowerUpLogic.nearestInCone(
	caster: Vec3,
	casterForward: Vec3,
	candidates: { TargetCandidate },
	maxRangeStuds: number,
	maxConeDegrees: number
): number?
	local bestId: number? = nil
	local bestDistance = math.huge

	for _, candidate in candidates do
		if
			not PowerUpLogic.isWithinRangeAndCone(
				caster,
				casterForward,
				candidate.position,
				maxRangeStuds,
				maxConeDegrees
			)
		then
			continue
		end

		local distance = magnitude(subtract(candidate.position, caster))
		if distance < bestDistance or (distance == bestDistance and (bestId == nil or candidate.id < bestId)) then
			bestDistance = distance
			bestId = candidate.id
		end
	end

	return bestId
end

-- Pure: the nearest candidate within range only, no cone constraint -
-- "Nearest"-target power-ups (Blind, Push/Trip per powerups.md) auto-
-- target without requiring the caster to actually aim.
function PowerUpLogic.nearestInRange(caster: Vec3, candidates: { TargetCandidate }, maxRangeStuds: number): number?
	return PowerUpLogic.nearestInCone(caster, { x = 0, y = 0, z = 0 }, candidates, maxRangeStuds, 360)
end

return PowerUpLogic
