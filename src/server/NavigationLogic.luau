--!strict
-- Navigation's rules (design-decisions.md Q8, "Navigation"), pure so
-- they run headlessly in tests/NavigationLogic.spec.luau. NavigationService
-- feeds in what it read from the profile, the pass cache and the race,
-- and does what these answer.

local NavigationLogic = {}

-- ===== switching on =========================================================

-- What a switch-on asks about. `chargedThisRound` is true once this
-- player has paid for (or spent a held round on) the race in progress.
export type SwitchOnFacts = {
	isRacing: boolean, -- in Race, assigned stations, not yet finished
	ownsPass: boolean, -- the Unlimited Navigation pass
	chargedThisRound: boolean,
	roundsHeld: number, -- paid rounds in the profile, not yet spent
}

-- "On": switch it on; `spend` says whether to take one held round first.
-- "NeedsPurchase": nothing to spend, so the client offers 99 R$ or coins.
-- "Unavailable": not racing, so there is nothing to lead anywhere.
export type SwitchOnAnswer = "On" | "NeedsPurchase" | "Unavailable"

-- A round is spent on the first switch-on of a race (owner, 2026-10-08).
-- Switching off and on again in the same race is free, and a pass owner
-- never spends a held round, so one bought before the pass is kept.
function NavigationLogic.switchOn(facts: SwitchOnFacts): (SwitchOnAnswer, boolean)
	if not facts.isRacing then
		return "Unavailable", false
	end
	if facts.ownsPass or facts.chargedThisRound then
		return "On", false
	end
	if facts.roundsHeld > 0 then
		return "On", true
	end
	return "NeedsPurchase", false
end

-- ===== where to lead ========================================================

export type Point = { x: number, y: number, z: number }

-- How much a metre of height counts against a metre across, when picking
-- the nearest station. A station on the floor above is further on foot
-- than its straight-line distance says, since the way up is a staircase
-- somewhere else.
local VERTICAL_WEIGHT = 3

local function weightedDistance(a: Point, b: Point): number
	local dx, dy, dz = a.x - b.x, (a.y - b.y) * VERTICAL_WEIGHT, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The nearest of the player's unfinished stations, or nil when none are
-- left (or none have a known position). Ties go to the earlier entry, so
-- the answer doesn't flicker between two equally near stations.
function NavigationLogic.nearestStation(from: Point, stations: { { stationId: string, position: Point } }): string?
	local bestId: string? = nil
	local bestDistance = math.huge
	for _, station in stations do
		local distance = weightedDistance(from, station.position)
		if distance < bestDistance then
			bestDistance = distance
			bestId = station.stationId
		end
	end
	return bestId
end

-- ===== when to resend =======================================================

-- A route is resent only when what it says changed: a new target, or a
-- different chain of waypoints. Positions are rounded to whole studs so
-- float noise in the same nodes never counts as a change.
function NavigationLogic.routeKey(stationId: string?, points: { Point }): string
	local parts = { stationId or "-" }
	for _, point in points do
		table.insert(parts, string.format("%d,%d,%d", math.round(point.x), math.round(point.y), math.round(point.z)))
	end
	return table.concat(parts, ";")
end

return NavigationLogic
