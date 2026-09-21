--!strict
-- Pure per-round task assignment (P2-4): who gets which stations, and
-- which of a station's accepted tasks runs there for them. Deterministic
-- given the same seed, so a round is reproducible for debugging (the
-- task's own requirement) - TaskService.luau is the thin Roblox-touching
-- wrapper that supplies the real seed, station pool and player list and
-- applies the result.
--
-- WHY A HAND-ROLLED RNG, NOT Random.new(): Random is a Roblox engine
-- datatype, not part of vanilla Luau - confirmed locally that `Random.
-- new(...)` errors ("attempt to index nil with 'new'") when run under
-- Lune, which would make this module fail to even require() in the test
-- runner, breaking Ground Rule 4. A simple LCG (the classic "Numerical
-- Recipes" constants) is all "reproducible for debugging" actually
-- needs - this isn't cryptographic and never needs to be.

local TaskAssignment = {}

export type StationInfo = {
	stationId: string,
	acceptedTaskIds: { string },
}

export type StationAssignment = {
	stationId: string,
	taskId: string,
}

local RNG_MODULUS = 2 ^ 32

local function newRng(seed: number): () -> number
	local state = seed % RNG_MODULUS
	return function(): number
		state = (state * 1664525 + 1013904223) % RNG_MODULUS
		return state / RNG_MODULUS -- a float in [0, 1)
	end
end

-- Fisher-Yates over a shallow copy, using `nextRandom` (a () -> number in
-- [0, 1)) for each swap - the caller's own list is never mutated.
local function shuffledCopy<T>(list: { T }, nextRandom: () -> number): { T }
	local copy = table.clone(list)
	for i = #copy, 2, -1 do
		local j = math.floor(nextRandom() * i) + 1
		copy[i], copy[j] = copy[j], copy[i]
	end
	return copy
end

-- Pure: assigns every player in `playerIds` exactly `tasksPerPlayer`
-- distinct stations from `stations`, each capped at `capacityPerStation`
-- concurrent players. Shuffling both the player visit order and each
-- player's own view of the pool (continuing the same RNG stream across
-- players and rounds, never resetting it) is what satisfies "avoid
-- giving every player an identical route" - two players only ever end up
-- with the same route by coincidence, not by construction.
--
-- DEALT ONE STATION PER PLAYER PER ROUND, NOT ONE PLAYER FULLY AT A TIME:
-- fully resolving player A's whole route before even looking at player
-- B lets A greedily exhaust shared capacity B also needed, and can starve
-- B even when total supply (capacityPerStation * #stations) comfortably
-- covers total demand (tasksPerPlayer * #playerIds) - confirmed locally,
-- this is exactly how the first version of this function failed its own
-- tests. Dealing round-by-round (everyone gets their 1st pick, then
-- everyone gets their 2nd, ...) keeps that early-mover advantage from
-- ever compounding within a single player's route.
--
-- Errors if the pool still can't satisfy every player at that capacity -
-- a caller should size `capacityPerStation` with some headroom above the
-- bare theoretical minimum (e.g. ceil(#playerIds * tasksPerPlayer /
-- #stations) + 1) for the random dealing order to reliably succeed; an
-- infeasible combination even then is a bad map/GameConfig pairing, and
-- Ground Rule 2 says that should fail loudly, not silently hand back a
-- short route a player can never complete.
function TaskAssignment.assign(
	seed: number,
	stations: { StationInfo },
	playerIds: { number },
	tasksPerPlayer: number,
	capacityPerStation: number
): { [number]: { StationAssignment } }
	assert(#stations > 0, "TaskAssignment.assign: no stations in pool")
	assert(tasksPerPlayer > 0, "TaskAssignment.assign: tasksPerPlayer must be positive")
	assert(capacityPerStation > 0, "TaskAssignment.assign: capacityPerStation must be positive")

	local nextRandom = newRng(seed)
	local remainingCapacity: { [string]: number } = {}
	for _, station in stations do
		remainingCapacity[station.stationId] = capacityPerStation
	end

	local result: { [number]: { StationAssignment } } = {}
	local alreadyAssigned: { [number]: { [string]: boolean } } = {}
	for _, playerId in playerIds do
		result[playerId] = {}
		alreadyAssigned[playerId] = {}
	end

	local orderedPlayerIds = shuffledCopy(playerIds, nextRandom)

	for _ = 1, tasksPerPlayer do
		for _, playerId in orderedPlayerIds do
			local pool = shuffledCopy(stations, nextRandom)
			for _, station in pool do
				if remainingCapacity[station.stationId] > 0 and not alreadyAssigned[playerId][station.stationId] then
					local taskIndex = math.floor(nextRandom() * #station.acceptedTaskIds) + 1
					table.insert(
						result[playerId],
						{ stationId = station.stationId, taskId = station.acceptedTaskIds[taskIndex] }
					)
					alreadyAssigned[playerId][station.stationId] = true
					remainingCapacity[station.stationId] -= 1
					break
				end
			end
		end
	end

	for _, playerId in playerIds do
		if #result[playerId] < tasksPerPlayer then
			error(
				string.format(
					"TaskAssignment.assign: could not give player %d %d distinct station(s) at capacity %d"
						.. " (pool size %d) - raise capacityPerStation or add stations",
					playerId,
					tasksPerPlayer,
					capacityPerStation,
					#stations
				),
				0
			)
		end
	end

	return result
end

return TaskAssignment
