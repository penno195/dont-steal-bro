--!strict
-- Hub-to-match travel (P5-2). Named MatchTeleportService so it never
-- shadows Roblox's own TeleportService. The decisions live in
-- src/server/TeleportLogic.luau (tested headlessly); docs/teleport.md
-- walks the whole flow, every failure case, and the TeleportData
-- tampering table.
--
-- ===== ON THE HUB ==========================================================
--
--   1. MatchmakingService's former asks `reserveDestination` for a
--      reserved match server BEFORE it claims anyone. The access code,
--      the map and the server's PrivateServerId (which becomes the group
--      id) go into the group record, so every hub server holding a
--      member sends them to the same place.
--   2. Each hub server's departure handler teleports its own members
--      together with TeleportAsync.
--   3. A failure (TeleportInitFailed, TeleportAsync throwing, or the
--      player still being here when the travel watchdog fires) goes
--      through TeleportLogic.classifyFailure: retry with backoff to the
--      same server, wait, or give up and requeue at the player's old
--      place with a message saying why. Nobody is left on a loading
--      screen: the watchdog guarantees every attempt ends one way or
--      the other.
--
-- ===== ON THE MATCH SERVER =================================================
--
--   1. Reads its own group record (the "manifest") from MemoryStore by
--      game.PrivateServerId. TeleportData is only compared against it.
--   2. Admits listed members, sends strays and late arrivals home.
--   3. Holds the round in WaitingForPlayers until everyone expected is
--      here with a loaded profile, or the grace window runs out, then
--      requests Loading. NPCService fills empty seats from the humans it
--      can see, never from any payload.
--
-- ===== PROFILE SESSION LOCKS ===============================================
--
-- The hub keeps each profile until PlayerRemoving, which fires once the
-- player has actually left for the match. It can't release earlier: a
-- failed teleport returns the player to the hub, still needing their
-- data. So the match server can ask for the profile while the hub still
-- holds it. ProfileStore resolves that itself: the waiting server asks
-- the holder (via MessagingService) to save and release, rechecks after
-- 5s, and steals the lock only after 40s. The arrival gate therefore
-- counts a player as ready only once DataService has loaded them, and
-- waits up to teleport.profileLoadGraceSeconds extra for it.

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Maps = require(ReplicatedStorage.Shared.Config.Maps)
local MatchmakingLogic = require(ServerScriptService.Server.MatchmakingLogic)
local TeleportLogic = require(ServerScriptService.Server.TeleportLogic)

type GroupRecord = MatchmakingLogic.GroupRecord

local config = GameConfig.teleport
local matchmakingConfig = GameConfig.matchmaking

local retryConfig: TeleportLogic.RetryConfig = {
	maxAttempts = config.maxAttempts,
	retryBaseSeconds = config.retryBaseSeconds,
	retryCapSeconds = config.retryCapSeconds,
}

local GATE_POLL_SECONDS = 0.25

local rng = Random.new()

local function enabledMapIds(): { string }
	local ids: { string } = {}
	for _, entry in Maps do
		if entry.def.enabled then
			table.insert(ids, entry.def.id)
		end
	end
	table.sort(ids)
	return ids
end

local function roll(n: number): number
	return rng:NextInteger(1, n)
end

-- ===========================================================================
-- HUB
-- ===========================================================================

type Travel = {
	group: GroupRecord,
	options: TeleportOptions,
	attempt: number,
	-- Bumped whenever an attempt's outcome is decided, so the watchdog
	-- of an attempt that already failed another way does nothing.
	token: number,
}

local travelling: { [Player]: Travel } = {}

local function matchmaking(): any
	return Loader.get("MatchmakingService")
end

