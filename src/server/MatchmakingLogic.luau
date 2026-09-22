--!strict
-- The pure half of cross-server matchmaking (P5-1). Every decision the
-- queue makes lives here - what a queue entry may turn into, which
-- entries form a group, who may not be grouped together, what the UI is
-- told - so it can be tested headlessly. MatchmakingService.luau is the
-- thin wrapper that moves these values in and out of MemoryStore.
--
-- ===== THE ONE RULE THAT PREVENTS DOUBLE-BOOKING =======================
--
-- A player's queue entry (one MemoryStore key, keyed by userId) is the
-- ONLY arbiter of which group that player belongs to. Every change to
-- an entry is a compare-and-set through UpdateAsync, using the
-- transforms below, and each transform refuses (returns nil, which
-- cancels the write) unless the entry is in exactly the state it
-- expects:
--
--   Waiting --claim(G)--> Claimed(G) --depart(G)--> Departed(G)
--                             |
--                             +--release(G)--> Waiting   (same sortKey:
--                                                         place kept)
--   any live state --leave(ownJob)--> Left
--
-- claim only accepts Waiting, so two servers claiming the same player
-- cannot both succeed: MemoryStore runs UpdateAsync on one key
-- atomically, re-running the transform against the new value on
-- conflict, and the loser's re-run sees Claimed and refuses.
--
-- A player leaves on group G only when BOTH are true: their entry says
-- Claimed(G), and G's group record exists. The server that owns the
-- player checks both and then moves the entry to Departed(G) with a
-- compare-and-set. A group record for G can outlive a claim, and a
-- claim can outlive a group that never committed. Neither case can put
-- a player in two groups, because only one token fits in the entry.
-- The worst case is a group that arrives one short, and the match
-- server's NPC fill (architecture.md §4) already handles that.
--
-- No cross-server clock comparison is load-bearing. Claims carry no
-- expiry timestamp. A stale claim is judged by the OWNING server,
-- using its own os.clock, from when it first saw that claim. Only the
-- partial-group timer and the rematch cooldown read wall-clock time,
-- and a few seconds of skew between servers only shifts them slightly.

local MatchmakingLogic = {}

export type EntryState = "Waiting" | "Claimed" | "Departed" | "Left"

-- One "don't group me with this player until `t`" record. A list
-- rather than a { [userId]: until } map so the MemoryStore JSON never
-- has to round-trip numeric-looking string keys.
export type AvoidRecord = { u: number, t: number }

export type Entry = {
	v: number, -- schema version; an unknown version decodes to nil
	userId: number,
	jobId: string, -- the hub server that owns this player right now
	enqueuedAt: number, -- unix seconds; also the SortedMap sort key
	streak: number, -- carried for later priority logic; design-decisions.md Q6 says none today
	avoid: { AvoidRecord },
	state: EntryState,
	groupId: string?,
}

export type GroupRecord = {
	v: number,
	groupId: string,
	members: { number },
	npcSlots: number,
	formedAt: number,
	formedBy: string,
}

export type FormedGroup = {
	members: { Entry },
	npcSlots: number,
	partial: boolean,
}

export type Config = {
	groupSize: number,
	partialGroupTimeoutSeconds: number,
	partialGroupMinPlayers: number,
	formationTickSeconds: number,
	rematchCooldownSeconds: number,
	recentOpponentsCap: number,
}

export type QueueStatus = {
	position: number?, -- nil: not on the page read (beyond the first page)
	queueSize: number,
	queueSizeIsLowerBound: boolean,
	estimatedWaitSeconds: number,
}

MatchmakingLogic.SCHEMA_VERSION = 1

local VALID_STATES: { [string]: boolean } = { Waiting = true, Claimed = true, Departed = true, Left = true }

-- ===== decoding ============================================================
--
-- Values come back from MemoryStore written by OTHER servers, possibly
-- running an older build. Anything malformed decodes to nil and is
-- treated as absent, never half-trusted.

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function decodeAvoid(raw: any): { AvoidRecord }
	local out: { AvoidRecord } = {}
	if type(raw) ~= "table" then
		return out
	end
	for _, record in raw do
		if type(record) == "table" and isFiniteNumber(record.u) and isFiniteNumber(record.t) then
			table.insert(out, { u = record.u, t = record.t })
		end
	end
	return out
end

