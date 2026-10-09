--!strict
-- Cross-server matchmaking for the Hub place (P5-1). Players queue here
-- and leave in groups of up to 6. The rules are pure and live in
-- src/server/MatchmakingLogic.luau, tested headlessly. This file moves
-- queue entries in and out of MemoryStore and talks to clients.
-- docs/matchmaking.md walks through every concurrency failure case and
-- the MemoryStore limits this is designed against.
--
-- ===== WHO DOES WHAT ====================================================
--
-- Every hub server, every tick (GameConfig.matchmaking.formationTickSeconds):
--
--   1. Tries to hold the formation lease. The holder reads the oldest
--      page of the shared queue (one GetRangeAsync); everyone else reads
--      the summary the holder published, or the page if it is stale.
--   2. For entries it OWNS (entry.jobId == this server): acts on any
--      claim. If the group record exists it departs the player. If it
--      never appears it reverts the claim. See MatchmakingLogic's header
--      for why this is the only place a player is committed to a group.
--   3. The lease holder alone runs selectGroups on the page, claims
--      members, and publishes the resulting summary.
--   4. Sends each of its own queued players their QueueState.
--
-- The lease is an EFFICIENCY measure: it stops ten servers fighting
-- over the same six entries every tick. Correctness does not depend on
-- it. If two servers both believe they hold it (a lapse, a stall),
-- per-key compare-and-set still lets each player be claimed only once.
--
-- ===== THE DEPARTURE SEAM (P5-2) =========================================
--
-- This service decides WHO goes together. It does not teleport anyone.
-- A departed group is handed to `setDepartureHandler`'s callback, which
-- P5-2 replaces with the reserved-server teleport. If a teleport fails,
-- P5-2 calls `requeue(player, enqueuedAt)` and the player goes back in
-- line at their original place.
--
-- A group can span several hub servers, and only the server that
-- reserves a match server learns its access code. So the FORMER
-- reserves, through `setDestinationProvider`, before it claims anyone,
-- and the code travels in the group record. Every owner then teleports
-- its own players to the same place. The reserved server's
-- PrivateServerId becomes the group id, which is how the match server
-- finds its own record without trusting TeleportData.

local Players = game:GetService("Players")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local MatchmakingLogic = require(ServerScriptService.Server.MatchmakingLogic)
local TeleportLogic = require(ServerScriptService.Server.TeleportLogic)

type Entry = MatchmakingLogic.Entry
type GroupRecord = MatchmakingLogic.GroupRecord

export type DepartureHandler = (players: { Player }, group: GroupRecord) -> ()

type TicketStatus = "Joining" | "Waiting" | "Departing"

-- This server's local view of one of its own queued players. It is not
-- authoritative (the MemoryStore entry is), but it outlives an outage:
-- if the entry expires while MemoryStore is down, the ticket still
-- holds enqueuedAt and the refresh loop re-creates the entry at the
-- same place.
type Ticket = {
	status: TicketStatus,
	enqueuedAt: number,
	-- The claim token this server last saw on the entry, and when (by
	-- its own os.clock). This is what "stale" is measured against.
	claimSeen: { groupId: string, at: number }?,
	-- A practice ticket (design-decisions.md Q7): queued locally in
	-- practiceEntries, never in MemoryStore. Every ticket on a private
	-- hub is one; on a public hub, the Practice button's are.
	practice: boolean,
}

local config = GameConfig.matchmaking

local logicConfig: MatchmakingLogic.Config = {
	groupSize = config.groupSize,
	partialGroupTimeoutSeconds = config.partialGroupTimeoutSeconds,
	partialGroupMinPlayers = config.partialGroupMinPlayers,
	formationTickSeconds = config.formationTickSeconds,
	rematchCooldownSeconds = config.rematchCooldownSeconds,
	recentOpponentsCap = config.recentOpponentsCap,
}

local LEASE_KEY = "formationLease"

-- game.JobId is "" in Studio, and every Studio server would share it.
local myJobId: string = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

-- MemoryStoreService throws in a place that has never been published,
-- and throwing here would take the whole server down with it. init()
-- turns matchmaking off instead when the lookups fail.
local queueMap: MemoryStoreSortedMap = nil :: any
local groupMap: MemoryStoreHashMap, recentMap: MemoryStoreHashMap, metaMap: MemoryStoreHashMap =
	nil :: any, nil :: any, nil :: any
