--!strict
-- Pure ranking/qualification logic for the race (P2-4). TaskService.luau
-- (the Roblox-touching wrapper) calls this whenever qualification needs
-- to be decided - either "3 players already finished all their tasks"
-- (the common case) or "the hard round timer expired with fewer than 3
-- finished" (design-decisions.md Q2) - both are just a ranking of
-- whatever progress exists at that moment, so one function covers both
-- triggers; TaskService decides WHEN to call it, this module only ever
-- decides WHAT the ranking is.
--
-- Self-contained on purpose - no requires, no Roblox API calls anywhere
-- - same shape as RoundStates.luau, Net.luau, Validate.luau, ProfileLogic
-- .luau, for the same reason: this is Ground Rule 4's outcome-resolution
-- kind of logic ("ranking, tie-breaks... must stay free of any Roblox
-- API calls"), so it has to stay requirable under Lune for headless
-- tests (tests/Qualification.spec.luau).

local Qualification = {}

-- One entry per player still being considered. `lastCompletionTime` and
-- `distanceToNextStation` are both nil for a player who hasn't completed
-- anything yet or has no meaningful "next station" (nothing assigned) -
-- see the comparator below for how nil is treated at each tie-break
-- level. A fully-finished player's `lastCompletionTime` IS their finish
-- time (their most recent completion is their last one), so there's no
-- separate "finishedAt" field to keep in sync with this one.
export type PlayerProgress = {
	playerId: number,
	tasksAssigned: number,
	tasksCompleted: number,
	lastCompletionTime: number?,
	distanceToNextStation: number?,
}

-- Which of the three named tie-break criteria (map-kit-spec.md/the
-- task's own requirement: "tasks completed, then... last completion,
-- then... distance to next station") is what separates this entry from
-- the entry ranked immediately above it - "onlyEntry" for rank 1, where
-- nothing separates it from anything. This is the "expose it so the UI
-- can show a player exactly why they placed where they did" requirement
-- - a client renders this against a fixed copy string per value, rather
-- than this module owning any display text itself.
export type DecidedBy = "taskCount" | "lastCompletionTime" | "distanceToNextStation" | "playerId" | "onlyEntry"

export type RankedEntry = {
	playerId: number,
	rank: number, -- 1-based
	tasksCompleted: number,
	tasksAssigned: number,
	completionRate: number, -- tasksCompleted / tasksAssigned, 0..1
	qualifies: boolean, -- top `qualifierCount` AND meets `minCompletionRate`
	decidedBy: DecidedBy,
}

export type QualificationResult = {
	ranked: { RankedEntry }, -- every entry given, in final rank order
	qualifiers: { number }, -- playerIds, in rank order; may be fewer than qualifierCount (design-decisions.md Q2: NPC backfill covers the rest, never a void case)
	alternate: number?, -- the next-in-line playerId who ALSO meets the floor (design-decisions.md Q3's promotion target); nil if nobody past the qualifiers meets it
}

-- Treats a missing timestamp as "never completed anything" (worst
-- possible, i.e. +inf) and a missing distance as "nothing left to travel
-- to" (best possible, i.e. 0) - both read naturally as "this criterion
-- doesn't apply, so it can't be what breaks the tie downward."
local function orderedCompletionTime(entry: PlayerProgress): number
	return entry.lastCompletionTime or math.huge
end

local function orderedDistance(entry: PlayerProgress): number
	return entry.distanceToNextStation or 0
end

-- True if `a` ranks strictly better than `b`. The final `playerId`
-- comparison is not one of the task's own three named criteria - it's
-- the deterministic tie-break UNDER all three, guaranteeing a strict
-- total order (every player has a distinct playerId) so this is always
-- safe to hand to table.sort regardless of how many real ties collide.
local function ranksBetter(a: PlayerProgress, b: PlayerProgress): boolean
	if a.tasksCompleted ~= b.tasksCompleted then
		return a.tasksCompleted > b.tasksCompleted
	end

	local aTime, bTime = orderedCompletionTime(a), orderedCompletionTime(b)
	if aTime ~= bTime then
		return aTime < bTime
	end

	local aDist, bDist = orderedDistance(a), orderedDistance(b)
	if aDist ~= bDist then
		return aDist < bDist
	end

	return a.playerId < b.playerId
end

-- Which criterion actually separates `worse` from `better` - the first
-- of the three (then playerId) that differs between them. Mirrors
-- `ranksBetter`'s own comparison order exactly, so "why am I not ranked
-- one spot higher" always names a real reason.
local function decidingCriterion(better: PlayerProgress, worse: PlayerProgress): DecidedBy
	if better.tasksCompleted ~= worse.tasksCompleted then
		return "taskCount"
	end
	if orderedCompletionTime(better) ~= orderedCompletionTime(worse) then
		return "lastCompletionTime"
	end
	if orderedDistance(better) ~= orderedDistance(worse) then
		return "distanceToNextStation"
	end
	return "playerId"
end

-- Pure: ranks every entry, applies design-decisions.md Q2's completion
-- floor, and takes the top `qualifierCount`. `entries` may be any size
-- (a leaver is simply never in the list - this function has no notion of
-- "should have been 6 players," so TaskService doesn't need to pad or
-- flag anything when someone leaves mid-race, just stop including them).
function Qualification.rank(
	entries: { PlayerProgress },
	qualifierCount: number,
	minCompletionRate: number
): QualificationResult
	assert(#entries > 0, "Qualification.rank: no player progress entries given")
	assert(qualifierCount > 0, "Qualification.rank: qualifierCount must be positive")

	local sorted = table.clone(entries)
	table.sort(sorted, ranksBetter)

	local ranked: { RankedEntry } = {}
	local qualifiers: { number } = {}
	local alternate: number? = nil

	for index, entry in sorted do
		local completionRate = if entry.tasksAssigned > 0 then entry.tasksCompleted / entry.tasksAssigned else 0
		local meetsFloor = completionRate >= minCompletionRate
		local qualifies = meetsFloor and #qualifiers < qualifierCount

		local decidedBy: DecidedBy
		if index == 1 then
			decidedBy = "onlyEntry"
		else
			decidedBy = decidingCriterion(sorted[index - 1], entry)
		end

		table.insert(ranked, {
			playerId = entry.playerId,
			rank = index,
			tasksCompleted = entry.tasksCompleted,
			tasksAssigned = entry.tasksAssigned,
			completionRate = completionRate,
			qualifies = qualifies,
			decidedBy = decidedBy,
		})

		if qualifies then
			table.insert(qualifiers, entry.playerId)
		elseif meetsFloor and alternate == nil then
			alternate = entry.playerId
		end
	end

	return { ranked = ranked, qualifiers = qualifiers, alternate = alternate }
end

return Qualification