function MatchmakingLogic.decodeEntry(raw: any): Entry?
	if type(raw) ~= "table" or raw.v ~= MatchmakingLogic.SCHEMA_VERSION then
		return nil
	end
	if not isFiniteNumber(raw.userId) or type(raw.jobId) ~= "string" or not isFiniteNumber(raw.enqueuedAt) then
		return nil
	end
	if type(raw.state) ~= "string" or not VALID_STATES[raw.state] then
		return nil
	end
	if raw.groupId ~= nil and type(raw.groupId) ~= "string" then
		return nil
	end
	-- Claimed and Departed are meaningless without the token they hold.
	if (raw.state == "Claimed" or raw.state == "Departed") and raw.groupId == nil then
		return nil
	end
	return {
		v = raw.v,
		userId = raw.userId,
		jobId = raw.jobId,
		enqueuedAt = raw.enqueuedAt,
		streak = if isFiniteNumber(raw.streak) then raw.streak else 0,
		avoid = decodeAvoid(raw.avoid),
		state = raw.state :: EntryState,
		groupId = raw.groupId,
	}
end

function MatchmakingLogic.decodeGroup(raw: any): GroupRecord?
	if type(raw) ~= "table" or raw.v ~= MatchmakingLogic.SCHEMA_VERSION then
		return nil
	end
	if type(raw.groupId) ~= "string" or type(raw.members) ~= "table" or not isFiniteNumber(raw.npcSlots) then
		return nil
	end
	local members: { number } = {}
	for _, userId in raw.members do
		if not isFiniteNumber(userId) then
			return nil
		end
		table.insert(members, userId)
	end
	return {
		v = raw.v,
		groupId = raw.groupId,
		members = members,
		npcSlots = raw.npcSlots,
		formedAt = if isFiniteNumber(raw.formedAt) then raw.formedAt else 0,
		formedBy = if type(raw.formedBy) == "string" then raw.formedBy else "",
	}
end

function MatchmakingLogic.decodeRecent(raw: any): { AvoidRecord }
	if type(raw) ~= "table" then
		return {}
	end
	return decodeAvoid(raw.list)
end

-- ===== construction ========================================================

function MatchmakingLogic.newEntry(
	userId: number,
	jobId: string,
	enqueuedAt: number,
	streak: number,
	avoid: { AvoidRecord }
): Entry
	return {
		v = MatchmakingLogic.SCHEMA_VERSION,
		userId = userId,
		jobId = jobId,
		enqueuedAt = enqueuedAt,
		streak = streak,
		avoid = avoid,
		state = "Waiting",
		groupId = nil,
	}
end

function MatchmakingLogic.newGroupRecord(
	groupId: string,
	members: { Entry },
	npcSlots: number,
	formedAt: number,
	formedBy: string
): GroupRecord
	local ids: { number } = {}
	for _, entry in members do
		table.insert(ids, entry.userId)
	end
	return {
		v = MatchmakingLogic.SCHEMA_VERSION,
		groupId = groupId,
		members = ids,
		npcSlots = npcSlots,
		formedAt = formedAt,
		formedBy = formedBy,
	}
end

local function withState(entry: Entry, state: EntryState, groupId: string?): Entry
	local copy = table.clone(entry)
	copy.state = state
	copy.groupId = groupId
	return copy
end

-- ===== compare-and-set transforms ==========================================
--
-- Each takes the CURRENT stored value (already decoded; nil = absent or
-- malformed) and returns the value to write, or nil to cancel. None of
-- them ever change enqueuedAt, which is what keeps a released player's
-- place in line.

-- Joining. A repeat join from the same server while still Waiting or
-- Claimed changes nothing (no write), so double-tapping the button
-- can't reset your place or disturb a claim in flight. Anything else
-- (absent, Left, Departed, or another server's stale entry after a
-- server hop) is replaced with the fresh entry.
function MatchmakingLogic.join(current: Entry?, fresh: Entry): Entry?
	if
		current ~= nil
		and current.jobId == fresh.jobId
		and (current.state == "Waiting" or current.state == "Claimed")
	then
		return nil
	end
	return fresh
end

function MatchmakingLogic.claim(current: Entry?, groupId: string): Entry?
	if current == nil or current.state ~= "Waiting" then
		return nil
	end
	return withState(current, "Claimed", groupId)
end

