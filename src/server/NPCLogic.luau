--!strict
-- Every decision an NPC makes that is arithmetic rather than Roblox
-- (P3-5): how many bots to spawn, which skill profile each draws, how
-- long it "works" at a station, the fairness floor that stops it beating
-- a human, which station it heads for next, and what it's called.
-- NPCService.luau is the thin Roblox-touching wrapper that supplies real
-- players, real parts and a real clock and acts on the results.
--
-- All of it lives here, out of the service, for one reason: this is the
-- FAIRNESS math. "An NPC never beats the median human time for a task"
-- is a claim about the leaderboard's credibility (threat-model.md §8),
-- and a claim like that should be provable by a test rather than by
-- reading a service that also does pathfinding. Ground Rule 4.
--
-- Same hand-rolled LCG as TaskAssignment.luau, for the same reason its
-- own header gives: `Random.new()` is a Roblox engine datatype and
-- errors under Lune, which would make this module fail to require() in
-- the test runner. Seeded, so a round's NPC behaviour is reproducible.

local NPCLogic = {}

local RNG_MODULUS = 2 ^ 31

-- A `() -> number` in [0, 1), seeded. Exported because NPCService gives
-- each NPC its own stream (seeded from the round seed plus the NPC's own
-- id) rather than sharing one - so adding or removing a bot doesn't
-- shift every other bot's draws, which would make "replay this round's
-- seed" useless the moment a player joined late.
function NPCLogic.newRng(seed: number): () -> number
	local state = math.floor(math.abs(seed)) % RNG_MODULUS
	return function(): number
		state = (state * 1664525 + 1013904223) % RNG_MODULUS
		return state / RNG_MODULUS
	end
end

-- ===== how many bots ========================================================

-- architecture.md §4: "reads npcCount from TeleportData as a hint only
-- and re-derives it itself: 6 - humansPresentAfterGraceWindow." The
-- TeleportData value never reaches this function at all - threat-model.md
-- §5 ("TeleportData is never authoritative for anything, full stop")
-- is enforced by not plumbing it in, rather than by remembering not to
-- trust it.
--
-- Clamped at both ends: a server that somehow holds more humans than the
-- target seat count asks for 0 bots, never a negative number.
function NPCLogic.deriveFillCount(humansPresent: number, targetPlayerCount: number): number
	return math.clamp(targetPlayerCount - humansPresent, 0, targetPlayerCount)
end

-- ===== skill profiles =======================================================

export type SkillProfile = {
	id: string,
	weight: number, -- relative draw weight; need not sum to 1
	durationScale: number, -- >1 works SLOWER than the task's expected range, <1 faster
	moveSpeedScale: number, -- multiplier on the NPC rig's walk speed
}

