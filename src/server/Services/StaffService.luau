--!strict
-- Staff grants (staff-tools.md step 2; design-decisions.md "Applied
-- case: staff tools"). The Roblox side of StaffGrantLogic: the one
-- staff remote, the profile write and the audit log.
--
-- HOW A GIFT FLOWS
--
--   StaffGrantIntent (NetGuard has already checked its shape and rate)
--   -> sender on liveOps.adminUserIds? If not, dropped with no reply
--      and no audit entry, as LiveConfig's /liveops does.
--   -> StaffGrantLogic.checkGift / resolveRecipients (this server's
--      players only)
--   -> DataService's staff gift writer, per recipient (applied and
--      saved in one go)
--   -> one audit entry for the whole give, then a StaffGrantResult to
--      the sender.
--
-- The audit log lives in the live-ops DataStore under
-- liveOps.staffAuditKey (Studio uses the _Studio store, as LiveConfig
-- does). A failed audit write warns and doesn't undo the gift, the same
-- as LiveConfig's audit; the server log line is the fallback record.
--
-- Step 3 (the gift pop-up) hooks in through onGifted.
--
-- VERIFIED APIs (globalTypes.d.luau):
--   DataStoreService:GetDataStore(name) -> DataStore
--   GlobalDataStore:UpdateAsync(key, (any, DataStoreKeyInfo) -> any) -> (any, DataStoreKeyInfo)
--   Players:GetPlayerByUserId(userId) -> Player?

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local StaffGrantLogic = require(ServerScriptService.Server.StaffGrantLogic)

local config = GameConfig.liveOps

-- LiveConfig's store, by the same rule.
local STORE_NAME = if RunService:IsStudio() then config.dataStoreName .. "_Studio" else config.dataStoreName

local cosmeticIds: { [string]: boolean } = {}
for _, entry in Cosmetics do
	cosmeticIds[(entry.def :: any).id] = true
end

local store: DataStore? = nil
local writeGift: any = nil -- DataService.StaffGiftWriter, claimed in init
local gifted = Instance.new("BindableEvent")

-- ===== audit ===============================================================

local function audit(entry: StaffGrantLogic.AuditEntry)
	local line = string.format(
		"StaffService: %d gave %s (%s) -> delivered %s; failed %s",
		entry.staffUserId,
		StaffGrantLogic.describe(entry.gift),
		entry.target,
		if #entry.delivered > 0 then table.concat(entry.delivered, ",") else "none",
		if #entry.failed > 0 then table.concat(entry.failed, ",") else "none"
	)
	print(line)

	local liveStore = store
	if liveStore == nil then
		warn("StaffService: no DataStore access, the grant above is only in this server's log")
		return
	end
	local ok, err = pcall(function()
		liveStore:UpdateAsync(config.staffAuditKey, function(log: any): any
			return StaffGrantLogic.appendAudit(log, entry, config.staffAuditLogCap)
		end)
	end)
	if not ok then
		warn("StaffService: audit write failed (the grant above still happened): " .. tostring(err))
	end
end

-- ===== the give ============================================================

local function reply(player: Player, ok: boolean, message: string, delivered: number, failed: number)
	Net.fireClient("StaffGrantResult", player, {
		ok = ok,
		message = message,
		delivered = delivered,
		failed = failed,
	})
end

local function handleGrant(staff: Player, payload: any)
	-- The only gate. Everything after it trusts the sender's authority,
	-- never their payload.
	if not StaffGrantLogic.isStaff(staff.UserId, config.adminUserIds) then
		return
	end

	local gift, giftError = StaffGrantLogic.checkGift(payload.kind, payload.amount, payload.cosmeticId, cosmeticIds)
	if gift == nil then
		reply(staff, false, giftError or "bad gift", 0, 0)
		return
	end

	local inServer: { number } = {}
	for _, player in Players:GetPlayers() do
		table.insert(inServer, player.UserId)
	end
	local recipients, targetError = StaffGrantLogic.resolveRecipients(payload.target, payload.targetUserId, inServer)
	if recipients == nil then
		reply(staff, false, targetError or "bad target", 0, 0)
		return
	end

	local grants, unlimitedNavigation = StaffGrantLogic.toGrants(gift)
	local StoreService = Loader.get("StoreService") :: any
	local delivered: { number } = {}
	local failed: { number } = {}
	for _, userId in recipients do
		local player = Players:GetPlayerByUserId(userId)
		local changes = if player ~= nil then writeGift(player, grants, unlimitedNavigation) else nil
		if player == nil or changes == nil then
			table.insert(failed, userId)
			continue
		end
		table.insert(delivered, userId)
		print(string.format("StaffService: %s (%d): %s", player.Name, userId, table.concat(changes, "; ")))
		StoreService.pushState(player)
		gifted:Fire(player, staff, gift)
	end

	task.spawn(audit, {
		at = os.time(),
		staffUserId = staff.UserId,
		target = payload.target,
		gift = gift,
		delivered = delivered,
		failed = failed,
	})

	local message = string.format(
		"gave %s to %d player%s",
		StaffGrantLogic.describe(gift),
		#delivered,
		if #delivered == 1 then "" else "s"
	)
	if #failed > 0 then
		message ..= string.format(" (%d couldn't take it: data still loading or read-only)", #failed)
	end
	reply(staff, #delivered > 0, message, #delivered, #failed)
end

-- ===== service =============================================================

local StaffService: Loader.Service = {
	name = "StaffService",
	dependencies = { "NetGuard", "DataService", "StoreService", "LiveConfig" },

	isStaff = function(player: Player): boolean
		return StaffGrantLogic.isStaff(player.UserId, config.adminUserIds)
	end,

	-- (recipient, staff, gift) after a gift lands in a profile. For step
	-- 3's pop-up; the recipient may be mid-race.
	onGifted = function(callback: (recipient: Player, staff: Player, gift: StaffGrantLogic.Gift) -> ())
		return gifted.Event:Connect(callback)
	end,
}

function StaffService:init()
	writeGift = (Loader.get("DataService") :: any).claimStaffGiftWriter("StaffService")
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("StaffService: no DataStore access, grants will be logged to the server log only: " .. tostring(result))
	end
end

function StaffService:start()
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("StaffGrantIntent", function(player: Player, payload: any)
		handleGrant(player, payload)
	end)
end

return StaffService
