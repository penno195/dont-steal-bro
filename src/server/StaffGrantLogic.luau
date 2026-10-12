--!strict
-- Staff grants (staff-tools.md step 2; design-decisions.md "Applied
-- case: staff tools"): who may give, what may be given, to whom, and the
-- audit log entry each give leaves. StaffService is the Roblox side.
--
-- Self-contained on purpose - no requires of sibling files, no Roblox
-- API calls - so it runs headlessly under Lune (Ground Rule 4). The
-- grant shape below is StoreLogic.Grant's, duplicated for the same
-- reason StoreLogic duplicates Validate's.
--
-- THE RULES IT ENFORCES
--
--   * Staff = liveOps.adminUserIds. Everyone on it has full power.
--   * Staff give coins, a cosmetic, Navigation (a round, or unlimited)
--     and Streak Saves. Nothing else - above all, nothing that sets a
--     streak. A gift kind outside GIFT_KINDS is refused, so a new kind
--     is a decision, not an accident.
--   * There are no caps. An amount only has to be a whole number of at
--     least 1 (and below MAX_AMOUNT, which keeps it an exact integer in
--     a DataStore, not a policy limit).
--   * A gift goes to one player in the staff member's own server, or to
--     every player in it. Never to another server.

local StaffGrantLogic = {}

export type GiftKind = "Currency" | "Cosmetic" | "NavigationRound" | "UnlimitedNavigation" | "StreakSave"

StaffGrantLogic.GIFT_KINDS = {
	"Currency",
	"Cosmetic",
	"NavigationRound",
	"UnlimitedNavigation",
	"StreakSave",
} :: { GiftKind }

-- 2^31 - 1. A ceiling on the number, not on generosity.
StaffGrantLogic.MAX_AMOUNT = 2147483647

export type Gift = {
	kind: GiftKind,
	amount: number?, -- Currency, NavigationRound, StreakSave
	cosmeticId: string?, -- Cosmetic
}

export type TargetKind = "Player" | "Server"

StaffGrantLogic.TARGET_KINDS = { "Player", "Server" } :: { TargetKind }

-- Structurally StoreLogic.Grant (the kinds a gift can become).
export type Grant = {
	kind: "Currency" | "Cosmetic" | "NavigationRound" | "StreakSave",
	amount: number?,
	cosmeticId: string?,
}

-- ===== who =================================================================

function StaffGrantLogic.isStaff(userId: number, adminUserIds: { number }): boolean
	return table.find(adminUserIds, userId) ~= nil
end

-- ===== what ================================================================

local AMOUNT_KINDS: { [string]: boolean } = { Currency = true, NavigationRound = true, StreakSave = true }

local function isWholeAmount(value: any): boolean
	return type(value) == "number"
		and value == value
		and value % 1 == 0
		and value >= 1
		and value <= StaffGrantLogic.MAX_AMOUNT
end

-- Turns what a staff client sent into a Gift, or says why not.
-- `cosmeticIds` is the set of every cosmetic in the registry. A field a
-- kind doesn't use must be absent, so a malformed panel fails loudly
-- rather than giving something other than what it showed.
function StaffGrantLogic.checkGift(
	kind: any,
	amount: any,
	cosmeticId: any,
	cosmeticIds: { [string]: boolean }
): (Gift?, string?)
	if type(kind) ~= "string" or table.find(StaffGrantLogic.GIFT_KINDS, kind :: any) == nil then
		return nil, string.format("%s can't be given", tostring(kind))
	end
	if AMOUNT_KINDS[kind] then
		if not isWholeAmount(amount) then
			return nil, "the amount must be a whole number of at least 1"
		end
	elseif amount ~= nil then
		return nil, string.format("%s takes no amount", kind)
	end
	if kind == "Cosmetic" then
		if type(cosmeticId) ~= "string" or not cosmeticIds[cosmeticId] then
			return nil, string.format("there is no cosmetic %q", tostring(cosmeticId))
		end
	elseif cosmeticId ~= nil then
		return nil, string.format("%s takes no cosmetic", kind)
	end
	return { kind = kind :: GiftKind, amount = amount, cosmeticId = cosmeticId }, nil
end

-- What the gift does to a profile: the store grants to apply, plus
-- whether it switches Unlimited Navigation on (a profile flag, not a
-- store grant - the store's only Unlimited Navigation is the live-
-- checked game pass).
function StaffGrantLogic.toGrants(gift: Gift): ({ Grant }, boolean)
	if gift.kind == "UnlimitedNavigation" then
		return {}, true
	end
	return { { kind = gift.kind :: any, amount = gift.amount, cosmeticId = gift.cosmeticId } }, false
end

-- One line for logs and the staff member's reply. Never mentions a
-- streak, so it's safe to show anyone (Q7 condition 1).
function StaffGrantLogic.describe(gift: Gift): string
	local amount = gift.amount or 0
	if gift.kind == "Currency" then
		return string.format("%d coin%s", amount, if amount == 1 then "" else "s")
	elseif gift.kind == "Cosmetic" then
		return string.format("cosmetic %s", gift.cosmeticId or "?")
	elseif gift.kind == "NavigationRound" then
		return string.format("%d Navigation round%s", amount, if amount == 1 then "" else "s")
	elseif gift.kind == "UnlimitedNavigation" then
		return "Unlimited Navigation"
	end
	return string.format("%d Streak Save%s", amount, if amount == 1 then "" else "s")
end

-- ===== to whom =============================================================

-- The recipients' user ids, or why there are none. `inServer` is every
-- player in the staff member's server; a Player target outside it is
-- refused, which is what keeps gifts to this server only.
function StaffGrantLogic.resolveRecipients(
	targetKind: any,
	targetUserId: any,
	inServer: { number }
): ({ number }?, string?)
	if targetKind == "Server" then
		if targetUserId ~= nil then
			return nil, "a whole-server gift takes no player"
		end
		if #inServer == 0 then
			return nil, "nobody is in this server"
		end
		return table.clone(inServer), nil
	elseif targetKind == "Player" then
		if type(targetUserId) ~= "number" or table.find(inServer, targetUserId) == nil then
			return nil, "that player isn't in this server"
		end
		return { targetUserId }, nil
	end
	return nil, string.format("%s isn't a gift target", tostring(targetKind))
end

-- ===== the audit log =======================================================

-- One entry per give, however many players it reached: a whole-server
-- gift is one DataStore write, not one per player (a key takes about
-- one write every few seconds). `failed` = recipients whose profile
-- wasn't writable (still loading, or live-ops read-only).
export type AuditEntry = {
	at: number,
	staffUserId: number,
	target: TargetKind,
	gift: Gift,
	delivered: { number },
	failed: { number },
}

-- Newest last, capped from the front. Same shape of rule as
-- LiveConfigLogic.appendAudit: an unreadable stored log is dropped
-- entry by entry rather than blocking the write.
function StaffGrantLogic.appendAudit(log: any, entry: AuditEntry, cap: number): { AuditEntry }
	local entries: { AuditEntry } = {}
	if type(log) == "table" then
		for _, existing in log do
			if type(existing) == "table" then
				table.insert(entries, existing)
			end
		end
	end
	table.insert(entries, entry)
	while #entries > cap do
		table.remove(entries, 1)
	end
	return entries
end

-- ===== the pop-up queue (step 3) ===========================================
--
-- A gift lands in the profile at once, but its "GIFT RECEIVED!" pop-up
-- only shows in the Hub (owner, 2026-10-12): so a gift given mid-match,
-- or to someone who quits before getting back, waits in the profile's
-- unseenGifts until the player is next in the Hub. The Hub sends the
-- whole list, the client shows what it hasn't shown yet and names the
-- newest id it showed, and everything up to that id is cleared. A gift
-- given meanwhile sits after it, so it stays queued.

-- Structurally ProfileLogic.UnseenGift. `id` is unique (a GUID from the
-- caller), so a resent list never shows a gift twice.
export type UnseenGift = {
	id: string,
	from: string,
	kind: string,
	amount: number?,
	cosmeticId: string?,
}

-- A bound on profile size, not a policy: past it the oldest pop-ups are
-- dropped (the gifts themselves are kept). One pop-up shows them all.
StaffGrantLogic.UNSEEN_CAP = 20

function StaffGrantLogic.unseen(gift: Gift, fromName: string, id: string): UnseenGift
	return { id = id, from = fromName, kind = gift.kind, amount = gift.amount, cosmeticId = gift.cosmeticId }
end

-- `list` with `gift` added newest last, capped from the front. A new
-- table; `list` is untouched.
function StaffGrantLogic.noteUnseen(list: { UnseenGift }, gift: UnseenGift): { UnseenGift }
	local out = table.clone(list)
	table.insert(out, gift)
	while #out > StaffGrantLogic.UNSEEN_CAP do
		table.remove(out, 1)
	end
	return out
end

-- `list` without everything up to and including `upToId`, the newest
-- gift the client says it showed. An id that isn't there (already
-- cleared, or made up) clears nothing.
function StaffGrantLogic.markSeen(list: { UnseenGift }, upToId: any): { UnseenGift }
	local last: number? = nil
	for index, gift in list do
		if gift.id == upToId then
			last = index
		end
	end
	if last == nil then
		return list
	end
	local out: { UnseenGift } = {}
	for index = last + 1, #list do
		table.insert(out, list[index])
	end
	return out
end

return StaffGrantLogic
