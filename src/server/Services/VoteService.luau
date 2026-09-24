--!strict
-- The hub's map vote (P5-3). The decisions live in
-- src/server/VoteLogic.luau (tested headlessly); docs/voting.md walks
-- the flow, the failure cases and the board UI.
--
-- ===== THE FLOW ============================================================
--
--   1. The former draws a 3-4 map ballot (drawBallot), weighted against
--      the members' recent maps, and commits it inside the group record
--      with a provisional map.
--   2. Every hub server holding members runs one session per group
--      (runVote, called by the departure handler once its players are
--      Departed). It polls the record, pushes the board to its own
--      players, and writes their votes with compare-and-sets.
--   3. At the deadline, or as soon as every member has voted, the first
--      server to get there locks: one compare-and-set writes the result
--      and sets the record's mapId to the winner. Everyone else reads
--      that result back, so every server shows, and travels to, the
--      same map even though the tie-break is random.
--   4. The winner is revealed for revealSeconds, each player's recent
--      maps are updated, and runVote returns the map for the teleport.
--
-- ===== WHY THE CLIENT CAN'T CHEAT IT =======================================
--
-- MapVoteIntent carries only a map id. The group is found from this
-- server's own session for the sender, the voter is the sender's own
-- UserId, and castVote refuses any map not on that group's ballot, any
-- non-member, and any vote after the lock. A client can't vote twice
-- (one vote per userId, replaced on change), can't vote in another
-- group, and can't see the access code (boardState copies fields out
-- one by one).
--
-- ===== WHEN MEMORYSTORE IS DOWN ============================================
--
-- The record already names a provisional map from the ballot. If no
-- server can lock or read a result by deadline + lockGraceSeconds, each
-- owner stops waiting and travels. The match server loads whatever
-- mapId its manifest read finds, so players still get a map from the
-- ballot, just not necessarily the one they voted for. The board says
-- the vote couldn't be counted rather than pretending it was.

local Players = game:GetService("Players")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Maps = require(ReplicatedStorage.Shared.Config.Maps)
local MatchmakingLogic = require(ServerScriptService.Server.MatchmakingLogic)
local VoteLogic = require(ServerScriptService.Server.VoteLogic)

type GroupRecord = MatchmakingLogic.GroupRecord
type Entry = MatchmakingLogic.Entry

local config = GameConfig.vote
local matchmakingConfig = GameConfig.matchmaking

local weighting: VoteLogic.Weighting = {
	floorWeight = config.recentFloorWeight,
	decay = config.recentDecay,
}

-- Nil in a never-published place, where MemoryStoreService throws. Every
-- use below is already inside a pcall, so a nil map reads as a failed
-- call rather than taking the server down at require time.
local groupMap: MemoryStoreHashMap, recentMapsMap: MemoryStoreHashMap = nil :: any, nil :: any
pcall(function()
	groupMap = MemoryStoreService:GetHashMap(matchmakingConfig.groupMapName)
	recentMapsMap = MemoryStoreService:GetHashMap(config.recentMapName)
end)

-- Roblox's Random: the tie-break and the ballot draw. VoteLogic takes it
-- as a parameter so the specs can pass a seeded stand-in.
-- Cast because the engine's Random is a class type, not the structural
-- table VoteLogic.Rng describes; its methods match.
local rng: VoteLogic.Rng = Random.new() :: any

-- One per group this server holds members of. `players` grows if a
-- later tick departs more of this server's members into the same group.
type Session = {
	groupId: string,
	players: { Player },
	record: GroupRecord,
	deadline: number, -- wall clock
	giveUpAt: number, -- wall clock
	done: boolean,
	mapId: string?,
}

local sessions: { [string]: Session } = {}
local sessionOf: { [Player]: Session } = {}

