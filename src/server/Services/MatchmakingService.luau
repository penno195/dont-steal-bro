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
--   1. Reads the oldest page of the shared queue (one GetRangeAsync).
--   2. For entries it OWNS (entry.jobId == this server): acts on any
--      claim. If the group record exists it departs the player. If it
--      never appears it reverts the claim. See MatchmakingLogic's header
--      for why this is the only place a player is committed to a group.
--   3. Tries to hold the formation lease. The holder alone runs
--      selectGroups on the page and claims members.
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

local function formGroup(group: MatchmakingLogic.FormedGroup): boolean
	-- Reserve BEFORE claiming: if it fails nobody has been touched, and if
	-- a claim fails later the reserved server is simply never used (it
	-- doesn't start until someone teleports to it). The yield happens
	-- before `started`, so it doesn't eat into the commit deadline.
	local destination: MatchmakingLogic.Destination? = nil
	if destinationProvider == nil and destinationRequired then
		return false
	end
	if destinationProvider ~= nil then
		destination = destinationProvider()
		if destination == nil then
			return false
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
			return true
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
	return false
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

local function broadcastStatus(entries: { Entry }?, pageWasFull: boolean)
	local unavailable = consecutiveFailures >= config.unavailableAfterFailures
	local stamp = now()
	for player, ticket in tickets do
		if ticket.status == "Waiting" then
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
				})
			end
		end
	end
end

-- ===== the loops ==========================================================

local function tick()
	local entries, pageWasFull = readPage()
	if entries == nil then
		consecutiveFailures += 1
		broadcastStatus(nil, false)
		return
	end
	consecutiveFailures = 0

	local pending: PendingDepartures = {}
	for _, entry in entries do
		handleOwnEntry(entry, pending)
	end
	dispatch(pending)

	if tryHoldLease() then
		for _, group in MatchmakingLogic.selectGroups(entries, now(), logicConfig) do
			formGroup(group)
		end
	end

	broadcastStatus(entries, pageWasFull)
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
		if ticket.status == "Waiting" then
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

-- `message` explains a requeue (P5-2's failed teleport) and rides on the
-- Joining and Waiting states so the client can show why they're back.
local function joinQueue(player: Player, preservedEnqueuedAt: number?, message: string?)
	if not active then
		sendState(player, { status = "Unavailable", message = "Matchmaking isn't available on this server." })
		return
	end
	local existing = tickets[player]
	if existing ~= nil then
		sendState(player, { status = existing.status })
		return
	end
	local DataService = Loader.get("DataService") :: any
	if not DataService.isLoaded(player) then
		sendState(player, { status = "Unavailable", message = "Your data is still loading - try again in a moment." })
		return
	end

	local ticket: Ticket = { status = "Joining", enqueuedAt = preservedEnqueuedAt or now(), claimSeen = nil }
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
end

local function leaveQueue(player: Player, fromIntent: boolean)
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
	if ticket ~= nil and ticket.status == "Departing" then
		enqueuedAt = enqueuedAt or ticket.enqueuedAt
		tickets[player] = nil
	end
	task.spawn(joinQueue, player, enqueuedAt, message)
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
	dependencies = { "NetGuard", "ConfigValidator", "DataService" },

	setDepartureHandler = setDepartureHandler,
	setDestinationProvider = setDestinationProvider,
	requeue = requeue,
	isQueued = isQueued,
	isDeparting = isDeparting,
	notify = notify,
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

	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("QueueJoinIntent", function(player: Player, _payload: any)
		task.spawn(joinQueue, player, nil)
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
		for player in tickets do
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
