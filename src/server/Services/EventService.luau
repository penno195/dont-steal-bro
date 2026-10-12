--!strict
-- Themed events (staff-tools.md step 5; design-decisions.md "Applied
-- case: staff tools"). The Roblox side of EventLogic: the staff remote,
-- the shared record and telling every Hub server.
--
-- HOW AN EVENT FLOWS
--
--   StaffEventIntent (NetGuard has already checked its shape and rate)
--   -> sender on liveOps.adminUserIds? If not, dropped with no reply
--      and no audit entry, as StaffService does.
--   -> EventLogic.checkStart (a Start), then one UpdateAsync on
--      liveOps.eventKey that builds the new record from the stored one
--   -> a MessagingService publish on liveOps.eventTopic, so every Hub
--      server shows it within seconds
--   -> one audit entry under liveOps.eventAuditKey, then a
--      StaffEventResult to the sender.
--
-- Every Hub server also re-reads the record each liveOps.refreshSeconds,
-- which covers a lost message and a server that started later. A read
-- and a message can arrive in either order; EventLogic.newer keeps the
-- higher version. Each server ends the event itself at endsAt.
--
-- Only Hub servers show events (owner, 2026-10-12: the lobby only), as
-- the ReplicatedStorage attributes LiveEventId and LiveEventEndsAt. The
-- client's EventController plays the music and draws the event's view.
-- A match server still takes a staff Start or Stop, but never reads,
-- subscribes or shows anything.
--
-- VERIFIED APIs (globalTypes.d.luau):
--   DataStoreService:GetDataStore(name) -> DataStore
--   GlobalDataStore:GetAsync(key) -> (any, DataStoreKeyInfo)
--   GlobalDataStore:UpdateAsync(key, (any, DataStoreKeyInfo) -> any) -> (any, DataStoreKeyInfo)
--   MessagingService:PublishAsync(topic, message)
--   MessagingService:SubscribeAsync(topic, callback) -> RBXScriptConnection
--     (callback gets { Data = message, Sent = time })

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Events = require(ReplicatedStorage.Shared.Config.Events)
local EventLogic = require(ServerScriptService.Server.EventLogic)
local StaffGrantLogic = require(ServerScriptService.Server.StaffGrantLogic)
local StreakTagLogic = require(ServerScriptService.Server.StreakTagLogic)

local config = GameConfig.liveOps

-- LiveConfig's store, by the same rule.
local STORE_NAME = if RunService:IsStudio() then config.dataStoreName .. "_Studio" else config.dataStoreName

local eventInfos: { EventLogic.EventInfo } = {}
local displayNames: { [string]: string } = {}
for _, entry in Events do
	table.insert(eventInfos, entry.def)
	displayNames[entry.def.id] = entry.def.displayName
end

local store: DataStore? = nil
local isHub = false -- set in init: only the Hub shows events
local current: EventLogic.State? = nil
local applyToken = 0

-- ===== showing it ============================================================

-- Mirrors `current` onto the attributes, and wakes again at endsAt so
-- the event ends on time with nothing else happening.
local function apply()
	if not isHub then
		return
	end
	applyToken += 1
	local token = applyToken
	local now = os.time()
	local id = EventLogic.activeId(current, now, eventInfos)
	local endsAt = if id ~= nil and current ~= nil then current.endsAt else nil
	if ReplicatedStorage:GetAttribute("LiveEventId") ~= id then
		print("EventService: " .. (if id ~= nil then "now showing " .. id else "no event showing"))
	end
	ReplicatedStorage:SetAttribute("LiveEventId", id)
	ReplicatedStorage:SetAttribute("LiveEventEndsAt", endsAt)
	if endsAt ~= nil then
		task.delay(endsAt - now, function()
			if token == applyToken then
				apply()
			end
		end)
	end
end

local function take(raw: any)
	local incoming = EventLogic.parseState(raw)
	local merged = EventLogic.newer(current, incoming)
	if merged ~= current then
		current = merged
		apply()
	end
end

local function refresh()
	local liveStore = store
	if liveStore == nil then
		return
	end
	local ok, result = pcall(function()
		return liveStore:GetAsync(config.eventKey)
	end)
	if ok then
		take(result)
	else
		warn("EventService: couldn't read the live event, keeping what this server has: " .. tostring(result))
	end
end

-- ===== audit =================================================================

local function audit(entry: EventLogic.AuditEntry)
	print(
		string.format(
			"EventService: %d %s %s%s",
			entry.staffUserId,
			if entry.action == "Start" then "started" else "stopped",
			entry.eventId or "?",
			if entry.minutes ~= nil then string.format(" for %d min", entry.minutes) else ""
		)
	)
	local liveStore = store
	if liveStore == nil then
		return
	end
	local ok, err = pcall(function()
		liveStore:UpdateAsync(config.eventAuditKey, function(log: any): any
			return EventLogic.appendAudit(log, entry, config.eventAuditLogCap)
		end)
	end)
	if not ok then
		warn("EventService: audit write failed (the change above still happened): " .. tostring(err))
	end
end

-- ===== the staff remote ======================================================

local function reply(player: Player, ok: boolean, message: string)
	Net.fireClient("StaffEventResult", player, { ok = ok, message = message })
end

-- Writes the change built from the stored record. `build` returns nil to
-- write nothing. Without DataStore access (a Studio place without API
-- access) the change is built from this server's own state and stays in
-- this server.
local function write(build: (EventLogic.State?) -> EventLogic.State?): (boolean, EventLogic.State?, EventLogic.State?)
	local liveStore = store
	if liveStore == nil then
		local before = current
		return true, before, build(before)
	end
	local before: EventLogic.State? = nil
	local after: EventLogic.State? = nil
	local ok, err = pcall(function()
		liveStore:UpdateAsync(config.eventKey, function(stored: any): any
			before = EventLogic.parseState(stored)
			after = build(before)
			return after -- nil cancels the write
		end)
	end)
	if not ok then
		warn("EventService: couldn't write the live event: " .. tostring(err))
		return false, nil, nil
	end
	return true, before, after
end

local function announce(state: EventLogic.State)
	current = EventLogic.newer(current, state)
	apply()
	if store == nil then
		warn("EventService: no DataStore access, the change only reaches this server")
		return
	end
	-- PublishAsync yields for seconds; the staff reply shouldn't wait on it.
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(config.eventTopic, state)
		end)
		if not ok then
			warn("EventService: publish failed, other servers pick it up on their next refresh: " .. tostring(err))
		end
	end)