local memoryStoreOk, memoryStoreErr = pcall(function()
	queueMap = MemoryStoreService:GetSortedMap(config.queueMapName)
	groupMap = MemoryStoreService:GetHashMap(config.groupMapName)
	recentMap = MemoryStoreService:GetHashMap(config.recentMapName)
	metaMap = MemoryStoreService:GetHashMap(config.metaMapName)
end)

local active = false
local tickets: { [Player]: Ticket } = {}
local consecutiveFailures = 0

-- design-decisions.md Q7, the practice-match case: a practice queue is
-- local to its hub server. Its players never get a MemoryStore queue
-- entry, so no other server can see or claim them, and the server forms
-- its own groups from these local entries, keeping parties whole
-- (PartyService). Only the group record goes to MemoryStore, because the
-- match server reads it from there. On a private hub (a player's own
-- server, or a reserved practice lobby) every queue is practice.
local practiceHub = TeleportLogic.isPracticeHub(game.PrivateServerId)
local practiceEntries: { [Player]: Entry } = {}

local function now(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

local function sendState(player: Player, payload: { [string]: any })
	Net.fireClient("QueueState", player, payload)
end

local function defaultDepartureHandler(players: { Player }, group: GroupRecord)
	-- Studio, or a place with teleporting unset: there is nowhere to send
	-- anyone. Still hold P5-3's vote, so it can be tested here, then say
	-- so honestly rather than leave anyone on a loading screen.
	local mapId = (Loader.get("VoteService") :: any).runVote(players, group)
	warn(
		string.format(
			"MatchmakingService: group %s formed (%d humans, %d NPC slots, map %s) but no departure handler is set",
			group.groupId,
			#group.members,
			group.npcSlots,
			tostring(mapId)
		)
	)
	for _, player in players do
		tickets[player] = nil
		sendState(player, { status = "MatchFound", message = "Match found! Travel isn't available yet." })
	end
end

local departureHandler: DepartureHandler = defaultDepartureHandler

-- Nil in Studio and until P5-2's service installs one: groups then get a
-- GUID id and no destination, which is P5-1's behaviour.
export type DestinationProvider = () -> MatchmakingLogic.Destination?
local destinationProvider: DestinationProvider? = nil

-- When teleporting is configured, a group formed without a destination
-- would have nowhere to go. P5-2's service installs the provider in its
-- own start(), which runs after this service's tick loop is already
-- going, so formation waits for it rather than racing it.
local destinationRequired = GameConfig.teleport.matchPlaceId ~= 0 and not RunService:IsStudio()

-- ===== MemoryStore wrappers ================================================

-- Runs a MatchmakingLogic transform against one queue entry as a
-- compare-and-set. Returns:
--   ok       - false if MemoryStore errored (outcome unknown, see below)
--   written  - what the transform wrote, nil if it refused
--   observed - the decoded value the final transform run saw
--
-- An error doesn't prove nothing was written: a timeout can land after
-- the write. Every caller is written so that a write it doesn't know
-- about is harmless. The transforms are all token-checked, so repeating
-- one or following it with its inverse is safe.
local function casEntry(userId: number, transform: (Entry?) -> Entry?, ttl: number): (boolean, Entry?, Entry?)
	local observed: Entry? = nil
	local written: Entry? = nil
	local ok, err = pcall(function()
		queueMap:UpdateAsync(tostring(userId), function(raw: any, _sortKey: any): (any, any)
			observed = MatchmakingLogic.decodeEntry(raw)
			written = transform(observed)
			if written == nil then
				return nil, nil -- cancels the update; nothing is written
			end
			local value = written :: Entry
			-- The sort key is returned explicitly every time, so it never
			-- depends on how UpdateAsync treats an omitted one.
			return value, value.enqueuedAt
		end, math.floor(ttl))
	end)
	if not ok then
		warn(string.format("MatchmakingService: entry update for %d failed: %s", userId, tostring(err)))
		return false, nil, nil
	end
	return true, written, observed
end

-- Returns (ok, group). ok = false means "couldn't tell", which callers
-- must treat as "wait", never as "absent".
local function fetchGroup(groupId: string): (boolean, GroupRecord?)
	local ok, raw = pcall(function()
		return groupMap:GetAsync(groupId)
	end)
	if not ok then
		return false, nil
	end
	return true, MatchmakingLogic.decodeGroup(raw)
end

local function fetchRecent(userId: number): { MatchmakingLogic.AvoidRecord }
	local ok, raw = pcall(function()
		return recentMap:GetAsync(tostring(userId))
	end)
	-- Best-effort: a failed read means this player's cooldown isn't
	-- enforced for this queue visit. Queueing them is better than
	-- refusing to during a MemoryStore wobble.
	return if ok then MatchmakingLogic.decodeRecent(raw) else {}
end

local function recordRecentOpponents(group: GroupRecord)
	local stamp = now()
	for _, userId in group.members do
		local ok = pcall(function()
			recentMap:UpdateAsync(tostring(userId), function(raw: any): any
				return {
					list = MatchmakingLogic.mergeRecent(
						MatchmakingLogic.decodeRecent(raw),
						userId,
						group.members,
						stamp,
						config.rematchCooldownSeconds,
						config.recentOpponentsCap
					),
				}
			end, config.rematchCooldownSeconds)
		end)
		if not ok then
			warn(string.format("MatchmakingService: recent-opponent write for %d failed", userId))
		end
	end
end

local function tryHoldLease(): boolean
	local held = false
	local ok = pcall(function()
		metaMap:UpdateAsync(LEASE_KEY, function(raw: any): any
			-- Absent means lapsed: its TTL is the only expiry, so no clock
			-- comparison between servers is needed.
			if type(raw) ~= "table" or raw.holder == myJobId then
				held = true
				return { holder = myJobId }
			end
			held = false
			return nil
		end, config.leaseTtlSeconds)
	end)
	return ok and held
end

local function readPage(): ({ Entry }?, boolean)
	local ok, rows = pcall(function()
		-- The bound arguments are declared non-optional in the type defs
		-- but are optional at runtime; see LeaderboardService's note.
		return queueMap:GetRangeAsync(Enum.SortDirection.Ascending, config.queuePageSize, nil, nil)
	end)
	if not ok or type(rows) ~= "table" then
		return nil, false
	end
	local entries: { Entry } = {}
	for _, row in rows :: { { key: string, value: any } } do
		local entry = MatchmakingLogic.decodeEntry(row.value)
		if entry ~= nil then
			table.insert(entries, entry)
		end
	end
	return entries, #rows >= config.queuePageSize
end

-- ===== forming a group (lease holder only) ================================

local function formGroup(group: MatchmakingLogic.FormedGroup): string?
	-- Reserve BEFORE claiming: if it fails nobody has been touched, and if
	-- a claim fails later the reserved server is simply never used (it
	-- doesn't start until someone teleports to it). The yield happens
	-- before `started`, so it doesn't eat into the commit deadline.
	local destination: MatchmakingLogic.Destination? = nil
	if destinationProvider == nil and destinationRequired then
		return nil
	end
	if destinationProvider ~= nil then
		destination = destinationProvider()
		if destination == nil then
			return nil
		end
	end
	local groupId = if destination then destination.groupId else HttpService:GenerateGUID(false)
	-- P5-3: the ballot goes into the record at commit, weighted by the
	-- members' recent maps, which their entries already carry. Drawn
	-- here rather than by the destination provider so the vote also
	-- runs in Studio, where nothing is reserved.
	local ballot = (Loader.get("VoteService") :: any).drawBallot(group.members) :: MatchmakingLogic.Ballot
	local started = os.clock()
	local attempted: { number } = {}

	local allClaimed = true
	for _, member in group.members do
		table.insert(attempted, member.userId)
		local ok, written = casEntry(member.userId, function(current: Entry?): Entry?
			return MatchmakingLogic.claim(current, groupId)
		end, config.entryTtlSeconds)
		if not ok or written == nil then
			allClaimed = false
			break
		end
	end

	-- A former that stalled past its deadline gives up rather than
	-- committing claims the owners may already be reverting.
	if allClaimed and os.clock() - started < config.claimCommitDeadlineSeconds then
		local record =
			MatchmakingLogic.newGroupRecord(groupId, group.members, group.npcSlots, now(), myJobId, destination, ballot)
		-- THE COMMIT POINT. One write to one fresh key: the group exists
		-- or it doesn't.
		local ok = pcall(function()
			groupMap:SetAsync(groupId, record, config.groupRecordTtlSeconds)
		end)
		if ok then
			task.spawn(recordRecentOpponents, record)
			return groupId
		end
	end

	-- Roll back, including the member whose claim errored (the write may
	-- have landed anyway). release only undoes THIS token, so it can't
	-- disturb anything another server did in the meantime.
	for _, userId in attempted do
		casEntry(userId, function(current: Entry?): Entry?
			return MatchmakingLogic.release(current, groupId)
		end, config.entryTtlSeconds)
	end
	return nil
end

-- ===== acting on our own players' entries =================================

type PendingDepartures = { [string]: { group: GroupRecord, players: { Player } } }

local function handleOwnEntry(entry: Entry, pending: PendingDepartures)
	if entry.jobId ~= myJobId then
		return
	end
	local player = Players:GetPlayerByUserId(entry.userId)
	local ticket = if player then tickets[player] else nil

	if ticket == nil then
		-- Ours, but nobody here is waiting on it: a leave whose write
		-- failed, or a player who has gone. Retry the leave so the entry
		-- stops being claimable.
		if entry.state == "Waiting" or entry.state == "Claimed" then
			casEntry(entry.userId, function(current: Entry?): Entry?
				return MatchmakingLogic.leave(current, myJobId)
			end, config.departedTtlSeconds)
		end
		return
	end
	if ticket.status ~= "Waiting" or player == nil then
		return
	end
	if entry.state ~= "Claimed" or entry.groupId == nil then
		ticket.claimSeen = nil
		return
	end

	local groupId = entry.groupId :: string
	local seen = ticket.claimSeen
	if seen == nil or seen.groupId ~= groupId then
		seen = { groupId = groupId, at = os.clock() }
		ticket.claimSeen = seen
	end

	local group: GroupRecord? = nil
	if pending[groupId] ~= nil then
		group = pending[groupId].group
	else
		local ok, fetched = fetchGroup(groupId)
		if not ok then
			return -- can't tell; waiting is always safe
		end
		group = fetched
	end
	local listed = group ~= nil and table.find(group.members, entry.userId) ~= nil

	local action = MatchmakingLogic.ownerActionForClaim(
		listed,
		os.clock() - (seen :: { groupId: string, at: number }).at,
		config.staleClaimRevertSeconds
	)
	if action == "Depart" then
		local ok, written = casEntry(entry.userId, function(current: Entry?): Entry?
			return MatchmakingLogic.depart(current, groupId)
		end, config.departedTtlSeconds)
		if ok and written ~= nil then
			ticket.status = "Departing"
			ticket.claimSeen = nil
			local bucket = pending[groupId]
			if bucket == nil then
				bucket = { group = group :: GroupRecord, players = {} }
				pending[groupId] = bucket
			end
			table.insert((bucket :: any).players, player)
		end
	elseif action == "Revert" then
		casEntry(entry.userId, function(current: Entry?): Entry?
			return MatchmakingLogic.release(current, groupId)
		end, config.entryTtlSeconds)
		ticket.claimSeen = nil
	end
end

local function dispatch(pending: PendingDepartures)
	for _, bucket in pending do
		for _, player in bucket.players do
			sendState(player, { status = "MatchFound" })
		end
		task.spawn(departureHandler, bucket.players, bucket.group)
	end
end

-- ===== the UI =============================================================

local UNAVAILABLE_MESSAGE = "Matchmaking is having trouble. You're still in line - hang tight."

-- `practice`: which tickets `entries` describe - the global page's
-- ranked ones, or this server's practice queue.
local function broadcastStatus(entries: { Entry }?, pageWasFull: boolean, practice: boolean)
	local unavailable = not practice and consecutiveFailures >= config.unavailableAfterFailures
	local stamp = now()
	for player, ticket in tickets do
		if ticket.status == "Waiting" and ticket.practice == practice then
			if unavailable or entries == nil then
				if unavailable then
					sendState(player, { status = "Unavailable", message = UNAVAILABLE_MESSAGE })
				end
			else
				local status = MatchmakingLogic.queueStatus(entries, player.UserId, stamp, logicConfig, pageWasFull)
				sendState(player, {
					status = "Waiting",
					position = status.position,
					queueSize = status.queueSize,
					queueSizeIsLowerBound = status.queueSizeIsLowerBound,
					estimatedWaitSeconds = status.estimatedWaitSeconds,
					practice = practice,
				})
			end
		end
	end
end

-- ===== the loops ==========================================================

-- ===== the queue summary (matchmaking.md, partition ceiling) ==============
--
-- The page read costs one unit per entry on the queue's one partition,
-- which capped hub servers × queue length at ~1,000. So the lease holder
-- alone reads it and publishes a summary into metaMap (hash-map keys
-- spread across partitions); every other server reads one shard for 1
-- unit. A stale or missing summary (lease handover, a stalled holder)
-- sends a server back to the page for that tick, so nothing waits on it.

local function readSummary(): ({ Entry }?, boolean)
	local shard = math.random(1, config.summaryShardCount)
	local ok, raw = pcall(function()
		return metaMap:GetAsync(MatchmakingLogic.summaryShardKey(shard))
	end)
	if not ok then
		return nil, false
	end
	local summary = MatchmakingLogic.decodeSummary(raw)
	if
		summary == nil or not MatchmakingLogic.isSummaryFresh(summary.publishedAt, now(), config.summaryStaleSeconds)
	then
		return nil, false
	end
	return summary.entries, summary.pageWasFull
end

local function publishSummary(entries: { Entry }, pageWasFull: boolean)
	local value = MatchmakingLogic.encodeSummary(entries, pageWasFull, now())
	for shard = 1, config.summaryShardCount do
		-- A shard that fails stays old and goes stale; its readers fall
		-- back to the page, so no retry here.
		pcall(function()
			metaMap:SetAsync(MatchmakingLogic.summaryShardKey(shard), value, config.summaryTtlSeconds)
		end)
	end
end

local function tick()
	-- The lease is held even with the kill switch on: the holder still
	-- publishes the summary everyone else reads.
	local holdsLease = tryHoldLease()
	local entries: { Entry }?, pageWasFull = nil, false
	if not holdsLease then
		entries, pageWasFull = readSummary()
	end
	if entries == nil then
		entries, pageWasFull = readPage()
	end
	if entries == nil then
		consecutiveFailures += 1
		broadcastStatus(nil, false, false)
		return
	end
	consecutiveFailures = 0
	local page = entries :: { Entry }

	local pending: PendingDepartures = {}
	for _, entry in page do
		handleOwnEntry(entry, pending)
	end
	dispatch(pending)

	if holdsLease then
		-- P8-5 kill switch: no new groups form, but owned entries above are
		-- still serviced, so a group formed before the switch still departs.
		if Loader.get("LiveConfig").flags().matchmakingEnabled then
			for _, group in MatchmakingLogic.selectGroups(page, now(), logicConfig) do
				local groupId = formGroup(group)
				if groupId ~= nil then
					local userIds: { number } = {}
					for _, member in group.members do
						table.insert(userIds, member.userId)
					end
					page = MatchmakingLogic.markClaimed(page, userIds, groupId)
				end
			end
		end
		publishSummary(page, pageWasFull)
	end

	broadcastStatus(page, pageWasFull, false)
end

-- ===== the practice hub's own queue =======================================

-- formGroup's practice twin. No claims to make: the local entries are
-- this server's alone, so writing the group record is the whole commit.
-- On failure nobody is touched, and the next tick tries again.
local function formPracticeGroup(group: MatchmakingLogic.FormedGroup): GroupRecord?
	local destination: MatchmakingLogic.Destination? = nil
	if destinationProvider == nil and destinationRequired then
		return nil
	end
	if destinationProvider ~= nil then
		destination = destinationProvider()
		if destination == nil then
			return nil
		end
	end
	local groupId = if destination then destination.groupId else HttpService:GenerateGUID(false)
	local ballot = (Loader.get("VoteService") :: any).drawBallot(group.members) :: MatchmakingLogic.Ballot
	local record = MatchmakingLogic.newGroupRecord(
		groupId,
		group.members,
		group.npcSlots,
		now(),
		myJobId,
		destination,
		ballot,
		{ returnAccessCode = if destination then destination.returnAccessCode else nil }
	)
	local ok = pcall(function()
		groupMap:SetAsync(groupId, record, config.groupRecordTtlSeconds)
	end)
	return if ok then record else nil
end

-- Parties travel whole: the practice selector groups entries by this.
local function partyUnitOf(userId: number): string
	return (Loader.get("PartyService") :: any).unitOf(userId)
end

local function practiceTick()
	local entries: { Entry } = {}
	for player, entry in practiceEntries do
		local ticket = tickets[player]
		if ticket ~= nil and ticket.status == "Waiting" then
			table.insert(entries, entry)
		end
	end
	if Loader.get("LiveConfig").flags().matchmakingEnabled then
		local group =
			MatchmakingLogic.selectPracticeGroup(entries, now(), #Players:GetPlayers(), logicConfig, partyUnitOf)
		if group ~= nil then
			local record = formPracticeGroup(group)
			if record ~= nil then
				local players: { Player } = {}
				for _, member in group.members do
					local player = Players:GetPlayerByUserId(member.userId)
					local ticket = if player then tickets[player] else nil
					if player ~= nil and ticket ~= nil then
						ticket.status = "Departing"
						practiceEntries[player] = nil
						table.insert(players, player)
					end
				end
				dispatch({ [record.groupId] = { group = record, players = players } })
				entries = {}
				for _, entry in practiceEntries do
					table.insert(entries, entry)
				end
			end
		end
	end
	broadcastStatus(entries, false, true)
end

local function writeFreshEntry(player: Player, ticket: Ticket): boolean
	local DataService = Loader.get("DataService") :: any
	local fresh = MatchmakingLogic.newEntry(
		player.UserId,
		myJobId,
		ticket.enqueuedAt,
		DataService.getStreak(player),
		fetchRecent(player.UserId),
		-- P5-3: best-effort, like the avoid list. A failed read only
		-- means this player's history doesn't weight the ballot.
		(Loader.get("VoteService") :: any).fetchRecentMaps(player.UserId)
	)
	local ok = casEntry(player.UserId, function(current: Entry?): Entry?
		return MatchmakingLogic.join(current, fresh)
	end, config.entryTtlSeconds)
	return ok
end

-- The heartbeat, and the fallback path for anything the page read
-- can't see: entries beyond the first page, and entries that expired
-- during an outage.
local function refreshOwnEntries()
	local pending: PendingDepartures = {}
	for player, ticket in tickets do
		if ticket.status == "Waiting" and not ticket.practice then
			local ok, _, observed = casEntry(player.UserId, function(current: Entry?): Entry?
				return MatchmakingLogic.refresh(current, myJobId)
			end, config.entryTtlSeconds)
			if ok and tickets[player] == ticket then
				if observed == nil or observed.jobId ~= myJobId or observed.state == "Left" then
					-- Gone (expired, or lost to a failed leave retry): put it
					-- back at the ticket's original place.
					writeFreshEntry(player, ticket)
				elseif observed.state == "Claimed" then
					handleOwnEntry(observed, pending)
				end
			end
		end
	end
	dispatch(pending)
end

-- ===== intents ============================================================

-- The practice queue (design-decisions.md Q7). Nothing to write: the
-- entries live here only. No avoid list (the rematch cooldown doesn't
-- apply) and no streak (nothing reads it, and a practice match never
-- touches it). The leader queues the whole party at once, with one
-- enqueuedAt, so the selector sees them as one unit. A requeue after a
-- failed teleport (`preservedEnqueuedAt`) puts back only that player.
local function joinPractice(player: Player, preservedEnqueuedAt: number?, message: string?)
	local PartyService = Loader.get("PartyService") :: any
	local DataService = Loader.get("DataService") :: any
	local members: { Player } = { player }
	if preservedEnqueuedAt == nil then
		if not PartyService.isLeader(player) then
			sendState(player, { status = "Unavailable", message = "Your party leader starts the practice queue." })
			return
		end
		members = {}
		for _, userId in PartyService.membersOf(player) do
			local member = Players:GetPlayerByUserId(userId)
			if member == nil or tickets[member] ~= nil or not DataService.isLoaded(member) then
				sendState(player, {
					status = "Unavailable",
					message = "Someone in your party is already queued or still loading.",
				})
				return
			end
			table.insert(members, member)
		end
	end

	local enqueuedAt = preservedEnqueuedAt or now()
	for _, member in members do
		tickets[member] = { status = "Waiting", enqueuedAt = enqueuedAt, claimSeen = nil, practice = true }
		practiceEntries[member] = MatchmakingLogic.newEntry(member.UserId, myJobId, enqueuedAt, 0, {}, {})
		sendState(member, { status = "Waiting", message = message, practice = true })
	end
end

local leaveQueue: (player: Player, fromIntent: boolean) -> ()

-- Drops these players' practice tickets that haven't departed yet: their
-- party changed, so the unit that queued no longer exists. Anyone now in
-- a party also leaves the ranked queue, which is solo only.
local function cancelPractice(players: { Player }, message: string?)
	local PartyService = Loader.get("PartyService") :: any
	for _, player in players do
		local ticket = tickets[player]
		if ticket == nil or ticket.status == "Departing" then
			continue
		end
		if ticket.practice then
			tickets[player] = nil
			practiceEntries[player] = nil
			sendState(player, { status = "Idle", message = message })
		elseif #PartyService.membersOf(player) > 1 then
			leaveQueue(player, false)
			sendState(player, { status = "Idle", message = "You joined a party, so you've left the ranked queue." })
		end
	end
end

-- `message` explains a requeue (P5-2's failed teleport) and rides on the
-- Joining and Waiting states so the client can show why they're back.
-- `practice`: the Practice button. Forced on a private hub.
local function joinQueue(player: Player, preservedEnqueuedAt: number?, message: string?, practice: boolean?)
	if not active then
		sendState(player, { status = "Unavailable", message = "Matchmaking isn't available on this server." })
		return
	end
	local existing = tickets[player]
	if existing ~= nil then
		sendState(player, { status = existing.status })
		return
	end
	if not Loader.get("LiveConfig").flags().matchmakingEnabled then
		sendState(player, { status = "Unavailable", message = "Matchmaking is paused for a moment. Try again soon." })
		return
	end
	local DataService = Loader.get("DataService") :: any
	if not DataService.isLoaded(player) then
		sendState(player, { status = "Unavailable", message = "Your data is still loading - try again in a moment." })
		return
	end

	if practiceHub or practice == true then
		joinPractice(player, preservedEnqueuedAt, message)
		return
	end
	-- Ranked is solo (design-decisions.md Q7 condition 2): parties are
	-- safe only where nothing is at stake.
	if #(Loader.get("PartyService") :: any).membersOf(player) > 1 then
		sendState(player, {
			status = "Unavailable",
			message = "Parties play Practice only. Leave your party to play ranked.",
		})
		return
	end

	local ticket: Ticket =
		{ status = "Joining", enqueuedAt = preservedEnqueuedAt or now(), claimSeen = nil, practice = false }
	tickets[player] = ticket

	sendState(player, { status = "Joining", message = message })

	local ok = writeFreshEntry(player, ticket)
	if tickets[player] ~= ticket then
		return -- left while the write was in flight; the leave path owns cleanup
	end
	if not ok then
		tickets[player] = nil
		sendState(player, { status = "Unavailable", message = "Couldn't reach matchmaking. Try again in a moment." })
		return
	end
	ticket.status = "Waiting"
	sendState(player, { status = "Waiting", message = message })
	-- A requeue after a failed teleport carries its old enqueuedAt and is
	-- the same attempt, not a new Matchmaking funnel session.
	if preservedEnqueuedAt == nil then
		Loader.get("Telemetry").userQueued(player)
	end
end

function leaveQueue(player: Player, fromIntent: boolean)
	local ticket = tickets[player]
	if ticket == nil then
		if fromIntent then
			sendState(player, { status = "Idle" })
		end
		return
	end
	if ticket.status == "Departing" and fromIntent then
		-- Past the point of no return: the group is committed and the
		-- teleport is being prepared. Leaving now would only strand them.
		sendState(player, { status = "MatchFound", message = "Your match is already on its way." })
		return
	end
	tickets[player] = nil
	if ticket.practice then
		practiceEntries[player] = nil
		-- The party queued as one, so it leaves as one.
		local others: { Player } = {}
		for _, userId in (Loader.get("PartyService") :: any).membersOf(player) do
			local member = Players:GetPlayerByUserId(userId)
			if member ~= nil and member ~= player then
				table.insert(others, member)
			end
		end
		cancelPractice(others, "A party member left the queue.")
		if fromIntent then
			sendState(player, { status = "Idle" })
		end
		return
	end
	local userId = player.UserId
	task.spawn(function()
		casEntry(userId, function(current: Entry?): Entry?
			return MatchmakingLogic.leave(current, myJobId)
		end, config.departedTtlSeconds)
	end)
	if fromIntent then
		sendState(player, { status = "Idle" })
	end
end

-- ===== public API =========================================================

-- P5-2 installs the teleport here. Called once per departed group with
-- the members on THIS server, which may be fewer than group.members
-- when the group spans servers or someone left late.
local function setDepartureHandler(handler: DepartureHandler)
	departureHandler = handler
end

-- P5-2's teleport-failed path: back in line at the original place.
-- The Departing ticket still remembers that place, so the caller
-- needn't pass it.
local function requeue(player: Player, enqueuedAt: number?, message: string?)
	local ticket = tickets[player]
	local practice = false
	if ticket ~= nil and ticket.status == "Departing" then
		enqueuedAt = enqueuedAt or ticket.enqueuedAt
		practice = ticket.practice
		tickets[player] = nil
	end
	task.spawn(joinQueue, player, enqueuedAt, message, practice)
end

local function isQueued(player: Player): boolean
	return tickets[player] ~= nil
end

-- P5-5: claimed into a group and voting or travelling. True until the
-- player leaves, or a failed teleport requeues them.
local function isDeparting(player: Player): boolean
	local ticket = tickets[player]
	return ticket ~= nil and ticket.status == "Departing"
end

-- P5-2 installs the reservation here. Called by the former once per
-- group it is about to claim; returning nil skips that group this tick.
local function setDestinationProvider(provider: DestinationProvider?)
	destinationProvider = provider
end

-- P5-2's status messages while a Departing player travels. Kept here so
-- the one QueueState remote has a single owner.
local function notify(player: Player, status: string, message: string?)
	sendState(player, { status = status, message = message })
end

local MatchmakingService: Loader.Service = {
	name = "MatchmakingService",
	dependencies = { "NetGuard", "ConfigValidator", "DataService", "LiveConfig", "Telemetry" },

	setDepartureHandler = setDepartureHandler,
	setDestinationProvider = setDestinationProvider,
	requeue = requeue,
	isQueued = isQueued,
	isDeparting = isDeparting,
	notify = notify,

	cancelPractice = cancelPractice,

	-- design-decisions.md Q7: this hub's matches are practice matches.
	isPracticeHub = function(): boolean
		return practiceHub
	end,

	-- This server is a hub that runs the queue (and so parties).
	isActive = function(): boolean
		return active
	end,
}

function MatchmakingService:init()
	-- hubPlaceId 0 means "not published yet": run in Studio so the queue
	-- can be tested, and nowhere else. A live match server with an unset
	-- id must not start forming groups.
	if config.hubPlaceId == 0 then
		active = RunService:IsStudio()
	else
		active = game.PlaceId == config.hubPlaceId
	end
	if active and not memoryStoreOk then
		warn("MatchmakingService: MemoryStore unavailable, queue disabled - " .. tostring(memoryStoreErr))
		active = false
	end
	-- QueueController reads this to say the queue here is practice.
	if active and practiceHub then
		workspace:SetAttribute("PracticeServer", true)
	end

	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("QueueJoinIntent", function(player: Player, payload: any)
		task.spawn(joinQueue, player, nil, nil, payload.mode == "Practice")
	end)
	NetGuard.on("QueueLeaveIntent", function(player: Player, _payload: any)
		leaveQueue(player, true)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		leaveQueue(player, false)
	end)
end

function MatchmakingService:start()
	if not active then
		return
	end

	-- The practice queue runs on every hub, on its own loop: it never
	-- touches the queue's MemoryStore structures, so the ranked loop's
	-- backoff isn't its concern, and its reservation never delays a
	-- ranked tick.
	task.spawn(function()
		while true do
			local ok, err = pcall(function(): any
				practiceTick()
				return nil
			end)
			if not ok then
				warn("MatchmakingService: practice tick errored: " .. tostring(err))
			end
			task.wait(config.formationTickSeconds)
		end
	end)

	-- A private hub has no ranked queue at all.
	if practiceHub then
		return
	end

	task.spawn(function()
		while true do
			local ok, err = pcall(function(): any
				tick()
				return nil
			end)
			if not ok then
				warn("MatchmakingService: tick errored: " .. tostring(err))
			end
			task.wait(
				config.formationTickSeconds
					+ MatchmakingLogic.backoffSeconds(
						consecutiveFailures,
						config.backoffBaseSeconds,
						config.backoffCapSeconds
					)
			)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(config.refreshIntervalSeconds)
			local ok, err = pcall(function(): any
				refreshOwnEntries()
				return nil
			end)
			if not ok then
				warn("MatchmakingService: refresh errored: " .. tostring(err))
			end
		end
	end)

	-- A clean shutdown marks our players' entries Left rather than
	-- leaving them claimable for up to entryTtlSeconds. A crash skips
	-- this, and the TTL covers it.
	game:BindToClose(function()
		local remaining = 0
		for player, ticket in tickets do
			if ticket.practice then
				continue -- never in MemoryStore
			end
			remaining += 1
			local userId = player.UserId
			task.spawn(function()
				casEntry(userId, function(current: Entry?): Entry?
					return MatchmakingLogic.leave(current, myJobId)
				end, config.departedTtlSeconds)
				remaining -= 1
			end)
		end
		local deadline = os.clock() + 5
		while remaining > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return MatchmakingService
