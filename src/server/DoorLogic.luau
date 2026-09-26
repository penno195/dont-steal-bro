--!strict
-- Pure half of DoorService: when a proximity door opens or closes, and
-- which way it swings. No Roblox API, so tests/DoorLogic.spec.luau
-- covers it headlessly.
--
-- HYSTERESIS. A door opens when someone comes within `openRadius` and
-- only closes once nobody is within the wider `closeRadius`. With one
-- radius, a player standing on the boundary would flap the door open and
-- shut every check.
--
-- SWING SIDE. A door swings away from the person who opened it, so it
-- never sweeps into their face. Chosen once, when it opens: re-picking
-- while open would slam it through whoever walked in behind them.

export type Vec3 = { x: number, y: number, z: number }

local DoorLogic = {}

local function horizontalDistanceSquared(a: Vec3, b: Vec3): number
	local dx, dz = a.x - b.x, a.z - b.z
	return dx * dx + dz * dz
end

-- The nearest of `positions` to `center` on the ground plane (doors
-- don't care who's on the floor above), or nil when there are none.
function DoorLogic.nearest(center: Vec3, positions: { Vec3 }): (Vec3?, number)
	local best: Vec3? = nil
	local bestSq = math.huge
	for _, p in positions do
		local d = horizontalDistanceSquared(center, p)
		if d < bestSq then
			best, bestSq = p, d
		end
	end
	return best, math.sqrt(bestSq)
end

-- Whether the door should be open after this check.
function DoorLogic.nextOpen(
	isOpen: boolean,
	center: Vec3,
	positions: { Vec3 },
	openRadius: number,
	closeRadius: number
): boolean
	local _, distance = DoorLogic.nearest(center, positions)
	if isOpen then
		return distance <= closeRadius
	end
	return distance <= openRadius
end

-- +1 or -1: the side of the door's plane the opener is NOT on. `normal`
-- is the closed door's facing (any length); +1 means "swing towards
-- +normal". Someone exactly in the plane gets +1, so the answer is
-- always defined.
function DoorLogic.swingSide(center: Vec3, normal: Vec3, opener: Vec3): number
	local along = (opener.x - center.x) * normal.x + (opener.z - center.z) * normal.z
	return if along > 0 then -1 else 1
end

return table.freeze(DoorLogic)
