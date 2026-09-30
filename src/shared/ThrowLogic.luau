--!strict
-- The pure half of a thrown power-up: which items are thrown, how long
-- the projectile flies, the lob it flies along, and the shove on each
-- end (the victim's shunt, the thrower's recoil). No Roblox API -
-- PowerUpService times the effect with flightSeconds and computes the
-- shunt; ThrowController draws the projectile and applies the local
-- player's own shove. Numbers live in GameConfig.powerUpThrow.
-- Require-free, so it runs under Lune.

-- Same shape as PowerUpLogic.Vec3.
export type Vec3 = { x: number, y: number, z: number }

export type ThrowConfig = {
	projectileSpeedStuds: number,
	maxFlightSeconds: number,
	arcHeightStuds: number,
	shuntSpeed: number,
	shuntUpSpeed: number,
	recoilSpeed: number,
}

local ThrowLogic = {}

-- Aimed and Nearest items hit another racer, so they're thrown. Self
-- and Area items are used where the caster stands.
function ThrowLogic.isThrown(target: string): boolean
	return target == "Aimed" or target == "Nearest"
end

local function distance(a: Vec3, b: Vec3): number
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Seconds from the throw to the impact: distance at projectile speed,
-- capped so a long throw can't leave a use uncommitted for long.
function ThrowLogic.flightSeconds(from: Vec3, to: Vec3, config: ThrowConfig): number
	return math.min(distance(from, to) / config.projectileSpeedStuds, config.maxFlightSeconds)
end

-- Unit ground-plane direction from `from` to `to`, or `fallback`
-- (flattened) when the two stand on top of each other.
local function flatDirection(from: Vec3, to: Vec3, fallback: Vec3): (number, number)
	local dx, dz = to.x - from.x, to.z - from.z
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-3 then
		dx, dz = fallback.x, fallback.z
		len = math.sqrt(dx * dx + dz * dz)
		if len < 1e-3 then
			return 0, 1
		end
	end
	return dx / len, dz / len
end

-- The velocity that shoves the victim away from the thrower: flat
-- `shuntSpeed` along the throw plus a small upward pop, both scaled by
-- the item's shuntScale (nil = 1). `fallback` is the throw direction
-- used when the two are standing in the same spot.
function ThrowLogic.shuntVelocity(
	thrower: Vec3,
	victim: Vec3,
	fallback: Vec3,
	config: ThrowConfig,
	scale: number?
): Vec3
	local s = scale or 1
	local dx, dz = flatDirection(thrower, victim, fallback)
	return { x = dx * config.shuntSpeed * s, y = config.shuntUpSpeed * s, z = dz * config.shuntSpeed * s }
end

-- The thrower's recoil: straight back from the target, no lift.
function ThrowLogic.recoilVelocity(thrower: Vec3, target: Vec3, fallback: Vec3, config: ThrowConfig): Vec3
	local dx, dz = flatDirection(thrower, target, fallback)
	return { x = -dx * config.recoilSpeed, y = 0, z = -dz * config.recoilSpeed }
end

-- The projectile's position `alpha` (0..1) of the way along its lob: a
-- straight line plus a parabola peaking at arcHeightStuds halfway.
function ThrowLogic.arcPoint(from: Vec3, to: Vec3, alpha: number, arcHeightStuds: number): Vec3
	local a = math.clamp(alpha, 0, 1)
	local lift = 4 * arcHeightStuds * a * (1 - a)
	return {
		x = from.x + (to.x - from.x) * a,
		y = from.y + (to.y - from.y) * a + lift,
		z = from.z + (to.z - from.z) * a,
	}
end

return ThrowLogic