-- The destination's map, used only when there is no vote: a ballot
-- needs at least two enabled maps (VoteLogic.drawBallot), and when one
-- is drawn its provisional map overrides this one in the record.
-- Uniform over enabled maps, or nil when none is registered yet (the
-- match server then falls back the same way).
local function pickMap(): string?
	local ids = enabledMapIds()
	if #ids == 0 then
		return nil
	end
	return ids[roll(#ids)]
end

-- The former's destination provider. Yields on the reservation.
local function reserveDestination(): MatchmakingLogic.Destination?
	-- VERIFY (docs/teleport.md): ReserveServerAsync is typed `...any` in
	-- the pinned definitions. Its older sibling ReserveServer returns
	-- (accessCode, privateServerId); this assumes the same order.
	local ok, accessCode, privateServerId = pcall(function(): (any, any)
		return (TeleportService :: any):ReserveServerAsync(config.matchPlaceId)
	end)
	if not ok or type(accessCode) ~= "string" or type(privateServerId) ~= "string" or privateServerId == "" then
		warn("MatchTeleportService: ReserveServerAsync failed: " .. tostring(if ok then "bad return" else accessCode))
		return nil
	end
	return { groupId = privateServerId, accessCode = accessCode, mapId = pickMap() }
end

local function giveUp(player: Player, message: string)
	travelling[player] = nil
	matchmaking().requeue(player, nil, message)
end

local handleFailure: (player: Player, reason: string, token: number?) -> ()

local function armWatchdog(player: Player, travel: Travel)
	local token = travel.token
	task.delay(config.travelWatchdogSeconds, function()
		if travelling[player] == travel and travel.token == token and player.Parent == Players then
			handleFailure(player, "Timeout", token)
		end
	end)
end

-- One attempt for any number of players heading to the same group. The
-- first attempt sends the whole local party together; retries go one
-- player at a time, to the same reserved server.
local function attempt(players: { Player }, options: TeleportOptions)
	local tokens: { [Player]: number } = {}
	for _, player in players do
		local travel = travelling[player]
		travel.attempt += 1
		travel.token += 1
		tokens[player] = travel.token
	end

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(config.matchPlaceId, players, options)
	end)

	for _, player in players do
		local travel = travelling[player]
		if travel == nil or travel.token ~= tokens[player] then
			continue -- left, or already decided while we yielded
		end
		if ok then
			armWatchdog(player, travel)
		else
			warn(string.format("MatchTeleportService: TeleportAsync threw for %d: %s", player.UserId, tostring(err)))
			handleFailure(player, "Error", travel.token)
		end
	end
end

handleFailure = function(player: Player, reason: string, token: number?)
	local travel = travelling[player]
	if travel == nil or (token ~= nil and travel.token ~= token) then
		return
	end
	local verdict = TeleportLogic.classifyFailure(reason, travel.attempt, retryConfig)
	if verdict.kind == "Wait" then
		return
	end
	travel.token += 1 -- this attempt is decided; its watchdog stands down

	if verdict.kind == "Requeue" then
		giveUp(player, verdict.message)
		return
	end
	matchmaking().notify(player, "Travelling", verdict.message)
	task.delay(verdict.delaySeconds, function()
		if travelling[player] == travel and player.Parent == Players then
			attempt({ player }, travel.options)
		end
	end)
end

-- MatchmakingService's departure handler: `players` are this server's
-- members of `group`, already committed (their entries are Departed).
local function onGroupDeparted(players: { Player }, group: GroupRecord)
	if group.accessCode == nil then
		-- Can't happen while this handler is installed (the provider is
		-- installed with it), but if it did, back in line beats stranded.
		for _, player in players do
			matchmaking().requeue(player, nil, "We couldn't find a server for your match.")
		end
		return
	end

	-- P5-5: a player frozen in the practice area when their match is
	-- ready is thawed now and travels anyway. Their Departing ticket
	-- keeps practice off them from here on.
	local PracticeService = Loader.get("PracticeService") :: any
	PracticeService.release(players)

	-- P5-3: the group votes on its map first. This yields until the vote
	-- locks (or gives up on the provisional map) and the winner has been
	-- revealed. The winner is already in the group record by then, which
	-- is what the match server actually loads.
	local mapId = (Loader.get("VoteService") :: any).runVote(players, group) :: string?

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = group.accessCode :: string
	-- A cosmetic hint, never trusted on arrival - see TeleportLogic's header.
	options:SetTeleportData(TeleportLogic.buildHint(group.groupId, mapId, group.npcSlots) :: any)

	local Telemetry = Loader.get("Telemetry") :: any
	local going: { Player } = {}
	for _, player in players do
		if player.Parent ~= Players then
			continue -- the match server treats them as a no-show
		end
		travelling[player] = { group = group, options = options, attempt = 0, token = 0 }
		matchmaking().notify(player, "Travelling", "Heading to your match...")
		Telemetry.userMatched(player.UserId, #group.members, group.npcSlots)
		table.insert(going, player)
	end
	if #going > 0 then
		attempt(going, options)
	end
end

local function startHub()
	local MatchmakingService = matchmaking()
	MatchmakingService.setDestinationProvider(reserveDestination)
	MatchmakingService.setDepartureHandler(onGroupDeparted)

	TeleportService.TeleportInitFailed:Connect(
		function(player: Player, result: Enum.TeleportResult, message: string, _placeId: number, _options: any)
			if travelling[player] == nil then
				return
			end
			warn(
				string.format("MatchTeleportService: %d failed to travel (%s): %s", player.UserId, result.Name, message)
			)
			handleFailure(player, result.Name, nil)
		end
	)

	Players.PlayerRemoving:Connect(function(player: Player)
		travelling[player] = nil
	end)

	-- Someone the match server sent home. The reason is a cosmetic hint
	-- that can only pick one of TeleportLogic's fixed messages.
	Players.PlayerAdded:Connect(function(player: Player)
		local joinData = player:GetJoinData()
		if joinData.SourcePlaceId ~= config.matchPlaceId then
			return
		end
		local message = TeleportLogic.returnMessage(joinData.TeleportData)
		if message ~= nil then
			matchmaking().notify(player, "Idle", message)
		end
	end)
end

-- ===========================================================================
-- MATCH SERVER
-- ===========================================================================

local manifest: TeleportLogic.Manifest? = nil
local manifestSettled = false
local gateClosed = false
local admitted: { [Player]: boolean } = {}
local pending: { Player } = {}
local firstHint: any = nil
local chosenMapId: string? = nil

local function sendHome(player: Player, reason: "Late" | "Stray")
	local message = TeleportLogic.returnMessage({ returnReason = reason }) or "Please rejoin."
	if matchmakingConfig.hubPlaceId == 0 then
		player:Kick(message)
		return
	end
	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ returnReason = reason } :: any)
	local ok = pcall(function()
		TeleportService:TeleportAsync(matchmakingConfig.hubPlaceId, { player }, options)
	end)
	if not ok then
		player:Kick(message)
	end