local function now(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

local function enabledMapIds(): { string }
	local ids: { string } = {}
	for _, entry in Maps do
		if entry.def.enabled then
			table.insert(ids, entry.def.id)
		end
	end
	return ids
end

-- ===== MemoryStore =========================================================

-- (ok, record). ok = false means "couldn't tell", never "absent".
local function fetchRecord(groupId: string): (boolean, GroupRecord?)
	local ok, raw = pcall(function()
		return groupMap:GetAsync(groupId)
	end)
	if not ok then
		return false, nil
	end
	return true, MatchmakingLogic.decodeGroup(raw)
end

-- Runs `change` against the group record as a compare-and-set. `change`
-- returns the new record or nil to cancel. A missing or malformed
-- record is never re-created: the record's existence is matchmaking's
-- commit point, not ours to invent.
local function casRecord(groupId: string, change: (GroupRecord) -> GroupRecord?): (boolean, GroupRecord?)
	local written: GroupRecord? = nil
	local ok, err = pcall(function()
		groupMap:UpdateAsync(groupId, function(raw: any): any
			local current = MatchmakingLogic.decodeGroup(raw)
			written = if current then change(current) else nil
			return written
		end, matchmakingConfig.groupRecordTtlSeconds)
	end)
	if not ok then
		warn(string.format("VoteService: group %s update failed: %s", groupId, tostring(err)))
		return false, nil
	end
	return true, written
end

local function pushRecentMap(userId: number, mapId: string)
	local ok, err = pcall(function()
		recentMapsMap:UpdateAsync(tostring(userId), function(raw: any): any
			local list = MatchmakingLogic.decodeStrings(if type(raw) == "table" then raw.list else nil)
			return { list = VoteLogic.pushRecent(list, mapId, config.recentMapsCap) }
		end, config.recentMapsTtlSeconds)
	end)
	if not ok then
		warn(string.format("VoteService: recent-map write for %d failed: %s", userId, tostring(err)))
	end
end

-- ===== the board ===========================================================

local function sendBoard(session: Session, extra: { [string]: any }?)
	local secondsLeft = session.deadline - now()
	for _, player in session.players do
		if player.Parent ~= Players then
			continue
		end
		local board: { [string]: any } =
			VoteLogic.boardState(session.groupId, session.record, player.UserId, secondsLeft) :: any
		if extra then
			for key, value in extra do
				board[key] = value
			end
		end
		Net.fireClient("MapVoteState", player, board)
	end
end

local function closeBoard(session: Session)
	for _, player in session.players do
		if player.Parent == Players then
			Net.fireClient("MapVoteState", player, { closed = true })
		end
	end
end

-- ===== the session =========================================================

local function tryLock(session: Session)
	local ok, written = casRecord(session.groupId, function(current: GroupRecord): GroupRecord?
		local result = VoteLogic.lock(current, rng)
		if result == nil then
			return nil
		end
		local copy = table.clone(current)
		copy.result = result
		copy.mapId = result.winner
		return copy
	end)
	if ok and written ~= nil then
		session.record = written
	end
	-- Refused means another server locked first; the next read picks up
	-- its result. An error is retried on the next poll until giveUpAt.
end

-- Polls until the result is known or it's time to give up. Returns the
-- map to travel to and whether it came from a locked vote.
local function awaitResult(session: Session): (string?, boolean)
	while true do
		local ok, fresh = fetchRecord(session.groupId)
		if ok and fresh ~= nil then
			session.record = fresh
		end
		local t = now()
		if session.record.result == nil and VoteLogic.shouldLock(session.record, t, session.deadline) then
			tryLock(session)
		end
		local result = session.record.result
		if result ~= nil then
			return result.winner, true
		end
		if t >= session.giveUpAt then
			return session.record.mapId, false
		end
		sendBoard(session)
		task.wait(config.pollSeconds)
	end
end

local function runSession(session: Session)
	local mapId, counted = awaitResult(session)
	session.mapId = mapId

	if counted then
		sendBoard(session)
	else
		warn(
			string.format(
				"VoteService: group %s couldn't lock its vote; travelling on provisional map %s",
				session.groupId,
				tostring(mapId)
			)
		)
		sendBoard(session, {
			locked = true,
			winner = mapId,
			fallback = true, -- the client says the vote couldn't be counted
		})
	end
	task.wait(config.revealSeconds)
	closeBoard(session)

	if mapId ~= nil then
		for _, player in session.players do
			task.spawn(pushRecentMap, player.UserId, mapId)
		end
	end
end

-- ===== intents =============================================================

local function onVoteIntent(player: Player, payload: { mapId: string })
	local session = sessionOf[player]
	if session == nil or session.done or session.record.result ~= nil then
		return
	end
	local refusal: string? = nil
	local ok, written = casRecord(session.groupId, function(current: GroupRecord): GroupRecord?
		local votes, reason = VoteLogic.castVote(current, player.UserId, payload.mapId)
		refusal = reason
		if votes == nil then
			return nil
		end
		local copy = table.clone(current)
		copy.votes = votes
		return copy
	end)
	if ok and written ~= nil and sessions[session.groupId] == session and not session.done then
		session.record = written
		sendBoard(session) -- instant feedback, without waiting for the next poll
	elseif refusal ~= nil and refusal ~= "Unchanged" and refusal ~= "Locked" then
		-- A hand-rolled client, or a stale board: nothing to show the player.
		warn(string.format("VoteService: vote from %d refused (%s)", player.UserId, refusal))
	end
end

-- ===========================================================================

local VoteService: Loader.Service = {
	name = "VoteService",
	dependencies = { "NetGuard", "ConfigValidator" },

	-- The former's ballot for a group about to be claimed. Never yields.
	drawBallot = function(members: { Entry }): MatchmakingLogic.Ballot
		local recentLists: { { string } } = {}
		for _, entry in members do
			table.insert(recentLists, entry.recentMaps)
		end
		local maps = VoteLogic.drawBallot(enabledMapIds(), recentLists, config.ballotSize, weighting, rng)
		return { maps = maps, provisionalMapId = VoteLogic.provisionalMap(maps, rng) }
	end,

	-- Best-effort: {} on any failure. Read at queue join, onto the entry.
	fetchRecentMaps = function(userId: number): { string }
		local ok, raw = pcall(function()
			return recentMapsMap:GetAsync(tostring(userId))
		end)
		if not ok or type(raw) ~= "table" then
			return {}
		end
		return MatchmakingLogic.decodeStrings(raw.list)
	end,

	-- Called by the departure handler with this server's Departed members
	-- of `group`. Yields through the vote and the reveal, then returns
	-- the map they travel to. Several calls for the same group (members
	-- departed on different ticks) share one session.
	runVote = function(players: { Player }, group: GroupRecord): string?
		if #group.ballot == 0 then
			return group.mapId -- nothing to choose between
		end

		local session = sessions[group.groupId]
		if session ~= nil then
			for _, player in players do
				table.insert(session.players, player)
				sessionOf[player] = session
			end
			sendBoard(session)
			while not session.done do
				task.wait(0.1)
			end
			return session.mapId
		end

		local t = now()
		local deadline = VoteLogic.deadline(group.formedAt, config.voteSeconds, t)
		session = {
			groupId = group.groupId,
			players = table.clone(players),
			record = group,
			deadline = deadline,
			giveUpAt = deadline + config.lockGraceSeconds,
			done = false,
			mapId = group.mapId,
		}
		local live = session :: Session
		sessions[group.groupId] = live
		for _, player in players do
			sessionOf[player] = live
		end

		local ok, err = pcall(runSession, live)
		if not ok then
			warn(string.format("VoteService: vote for %s errored: %s", group.groupId, tostring(err)))
			closeBoard(live)
		end

		live.done = true
		sessions[group.groupId] = nil
		for _, player in live.players do
			if sessionOf[player] == live then
				sessionOf[player] = nil
			end
		end
		return live.mapId
	end,
}

function VoteService:init()
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("MapVoteIntent", function(player: Player, payload: any)
		task.spawn(onVoteIntent, player, payload)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		-- Their vote stays counted: they cast it as a member. Nothing
		-- else to do; the session skips players who have left.
		sessionOf[player] = nil
	end)
end

return VoteService