-- Weighted draw from `profiles` using a single roll in [0, 1). Walks the
-- list in order and returns the first profile whose cumulative weight
-- passes the roll, so the result is a pure function of (profiles, roll)
-- - no hidden state, trivially testable at the boundaries.
function NPCLogic.pickSkillProfile(profiles: { SkillProfile }, roll: number): SkillProfile
	assert(#profiles > 0, "NPCLogic.pickSkillProfile: no profiles configured")

	local total = 0
	for _, profile in profiles do
		total += profile.weight
	end
	assert(total > 0, "NPCLogic.pickSkillProfile: profile weights sum to zero")

	local target = math.clamp(roll, 0, 0.999999) * total
	local cumulative = 0
	for _, profile in profiles do
		cumulative += profile.weight
		if target < cumulative then
			return profile
		end
	end

	-- Unreachable for a well-formed weight list; returned rather than
	-- errored so a floating-point edge can never stall a whole round.
	return profiles[#profiles]
end

-- ===== how long a bot "works" at a station ==================================

export type DurationRange = {
	min: number,
	max: number,
}

-- The median of a copy of `samples` - the caller's list is never sorted
-- in place. nil for an empty list (no opinion, rather than a fabricated
-- zero, which would read as "humans finish instantly" to the floor
-- below and wipe out the fairness guarantee).
function NPCLogic.median(samples: { number }): number?
	if #samples == 0 then
		return nil
	end

	local sorted = table.clone(samples)
	table.sort(sorted)

	local middle = #sorted // 2
	if #sorted % 2 == 1 then
		return sorted[middle + 1]
	end
	return (sorted[middle] + sorted[middle + 1]) / 2
end

-- The fairness floor: the fastest an NPC is ever allowed to complete
-- this task, in seconds.
--
-- `observedMedianSeconds` is the median of REAL human completions of
-- this task (this server, this round - NPCService feeds them in as they
-- land). Until enough humans have actually finished it, there is no
-- observed median to floor against, and the honest fallback is the
-- task's own catalogue range: `expectedDurationSeconds` is the
-- designed human time for that task (tasks-catalogue.md), so its
-- midpoint is the best available estimate of a median human. That makes
-- the guarantee hold from the first second of a round rather than only
-- after the third human completion, which is exactly when an NPC would
-- otherwise be free to run away with it.
function NPCLogic.fairnessFloorSeconds(
	expected: DurationRange,
	observedMedianSeconds: number?,
	mapDifficultyModifier: number,
	floorScale: number
): number
	local median = observedMedianSeconds
	if median == nil then
		median = (expected.min + expected.max) / 2
	end
	return (median :: number) * mapDifficultyModifier * floorScale
end

export type WorkSampleParams = {
	expected: DurationRange,
	profile: SkillProfile,
	mapDifficultyModifier: number, -- MapDef.npcDifficultyModifier, 0.5-2.0
	observedMedianSeconds: number?,
	floorScale: number, -- 1.0 = "never faster than the median human"
	roll: number, -- [0, 1)
}

export type WorkSample = {
	seconds: number,
	flooredBy: number?, -- the floor value, when it actually bound; nil when the raw sample was already slow enough
}

-- Samples uniformly across the task's expected range, scales by the
-- NPC's skill profile and the map's difficulty modifier, then clamps up
-- to the fairness floor. Returns which floor bound it (if any) so
-- NPCService can log how often the rubber band is actually doing work -
-- a strong-profile NPC that is floored on every single task means the
-- profile spread is tuned outside what the floor permits, and the
-- profile is a lie. That is worth being able to see.
function NPCLogic.sampleWorkSeconds(params: WorkSampleParams): WorkSample
	local expected = params.expected
	local span = math.max(expected.max - expected.min, 0)
	local base = expected.min + math.clamp(params.roll, 0, 0.999999) * span

	local scaled = base * params.profile.durationScale * params.mapDifficultyModifier
	local floor = NPCLogic.fairnessFloorSeconds(
		expected,
		params.observedMedianSeconds,
		params.mapDifficultyModifier,
		params.floorScale
	)

	if scaled < floor then
		return { seconds = floor, flooredBy = floor }
	end
	return { seconds = scaled, flooredBy = nil }
end

-- ===== which station next ===================================================

export type StationCandidate = {
	stationId: string,
	distance: number,
}

-- "Nearest unfinished, with randomness" (architecture.md §4): sorts by
-- distance and picks uniformly among the `topK` nearest. Pure nearest
-- would send every NPC on an identical, obviously-scripted route through
-- the map and make them clump; full random would have them cross the
-- arena pointlessly and look broken. k=2 is the smallest value that
-- breaks the lockstep.
--
-- Ties are broken by stationId so the result is deterministic for a
-- given (candidates, roll) regardless of the caller's input order.
function NPCLogic.chooseNextStation(candidates: { StationCandidate }, roll: number, topK: number): string?
	if #candidates == 0 then
		return nil
	end

	local sorted = table.clone(candidates)
	table.sort(sorted, function(a, b)
		if a.distance == b.distance then
			return a.stationId < b.stationId
		end
		return a.distance < b.distance
	end)

	local poolSize = math.clamp(topK, 1, #sorted)
	local index = math.floor(math.clamp(roll, 0, 0.999999) * poolSize) + 1
	return sorted[index].stationId
end

-- ===== the coarse nav graph =================================================

-- The map's own NavNode graph, as map-kit-spec.md defines it: a NodeId
-- per node and the comma-separated ConnectedNodeIds out of it.
-- NPCService reads the real Attachments and their attributes; this
-- module only ever sees the ids, so the search below is pure.
export type NavGraph = { [string]: { string } }

-- Breadth-first, so the returned route is the FEWEST hops rather than
-- the shortest walking distance. That's the right trade here: each hop
-- is a separate PathfindingService:ComputeAsync call (the expensive
-- part - docs/npc-notes.md), and shaving studs off a route by taking
-- more hops would cost more than it saves. Includes both endpoints;
-- {from} alone when from == to; nil when no route exists at all, which
-- is map-kit-spec.md's "disconnected graph" failure and the one case
-- NPCService has to fall back on a direct path for.
function NPCLogic.findNodePath(graph: NavGraph, fromNodeId: string, toNodeId: string): { string }?
	if graph[fromNodeId] == nil or graph[toNodeId] == nil then
		return nil
	end
	if fromNodeId == toNodeId then
		return { fromNodeId }
	end

	local cameFrom: { [string]: string } = {}
	local visited: { [string]: boolean } = { [fromNodeId] = true }
	local queue: { string } = { fromNodeId }
	local head = 1

	while head <= #queue do
		local current = queue[head]
		head += 1

		local neighbors = graph[current]
		if neighbors == nil then
			continue
		end

		for _, neighbor in neighbors do
			if visited[neighbor] or graph[neighbor] == nil then
				continue
			end
			visited[neighbor] = true
			cameFrom[neighbor] = current

			if neighbor == toNodeId then
				local route = { neighbor }
				local step = neighbor
				while cameFrom[step] ~= nil do
					step = cameFrom[step]
					table.insert(route, 1, step)
				end
				return route
			end

			table.insert(queue, neighbor)
		end
	end

	return nil
end

-- ===== names ================================================================

-- Two halves joined by a SPACE, and the space is the whole guarantee: a
-- Roblox username may contain only letters, digits and at most one
-- underscore, never a space, so a generated name of this shape cannot
-- collide with any real username that exists or could ever be created.
-- That is a property of the format, not of a list that has to be kept
-- up to date - architecture.md §4's "names that can never collide with
-- real usernames," satisfied by construction.
--
-- Display names, unlike usernames, CAN contain spaces, so a human could
-- in principle be displaying "Rapid Gecko" right now. That is what
-- `isTaken` is for: NPCService passes a predicate closed over the live
-- roster's display names, and this retries until it finds a free one.
local NAME_FIRST: { string } = {
	"Rapid",
	"Turbo",
	"Sneaky",
	"Lucky",
	"Grumpy",
	"Cosmic",
	"Jumpy",
	"Silent",
	"Wired",
	"Frosty",
	"Rusty",
	"Zippy",
}

local NAME_SECOND: { string } = {
	"Gecko",
	"Walnut",
	"Pylon",
	"Muffin",
	"Cactus",
	"Otter",
	"Wrench",
	"Comet",
	"Badger",
	"Noodle",
	"Pigeon",
	"Sprocket",
}

-- Never impersonates a real player: the pool is fixed, generic and
-- shipped in this file, so a name can't be derived from (or drift
-- toward) anything a real player is called.
function NPCLogic.generateDisplayName(nextRandom: () -> number, isTaken: (name: string) -> boolean): string
	-- Bounded rather than `while true`: the pool is 12 x 12 x 100, so
	-- exhausting 64 draws means something is badly wrong (an isTaken that
	-- always returns true), and stalling the round's spawn loop forever
	-- is a worse failure than one duplicate-looking name.
	for _ = 1, 64 do
		local first = NAME_FIRST[math.floor(nextRandom() * #NAME_FIRST) + 1]
		local second = NAME_SECOND[math.floor(nextRandom() * #NAME_SECOND) + 1]
		local suffix = math.floor(nextRandom() * 100)
		local candidate = string.format("%s %s%02d", first, second, suffix)
		if not isTaken(candidate) then
			return candidate
		end
	end

	-- Deliberately still space-separated, so even the giving-up path
	-- keeps the username-collision guarantee above.
	return string.format("Racer %d", math.floor(nextRandom() * 10000))
end

-- The guarantee above, as something a test can assert directly rather
-- than by re-implementing the rule. A name is username-collision-proof
-- if it contains at least one character no Roblox username may contain.
function NPCLogic.isUsernameCollisionProof(name: string): boolean
	return string.match(name, "[^%w_]") ~= nil
end

-- ===== leaderboard credit ===================================================

-- threat-model.md §8 promotes architecture.md's "consider reduced or
-- zero streak credit when more than N seats are NPCs" to a REQUIRED
-- launch mitigation: "no streak credit above a defined NPC-seat
-- threshold. Exact N is a playtest tuning call, but some threshold must
-- ship day one." This is that check, as one pure predicate, so P4-1's
-- ProgressionService can gate on it without re-deriving the rule.
--
-- `npcSeatCount > threshold` (strictly greater - "more than N"), against
-- GameConfig.npcSeatStreakCreditThreshold.
function NPCLogic.earnsStreakCredit(npcSeatCount: number, threshold: number): boolean
	return npcSeatCount <= threshold
end

return NPCLogic