end

local function handleEvent(staff: Player, payload: any)
	-- The only gate. Everything after it trusts the sender's authority,
	-- never their payload.
	if not StaffGrantLogic.isStaff(staff.UserId, config.adminUserIds) then
		return
	end
	local now = os.time()

	if payload.action == "Start" then
		local event, why = EventLogic.checkStart(payload.eventId, payload.minutes, eventInfos)
		if event == nil then
			reply(staff, false, why or "can't start that")
			return
		end
		local minutes = payload.minutes :: number
		local ok, before, after = write(function(stored)
			return EventLogic.start(stored, event.id, minutes, staff.UserId, now)
		end)
		if not ok or after == nil then
			reply(staff, false, "couldn't save the event, try again")
			return
		end
		announce(after)
		local replaced = EventLogic.activeId(before, now, eventInfos)
		local entry: EventLogic.AuditEntry = {
			at = now,
			staffUserId = staff.UserId,
			action = "Start",
			eventId = event.id,
			minutes = minutes,
			replaced = replaced,
		}
		task.spawn(audit, entry)
		local message = string.format("%s is on in every lobby for %d min", event.displayName, minutes)
		if replaced ~= nil then
			message ..= string.format(" (it replaced %s)", displayNames[replaced] or replaced)
		end
		reply(staff, true, message)
		return
	end

	-- Stop.
	local ok, before, after = write(function(stored)
		if stored == nil or EventLogic.activeId(stored, now, eventInfos) == nil then
			return nil
		end
		return EventLogic.stop(stored, staff.UserId, now)
	end)
	if not ok then
		reply(staff, false, "couldn't save the stop, try again")
		return
	end
	if after == nil or before == nil then
		reply(staff, false, "no event is running")
		return
	end
	announce(after)
	local entry: EventLogic.AuditEntry = { at = now, staffUserId = staff.UserId, action = "Stop", eventId = before.id }
	task.spawn(audit, entry)
	reply(staff, true, string.format("%s stopped in every lobby", displayNames[before.id] or before.id))
end

-- ===== service ===============================================================

local EventService: Loader.Service = {
	name = "EventService",
	dependencies = { "NetGuard", "LiveConfig" },
}

function EventService:init()
	isHub = StreakTagLogic.isHub(
		game.PlaceId,
		GameConfig.matchmaking.hubPlaceId,
		RunService:IsStudio(),
		Workspace:FindFirstChild("Hub") ~= nil
	)
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("EventService: no DataStore access, events only reach this server: " .. tostring(result))
	end
end

function EventService:start()
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("StaffEventIntent", function(player: Player, payload: any)
		handleEvent(player, payload)
	end)

	if not isHub or store == nil then
		return
	end
	-- Both yield (SubscribeAsync for seconds), so off the boot path.
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(config.eventTopic, function(message: any)
				if type(message) == "table" then
					take(message.Data)
				end
			end)
		end)
		if not ok then
			warn("EventService: couldn't subscribe, events arrive on the refresh instead: " .. tostring(err))
		end
	end)
	task.spawn(function()
		while true do
			refresh()
			task.wait(config.refreshSeconds)
		end
	end)
end

return EventService
