--!strict
-- Where a point sits against a route (a polyline), pure so it runs
-- headlessly in tests/PathLogic.spec.luau. Navigation uses it on both
-- sides: the server, to tell when a player has strayed far enough off
-- their line to need a new one; the client, to start the dots at the
-- player rather than back where the route began.

local PathLogic = {}

export type Point = { x: number, y: number, z: number }

export type Closest = {
	segment: number, -- the segment ending at points[segment] (the first starts at `from`)
	t: number, -- 0..1 along that segment
	distance: number, -- from the point to the route
}

-- The nearest place on the route to `point`. `from` is the route's
-- start, so a route of n points has n segments. Ties go to the earlier
-- segment, so a route that doubles back doesn't skip ahead.
function PathLogic.closest(point: Point, from: Point, points: { Point }): Closest
	local best: Closest = { segment = 0, t = 0, distance = math.huge }
	local a = from
	for i, b in points do
		local abx, aby, abz = b.x - a.x, b.y - a.y, b.z - a.z
		local lengthSq = abx * abx + aby * aby + abz * abz
		local t = 0
		if lengthSq > 0 then
			t = ((point.x - a.x) * abx + (point.y - a.y) * aby + (point.z - a.z) * abz) / lengthSq
			t = math.clamp(t, 0, 1)
		end
		local dx = a.x + abx * t - point.x
		local dy = a.y + aby * t - point.y
		local dz = a.z + abz * t - point.z
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		if distance < best.distance then
			best = { segment = i, t = t, distance = distance }
		end
		a = b
	end
	return best
end

-- The route's length on foot, from `from` through every point.
function PathLogic.length(from: Point, points: { Point }): number
	local total, a = 0, from
	for _, b in points do
		local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
		total += math.sqrt(dx * dx + dy * dy + dz * dz)
		a = b
	end
	return total
end

return PathLogic
