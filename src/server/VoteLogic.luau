--!strict
-- The pure half of map voting (P5-3). Everything the vote decides lives
-- here, so it can be tested headlessly: which maps go on the ballot,
-- whether a vote is accepted, when voting locks, who won, and how a tie
-- is broken. VoteService.luau moves these values in and out of the
-- group record in MemoryStore and drives the board UI. docs/voting.md
-- walks the whole flow.
--
-- ===== WHERE THE VOTE LIVES ================================================
--
-- A group can span several hub servers, so no single server can hold
-- the vote. It lives inside the group record (MatchGroups_v1[groupId]),
-- the same record the match server later reads as its manifest:
--
--   ballot  - drawn by the former, before it claims anyone
--   votes   - one { u, m } per voter, each written by that voter's own
--             hub server with a compare-and-set (castVote)
--   result  - written ONCE, by whichever owner server locks first
--             (lock). Every transform refuses once it is set, so a
--             late vote can't land after the winner is fixed, and a
--             second locker can't re-roll a tie
--   mapId   - overwritten with the winner by the same lock write
--
-- Because the winner is only ever read back from the record, every hub
-- server teleports to the same map and the match server loads it, even
-- though each server tallies on its own and the tie-break is random.
--
-- ===== THE RANDOM TIE-BREAK ================================================
--
-- `rng` is anything with Roblox Random's NextNumber/NextInteger methods.
-- VoteService passes a real `Random.new()`. The specs pass a seeded LCG,
-- because Random is an engine datatype that doesn't exist under Lune
-- (see TaskAssignment.luau's header).

local VoteLogic = {}

-- The slice of MatchmakingLogic.GroupRecord a vote reads. Declared here,
-- structurally, rather than required, so this module stays requirable
-- on its own under Lune like every other *Logic module. The shapes of
-- VoteRecord and VoteResult must match MatchmakingLogic's exactly.
export type VoteRecord = { u: number, m: string }
export type VoteResult = { winner: string, tied: { string } }
export type VoteState = {
	members: { number },
	ballot: { string },
	votes: { VoteRecord },
	result: VoteResult?,
}

export type Rng = {
	NextNumber: (self: any) -> number,
	NextInteger: (self: any, min: number, max: number) -> number,
}

-- How hard a recently played map is pushed off the ballot.
export type Weighting = {
	-- The weight of a map every member played last round. 0 would ban
	-- it outright, and a ballot then couldn't fill on a small map pool.
	floorWeight: number,
	-- Each round further back counts this much less (0.5: last round
	-- counts 1, the one before 0.5, then 0.25...).
	decay: number,
}

export type Tally = {
	counts: { [string]: number },
	voters: { [string]: { number } }, -- mapId -> userIds, in vote order
	voted: number, -- members with a counted vote
}

export type Winner = {
	winner: string,
	tied: { string }, -- every map on the top count, ballot order
	randomTieBreak: boolean,
}

export type CastRefusal = "NoRecord" | "NoBallot" | "Locked" | "NotMember" | "NotOnBallot" | "Unchanged"

-- ===== the ballot ==========================================================

-- 0..1: how recently the group as a whole played `mapId`. Each member
-- contributes decay^(i-1) if it's i-th in their list, and the result is
-- the average over members. A member with no history pulls it towards
-- 0, so one regular can't shut a map out for five newcomers.
function VoteLogic.exposure(mapId: string, recentLists: { { string } }, decay: number): number
	if #recentLists == 0 then
		return 0
	end
	local sum = 0
	for _, list in recentLists do
		local index = table.find(list, mapId)
		if index ~= nil then
			sum += decay ^ (index - 1)
		end
	end
	return sum / #recentLists
end

function VoteLogic.mapWeight(mapId: string, recentLists: { { string } }, weighting: Weighting): number
	local exposure = VoteLogic.exposure(mapId, recentLists, weighting.decay)
	return 1 - (1 - weighting.floorWeight) * exposure
end

-- Draws `size` distinct maps from `enabled`, weighted against recent
-- play. Weighted sampling without replacement: each draw picks from
-- the maps still left in proportion to their weight. Returns fewer
-- than `size` maps only when fewer are enabled, and an empty ballot
-- when there's nothing to choose between (0 or 1 maps), which skips
-- the vote.
function VoteLogic.drawBallot(
	enabled: { string },
	recentLists: { { string } },
	size: number,
	weighting: Weighting,
	rng: Rng
): { string }
	if #enabled < 2 then
		return {}
	end
	-- Sorted, so the same rng stream always gives the same ballot
	-- regardless of the order Maps/ was collected in.
	local pool = table.clone(enabled)
	table.sort(pool)
	local weights: { number } = {}
	for i, mapId in pool do
		weights[i] = VoteLogic.mapWeight(mapId, recentLists, weighting)
	end

	local ballot: { string } = {}
	while #ballot < size and #pool > 0 do
		local total = 0
		for _, weight in weights do
			total += weight
		end
		local roll = rng:NextNumber() * total
		local chosen = #pool -- float rounding can leave roll just past the end
		for i, weight in weights do
			roll -= weight
			if roll < 0 then
				chosen = i
				break
			end
		end
		table.insert(ballot, table.remove(pool, chosen) :: string)
		table.remove(weights, chosen)
	end
	return ballot
end

-- The former's stand-in for the winner, written into the record at
-- commit so the match server always has a valid map, even if the vote
-- never locks. Uniform over the ballot.
function VoteLogic.provisionalMap(ballot: { string }, rng: Rng): string?
	if #ballot == 0 then
		return nil
	end
	return ballot[rng:NextInteger(1, #ballot)]
end

-- ===== casting =============================================================

-- The heart of the compare-and-set for one player's vote. Returns the
-- record's new `votes` list, or nil and why not. A player may change
-- their vote as often as they like until the result is set, and a vote
-- replaces their previous one, so there's never more than one each.
function VoteLogic.castVote(current: VoteState?, userId: number, mapId: string): ({ VoteRecord }?, CastRefusal?)
	if current == nil then
		return nil, "NoRecord"
	end
	if #current.ballot == 0 then
		return nil, "NoBallot"
	end
	if current.result ~= nil then
		return nil, "Locked"
	end
	if table.find(current.members, userId) == nil then
		return nil, "NotMember"
	end
	if table.find(current.ballot, mapId) == nil then
		return nil, "NotOnBallot"
	end
	local votes: { VoteRecord } = {}
	for _, vote in current.votes do
		if vote.u == userId then
			if vote.m == mapId then
				return nil, "Unchanged"
			end
		else
			table.insert(votes, vote)
		end
	end
	table.insert(votes, { u = userId, m = mapId })
	return votes, nil
end

-- ===== counting ============================================================

-- Counts only votes from listed members for maps on the ballot, and
-- only each member's last vote. castVote already guarantees all three,
-- but the record comes back from MemoryStore, so the tally doesn't rely
-- on it.
function VoteLogic.tally(record: VoteState): Tally
	local latest: { [number]: string } = {}
	local order: { number } = {}
	for _, vote in record.votes do
		if table.find(record.members, vote.u) ~= nil and table.find(record.ballot, vote.m) ~= nil then
			if latest[vote.u] == nil then
				table.insert(order, vote.u)
			end
			latest[vote.u] = vote.m
		end
	end

	local counts: { [string]: number } = {}
	local voters: { [string]: { number } } = {}
	for _, mapId in record.ballot do
		counts[mapId] = 0
		voters[mapId] = {}
	end
	for _, userId in order do
		local mapId = latest[userId]
		counts[mapId] += 1
		table.insert(voters[mapId], userId)
	end
	return { counts = counts, voters = voters, voted = #order }
end

-- THE TIE RULE: the most votes wins. If several maps share the top
-- count, one of them is picked uniformly at random. With no votes at
-- all, every ballot map is tied on 0, so the pick is uniform over the
-- whole ballot: players who don't vote simply aren't counted.
function VoteLogic.pickWinner(ballot: { string }, counts: { [string]: number }, rng: Rng): Winner?
	if #ballot == 0 then
		return nil
	end
	local best = -1
	local tied: { string } = {}
	for _, mapId in ballot do
		local count = counts[mapId] or 0
		if count > best then
			best = count
			tied = { mapId }
		elseif count == best then
			table.insert(tied, mapId)
		end
	end
	local winner = if #tied == 1 then tied[1] else tied[rng:NextInteger(1, #tied)]
	return { winner = winner, tied = tied, randomTieBreak = #tied > 1 }
end

-- ===== locking =============================================================

function VoteLogic.allVoted(record: VoteState): boolean
	return VoteLogic.tally(record).voted >= #record.members
end

-- When voting closes, in the caller's wall-clock seconds. The deadline
-- is shared (formedAt is the former's clock), so every owner server
-- closes at about the same moment. It's clamped to at most one full
-- window from `now`, so a former whose clock runs ahead can't stretch
-- the vote.
function VoteLogic.deadline(formedAt: number, voteSeconds: number, now: number): number
	return math.min(formedAt + voteSeconds, now + voteSeconds)
end

function VoteLogic.shouldLock(record: VoteState, now: number, deadline: number): boolean
	if record.result ~= nil or #record.ballot == 0 then
		return false
	end
	return now >= deadline or VoteLogic.allVoted(record)
end

-- The heart of the lock compare-and-set. Returns the result to write
-- (the caller also sets the record's mapId to its winner, which is what
-- the match server loads), or nil to refuse: already locked, because
-- the winner is fixed by whoever got there first and a retry mustn't
-- re-roll a tie, or nothing to lock.
function VoteLogic.lock(current: VoteState?, rng: Rng): VoteResult?
	if current == nil or current.result ~= nil or #current.ballot == 0 then
		return nil
	end
	local picked = VoteLogic.pickWinner(current.ballot, VoteLogic.tally(current).counts, rng)
	if picked == nil then
		return nil
	end
	return { winner = picked.winner, tied = picked.tied }
end

-- ===== recent maps =========================================================

-- A player's history after playing `mapId`: newest first, no repeats,
-- at most `cap` long.
function VoteLogic.pushRecent(list: { string }, mapId: string, cap: number): { string }
	local out: { string } = { mapId }
	for _, other in list do
		if #out >= cap then
			break
		end
		if other ~= mapId then
			table.insert(out, other)
		end
	end
	return out
end

-- ===== the board ===========================================================

export type BoardCard = { mapId: string, votes: number, voters: { number } }

export type BoardState = {
	groupId: string,
	cards: { BoardCard },
	secondsLeft: number,
	myVote: string?,
	locked: boolean,
	winner: string?,
	tied: { string }?,
	randomTieBreak: boolean,
}

-- What one player's client is shown. Built field by field, so nothing
-- else in the record (the access code above all) can reach a client.
-- Voters are only ever members of the viewer's own group, who they're
-- about to meet anyway. No streaks: design-decisions.md Q7.
function VoteLogic.boardState(groupId: string, record: VoteState, viewer: number, secondsLeft: number): BoardState
	local tally = VoteLogic.tally(record)
	local cards: { BoardCard } = {}
	local myVote: string? = nil
	for _, mapId in record.ballot do
		local voters = tally.voters[mapId]
		if table.find(voters, viewer) ~= nil then
			myVote = mapId
		end
		table.insert(cards, { mapId = mapId, votes = tally.counts[mapId], voters = table.clone(voters) })
	end
	local result = record.result
	return {
		groupId = groupId,
		cards = cards,
		secondsLeft = math.max(0, math.ceil(secondsLeft)),
		myVote = myVote,
		locked = result ~= nil,
		winner = if result then result.winner else nil,
		tied = if result then table.clone(result.tied) else nil,
		randomTieBreak = result ~= nil and #result.tied > 1,
	}
end

return VoteLogic
