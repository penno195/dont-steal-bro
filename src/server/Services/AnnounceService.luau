--!strict
-- Staff announcements (staff-tools.md step 6; design-decisions.md
-- "Applied case: staff tools"). The Roblox side of AnnounceLogic: the
-- staff remote, the text filter, telling every server and the audit log.
--
-- HOW AN ANNOUNCEMENT FLOWS
--
--   StaffAnnounceIntent (NetGuard has already checked its shape and rate)
--   -> sender on liveOps.adminUserIds? If not, dropped with no reply
--      and no audit entry, as StaffService does.
--   -> AnnounceLogic.clean (tidy, length) and checkCooldown (one per
--      staff member per liveOps.announceCooldownSeconds, this server)
--   -> TextService filters it for a broadcast, in the sender's name
--   -> shown in this server at once, then published on
--      liveOps.announceTopic so every other server shows it too
--   -> one audit entry under liveOps.announceAuditKey, then a
--      StaffAnnounceResult to the sender.
--
-- Every server subscribes, Hub, match and practice alike: an
-- announcement shows everywhere, mid-race included (owner, 2026-10-18).
-- The sending server hears its own publish too; AnnounceLogic.remember
-- drops that repeat. Nothing is stored, so a server that starts later,
-- or a player who joins later, never sees an old one.
--
-- Q7 condition 1: the text is staff's own words, so nothing here can
-- tell a streak mention from any other number. The owner made that
-- staff's job; the panel warns them.
--
-- VERIFIED APIs (globalTypes.d.luau):
--   TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext?) -> TextFilterResult
--   TextFilterResult:GetNonChatStringForBroadcastAsync() -> string
--   MessagingService:PublishAsync(topic, message)
--   MessagingService:SubscribeAsync(topic, callback) -> RBXScriptConnection
--     (callback gets { Data = message, Sent = time })
--   HttpService:GenerateGUID(wrapInCurlyBraces: boolean?) -> string
--   DataStoreService:GetDataStore(name) -> DataStore
--   GlobalDataStore:UpdateAsync(key, (any, DataStoreKeyInfo) -> any) -> (any, DataStoreKeyInfo)

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TextService = game:GetService("TextService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local AnnounceLogic = require(ReplicatedStorage.Shared.AnnounceLogic)
local StaffGrantLogic = require(ServerScriptService.Server.StaffGrantLogic)

local config = GameConfig.liveOps

-- LiveConfig's store, by the same rule.
local STORE_NAME = if RunService:IsStudio() then config.dataStoreName .. "_Studio" else config.dataStoreName

local store: DataStore? = nil
local seen = AnnounceLogic.newSeen()
local lastSentAt: { [number]: number } = {} -- staff user id -> os.time()
local sending: { [number]: boolean } = {} -- a send of theirs is still in flight

-- ===== showing it ============================================================

local function show(message: AnnounceLogic.Message)
	if not AnnounceLogic.remember(seen, message.id) then
		return
	end
	if AnnounceLogic.isStale(message.sentAt, os.time()) then
		return
	end
	Net.fireAllClients("Announcement", { text = message.text, from = message.from })
end

-- ===== audit =================================================================

local function audit(entry: AnnounceLogic.AuditEntry)
	print(
		string.format(
			"AnnounceService: %d announced %q%s",
			entry.staffUserId,
			entry.shown,
			if entry.reachedEveryServer then "" else " (this server only: the publish failed)"
		)
	)
	local liveStore = store
	if liveStore == nil then
		return
	end
	local ok, err = pcall(function()
		liveStore:UpdateAsync(config.announceAuditKey, function(log: any): any
			return AnnounceLogic.appendAudit(log, entry, config.announceAuditLogCap)
		end)
	end)
	if not ok then
		warn("AnnounceService: audit write failed (the announcement above still went out): " .. tostring(err))
	end
end

-- ===== the staff remote ======================================================

local function reply(player: Player, ok: boolean, message: string)
	Net.fireClient("StaffAnnounceResult", player, { ok = ok, message = message })
end

-- What the filter makes of the text for everyone to read, or nil if the
-- filter couldn't be reached. Yields.
local function filter(text: string, fromUserId: number): string?
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		warn("AnnounceService: the text filter failed: " .. tostring(result))
		return nil
	end
	return result
end

local function send(staff: Player, text: string)
	local filtered = filter(text, staff.UserId)
	if filtered == nil then
		reply(staff, false, "couldn't reach the text filter, try again")
		return false
	end
	if AnnounceLogic.isFilteredOut(filtered) then
		reply(staff, false, "the text filter removed the whole message")
		return false
	end

	local message: AnnounceLogic.Message = {
		id = HttpService:GenerateGUID(false),
		text = filtered,
		from = staff.DisplayName,
		sentAt = os.time(),
	}
	if not AnnounceLogic.fits(message) then
		reply(staff, false, "that's too long to send, make it shorter")
		return false
	end

	show(message)
	-- Yields for up to a few seconds; the reply needs its outcome.
	local published, err = pcall(function()
		MessagingService:PublishAsync(config.announceTopic, message)
	end)
	if not published then
		warn("AnnounceService: publish failed, only this server showed it: " .. tostring(err))
	end

	task.spawn(
		audit,
		{
			at = message.sentAt,
			staffUserId = staff.UserId,
			typed = text,
			shown = filtered,
			reachedEveryServer = published,
		} :: AnnounceLogic.AuditEntry
	)

	if published then
		reply(staff, true, string.format("sent to every server: %s", filtered))
	else
		reply(staff, false, "only this server got it, the send to other servers failed. Try again in a minute")
	end
	return true
end

local function handleAnnounce(staff: Player, payload: any)
	-- The only gate. Everything after it trusts the sender's authority,
	-- never their payload.
	if not StaffGrantLogic.isStaff(staff.UserId, config.adminUserIds) then
		return
	end
	local text, why = AnnounceLogic.clean(payload.text)
	if text == nil then
		reply(staff, false, why or "bad message")
		return
	end
	local userId = staff.UserId
	if sending[userId] then
		reply(staff, false, "your last one is still sending")
		return
	end
	local now = os.time()
	local free, wait = AnnounceLogic.checkCooldown(lastSentAt[userId], now, config.announceCooldownSeconds)
	if not free then
		reply(staff, false, string.format("wait %d s before the next one", wait))
		return
	end

	sending[userId] = true
	local ok, sent = pcall(send, staff, text)
	sending[userId] = nil
	if not ok then
		warn("AnnounceService: " .. tostring(sent))
		reply(staff, false, "something went wrong, try again")
	elseif sent then
		-- Only an announcement that went out starts the cooldown, so a
		-- filter hiccup can be retried at once.
		lastSentAt[userId] = now
	end
end

-- ===== service ===============================================================

local AnnounceService: Loader.Service = {
	name = "AnnounceService",
	dependencies = { "NetGuard", "LiveConfig" },
}

function AnnounceService:init()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn(
			"AnnounceService: no DataStore access, announcements are logged to the server log only: "
				.. tostring(result)
		)
	end
end

function AnnounceService:start()
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("StaffAnnounceIntent", function(player: Player, payload: any)
		handleAnnounce(player, payload)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastSentAt[player.UserId] = nil
	end)

	-- SubscribeAsync yields for seconds, so off the boot path.
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(config.announceTopic, function(packet: any)
				if type(packet) ~= "table" then
					return
				end
				local message = AnnounceLogic.parse(packet.Data)
				if message ~= nil then
					show(message)
				end
			end)
		end)
		if not ok then
			warn("AnnounceService: couldn't subscribe, this server only shows its own announcements: " .. tostring(err))
		end
	end)
end

return AnnounceService