function MatchmakingLogic.release(current: Entry?, groupId: string): Entry?
	if current == nil or current.state ~= "Claimed" or current.groupId ~= groupId then
		return nil
	end
	return withState(current, "Waiting", nil)
end

function MatchmakingLogic.depart(current: Entry?, groupId: string): Entry?
	if current == nil or current.state ~= "Claimed" or current.groupId ~= groupId then
		return nil
	end
	return withState(current, "Departed", groupId)
end

-- Only the owning server can mark an entry Left, so a PlayerRemoving
-- on the old server that runs late can't evict an entry the player
-- has since made on a new hub server. Departed is final: the player is
-- already on the way to a match.
function MatchmakingLogic.leave(current: Entry?, jobId: string): Entry?
	if current == nil or current.jobId ~= jobId then
		return nil
	end
	if current.state == "Departed" or current.state == "Left" then
		return nil
	end
	return withState(current, "Left", nil)
end

-- The owner's heartbeat: rewrite unchanged to push the TTL out. Claimed
-- entries are kept alive too, so a claim that is still resolving can't
-- expire mid-commit. Anything else isn't ours to keep alive.
function MatchmakingLogic.refresh(current: Entry?, jobId: string): Entry?
	if current == nil or current.jobId ~= jobId then
		return nil
	end
	if current.state == "Waiting" or current.state == "Claimed" then
		return current
	end
	return nil
end

-- ===== what the owning server does about a claim ===========================

export type OwnerAction = "Depart" | "Revert" | "Wait"

-- `groupExists` is whether the group record for the entry's token was
-- found; `claimSeenForSeconds` is how long THIS server has watched the
-- same token sit on the entry, by its own clock.
function MatchmakingLogic.ownerActionForClaim(
	groupExists: boolean,
	claimSeenForSeconds: number,
	staleClaimRevertSeconds: number
): OwnerAction
	if groupExists then
		return "Depart"
	end
	if claimSeenForSeconds >= staleClaimRevertSeconds then
		return "Revert"
	end
	return "Wait"
end

-- ===== rematch cooldown ====================================================

local function avoids(entry: Entry, otherUserId: number, now: number): boolean
	for _, record in entry.avoid do
		if record.u == otherUserId and record.t > now then
			return true
		end
	end
	return false
end

-- Symmetric on purpose. Both sides of a past group normally carry the
-- other in their own list, but one side's write can fail, and one
-- surviving record is enough to keep them apart.
function MatchmakingLogic.compatible(a: Entry, b: Entry, now: number): boolean
	return not avoids(a, b.userId, now) and not avoids(b, a.userId, now)
end

-- Merges a new group's co-members into one player's stored avoid list:
-- drops expired records, drops the player themselves, keeps the latest
-- expiry per opponent, and caps the list at the most recent `cap`
-- expiries (the ones that will still matter longest).
function MatchmakingLogic.mergeRecent(
	existing: { AvoidRecord },
	selfUserId: number,
	coMembers: { number },
	now: number,
	cooldownSeconds: number,
	cap: number
): { AvoidRecord }
	local latest: { [number]: number } = {}
	for _, record in existing do
		if record.t > now and record.u ~= selfUserId then
			latest[record.u] = math.max(latest[record.u] or 0, record.t)
		end
	end
	local expiresAt = now + cooldownSeconds
	for _, userId in coMembers do
		if userId ~= selfUserId then
			latest[userId] = math.max(latest[userId] or 0, expiresAt)
		end
	end

	local merged: { AvoidRecord } = {}
	for userId, t in latest do
		table.insert(merged, { u = userId, t = t })
	end
	table.sort(merged, function(a: AvoidRecord, b: AvoidRecord): boolean
		if a.t ~= b.t then
			return a.t > b.t
		end
		return a.u < b.u
	end)
	while #merged > cap do
		table.remove(merged)
	end
	return merged
end

-- ===== group selection =====================================================

local function byQueueOrder(a: Entry, b: Entry): boolean
	if a.enqueuedAt ~= b.enqueuedAt then
		return a.enqueuedAt < b.enqueuedAt
	end
	return a.userId < b.userId
end

function MatchmakingLogic.waitingInOrder(entries: { Entry }): { Entry }
	local waiting: { Entry } = {}
	for _, entry in entries do
		if entry.state == "Waiting" then
			table.insert(waiting, entry)
		end
	end
	table.sort(waiting, byQueueOrder)
	return waiting