end

local function readManifest()
	local groupMap = MemoryStoreService:GetHashMap(matchmakingConfig.groupMapName)
	for tries = 1, config.manifestReadAttempts do
		local ok, raw = pcall(function(): any
			return groupMap:GetAsync(game.PrivateServerId)
		end)
		if ok then
			local record = MatchmakingLogic.decodeGroup(raw)
			if record ~= nil and record.groupId == game.PrivateServerId then
				manifest = {
					groupId = record.groupId,
					members = record.members,
					npcSlots = record.npcSlots,
					mapId = record.mapId,
				}
			else
				warn("MatchTeleportService: no group record for this server - running without a manifest")
			end
			break
		end
		warn(string.format("MatchTeleportService: manifest read %d failed: %s", tries, tostring(raw)))
		task.wait(TeleportLogic.backoffSeconds(tries, config.retryBaseSeconds, config.retryCapSeconds))
	end
	manifestSettled = true
end

local function adjudicate(player: Player)
	local hint = player:GetJoinData().TeleportData
	local flags = TeleportLogic.checkHint(hint, manifest, game.PrivateServerId)
	if #flags > 0 then
		-- threat-model.md §5: log mismatches. Nothing reads the hint's values.
		warn(
			string.format(
				"MatchTeleportService: TeleportData from %d disagrees: %s",
				player.UserId,
				table.concat(flags, ",")
			)
		)
	end

	local verdict = TeleportLogic.admission(player.UserId, manifest, gateClosed)
	if verdict == "Admit" then
		admitted[player] = true
		if firstHint == nil then
			firstHint = hint
		end
	else
		sendHome(player, if verdict == "Late" then "Late" else "Stray")
	end
end

local function counts(): (number, number)
	local DataService = Loader.get("DataService") :: any
	local present, loaded = 0, 0
	for player in admitted do
		if player.Parent == Players then
			present += 1
			if DataService.isLoaded(player) then
				loaded += 1
			end
		end
	end
	return present, loaded
end

local function startRound(present: number)
	gateClosed = true
	local source: TeleportLogic.MapSource
	chosenMapId, source = TeleportLogic.resolveMapId(manifest, firstHint, enabledMapIds(), roll)
	print(
		string.format(
			"MatchTeleportService: starting with %d human(s), map %s (%s)",
			present,
			tostring(chosenMapId),
			source
		)
	)

	local NPCService = Loader.get("NPCService") :: any
	NPCService.markArrivalGraceServed()
	local RoundService = Loader.get("RoundService") :: any
	RoundService.requestTransition("Loading")

	local Telemetry = Loader.get("Telemetry") :: any
	local mapLabel = chosenMapId or "none"
	Telemetry.roundStarted(RoundService.getRoundId(), mapLabel, present)
	Telemetry.mapPlayed(RoundService.getRoundId(), mapLabel, present)
end

local function runArrivalGate()
	task.spawn(readManifest)
	local openedAt = os.clock()

	while not gateClosed do
		task.wait(GATE_POLL_SECONDS)
		if not manifestSettled then
			continue -- can't tell strays from members yet
		end
		for _, player in pending do
			if player.Parent == Players then
				adjudicate(player)
			end
		end
		table.clear(pending)

		local present, loaded = counts()
		local decision = TeleportLogic.gateDecision({
			expected = if manifest then #manifest.members else nil,
			present = present,
			loaded = loaded,
			elapsed = os.clock() - openedAt,
			graceSeconds = GameConfig.npc.fillGraceSeconds,
			loadGraceSeconds = config.profileLoadGraceSeconds,
			seatCount = GameConfig.playerCount,
		})
		if decision == "Start" then
			startRound(present)
		elseif decision == "Abandon" then
			gateClosed = true
			warn("MatchTeleportService: nobody arrived - no round will run on this server")
		end
	end
end

local function startMatch()
	local function onArrival(player: Player)
		if gateClosed then
			adjudicate(player) -- always "Late"
		else
			table.insert(pending, player)
		end
	end
	for _, player in Players:GetPlayers() do
		onArrival(player)
	end
	Players.PlayerAdded:Connect(onArrival)
	Players.PlayerRemoving:Connect(function(player: Player)
		admitted[player] = nil
	end)

	task.spawn(runArrivalGate)
end

-- A public (non-reserved) server of the match place is never a real
-- match: someone got there without our hub sending them. Send them back.
local function startStrayMatchServer()
	local function turnAway(player: Player)
		sendHome(player, "Stray")
	end
	for _, player in Players:GetPlayers() do
		turnAway(player)
	end
	Players.PlayerAdded:Connect(turnAway)
end

-- ===========================================================================

type Role = "Hub" | "Match" | "StrayMatch" | "Inert"

local role: Role = "Inert"

local MatchTeleportService: Loader.Service = {
	name = "MatchTeleportService",
	dependencies = {
		"ConfigValidator",
		"DataService",
		"MatchmakingService",
		"RoundService",
		"NPCService",
		"Telemetry",
	},

	-- The map this match is playing, once the arrival gate has closed.
	-- Whatever loads maps reads it here (no map loader exists yet).
	getMapId = function(): string?
		return chosenMapId
	end,
}

function MatchTeleportService:init()
	-- TeleportService doesn't work in Studio, and an unset place id means
	-- there is nowhere to go: Studio keeps P5-1's placeholder handler and
	-- RoundService's debug interface.
	if RunService:IsStudio() or config.matchPlaceId == 0 then
		return
	end
	if matchmakingConfig.hubPlaceId ~= 0 and game.PlaceId == matchmakingConfig.hubPlaceId then
		role = "Hub"
	elseif game.PlaceId == config.matchPlaceId then
		local reserved = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
		role = if reserved then "Match" else "StrayMatch"
	end
end

function MatchTeleportService:start()
	if role == "Hub" then
		startHub()
	elseif role == "Match" then
		startMatch()
	elseif role == "StrayMatch" then
		startStrayMatchServer()
	end
end

return MatchTeleportService