end

-- Greedy in queue order from `seed`: take each next-oldest player who
-- is compatible with everyone taken so far, up to groupSize.
local function greedyFrom(
	seed: Entry,
	pool: { Entry },
	taken: { [number]: boolean },
	now: number,
	size: number
): { Entry }
	local group: { Entry } = { seed }
	for _, candidate in pool do
		if #group >= size then
			break
		end
		if candidate ~= seed and not taken[candidate.userId] then
			local ok = true
			for _, member in group do
				if not MatchmakingLogic.compatible(member, candidate, now) then
					ok = false
					break
				end
			end
			if ok then
				table.insert(group, candidate)
			end
		end
	end
	return group
end

-- Every group that should form from this snapshot, oldest first.
--
-- Full groups first: each still-unassigned player, in queue order,
-- seeds a greedy group, and a seed that reaches groupSize takes it.
-- Trying every seed rather than only the oldest means one player whose
-- cooldown rules out everyone can't hold up six others who are fine
-- together. They keep their place and get the partial-group timer.
--
-- Then partial groups: the oldest leftover player who has waited past
-- partialGroupTimeoutSeconds seeds the largest compatible group of
-- leftovers, and the rest of the seats are NPC slots. The cooldown is
-- never relaxed to fill a group. A quiet server is exactly when
-- colluding friends would be matched together, so the fallback is
-- bots, and NPC-heavy lobbies already earn reduced streak credit
-- (GameConfig.npcSeatStreakCreditThreshold).
function MatchmakingLogic.selectGroups(entries: { Entry }, now: number, config: Config): { FormedGroup }
	local waiting = MatchmakingLogic.waitingInOrder(entries)
	local taken: { [number]: boolean } = {}
	local groups: { FormedGroup } = {}
	local size = config.groupSize

	for _, seed in waiting do
		if not taken[seed.userId] then
			local group = greedyFrom(seed, waiting, taken, now, size)
			if #group == size then
				for _, member in group do
					taken[member.userId] = true
				end
				table.insert(groups, { members = group, npcSlots = 0, partial = false })
			end
		end
	end

	for _, seed in waiting do
		if not taken[seed.userId] and now - seed.enqueuedAt >= config.partialGroupTimeoutSeconds then
			local group = greedyFrom(seed, waiting, taken, now, size)
			if #group >= config.partialGroupMinPlayers then
				for _, member in group do
					taken[member.userId] = true
				end
				table.insert(groups, { members = group, npcSlots = size - #group, partial = true })
			end
		end
	end

	return groups
end

-- ===== the UI's view of the queue ==========================================

-- Position, queue size and a rough wait estimate for one player, from
-- the same page snapshot the formation pass reads. The estimate is an
-- estimate: a full group ahead forms on the next tick, otherwise the
-- player's own slice of the line waits out the partial-group timer.
-- It never names or counts anybody's streak (design-decisions.md Q7).
function MatchmakingLogic.queueStatus(
	entries: { Entry },
	userId: number,
	now: number,
	config: Config,
	pageWasFull: boolean
): QueueStatus
	local waiting = MatchmakingLogic.waitingInOrder(entries)
	local position: number? = nil
	for index, entry in waiting do
		if entry.userId == userId then
			position = index
			break
		end
	end

	local size = config.groupSize
	local tick = config.formationTickSeconds
	local estimate: number
	if position == nil then
		-- Behind everyone on the page: at least as long as the last slice.
		estimate = config.partialGroupTimeoutSeconds
	else
		local slice = math.ceil(position / size)
		local sliceStart = (slice - 1) * size + 1
		if #waiting >= slice * size then
			estimate = tick
		else
			local waited = now - waiting[sliceStart].enqueuedAt
			estimate = math.max(tick, config.partialGroupTimeoutSeconds - waited)
		end
	end

	return {
		position = position,
		queueSize = #waiting,
		queueSizeIsLowerBound = pageWasFull,
		estimatedWaitSeconds = math.ceil(estimate),
	}
end

-- ===== retry pacing ========================================================

function MatchmakingLogic.backoffSeconds(consecutiveFailures: number, base: number, cap: number): number
	if consecutiveFailures <= 0 then
		return 0
	end
	return math.min(cap, base * 2 ^ (consecutiveFailures - 1))
end

return MatchmakingLogic
