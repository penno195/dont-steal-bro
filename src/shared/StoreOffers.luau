--!strict
-- What the store is offering right now: sale windows, launch offers that
-- replace a full-price item, the hub plinths, and the struck-through
-- "was" price (design-decisions.md Q1, "the featured plinths" and
-- "limited cosmetics", 2026-10-09).
--
-- Shared because both sides need the same answer: StoreService refuses
-- to sell anything this says isn't on offer, and the client hides it.
-- The server's answer is the one that counts.
--
-- Self-contained on purpose - no requires, no Roblox API calls - so
-- tests/StoreOffers.spec.luau runs it under Lune. Every function takes
-- `now` (os.time() on the server, a synced clock on the client) rather
-- than reading a clock. Defs are typed loosely so this needn't require
-- Validate.

local StoreOffers = {}

type Def = { [string]: any }
type Entry = { fileName: string, def: Def }

-- Days since 1970-01-01 (Howard Hinnant's days_from_civil). os.time's
-- table form reads LOCAL time, so it can't parse a UTC config time.
local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- "YYYY-MM-DD HH:MM" (UTC) -> os.time(), or nil if it doesn't parse.
-- Validate refuses a bad date at boot; this only checks the shape.
function StoreOffers.parseUtcTime(text: any): number?
	if type(text) ~= "string" then
		return nil
	end
	local ys, ms, ds, hs, mins = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d)$")
	if ys == nil then
		return nil
	end
	local days = daysFromCivil(tonumber(ys) :: number, tonumber(ms) :: number, tonumber(ds) :: number)
	return days * 86400 + (tonumber(hs) :: number) * 3600 + (tonumber(mins) :: number) * 60
end

-- Enabled and inside its own sale window. A bound that won't parse
-- counts as closed, so a typo can't put an item on sale forever.
function StoreOffers.isOnSale(def: Def, now: number): boolean
	if def.enabled ~= true then
		return false
	end
	if def.onSaleFrom ~= nil then
		local from = StoreOffers.parseUtcTime(def.onSaleFrom)
		if from == nil or now < from then
			return false
		end
	end
	if def.onSaleUntil ~= nil then
		local untilAt = StoreOffers.parseUtcTime(def.onSaleUntil)
		if untilAt == nil or now >= untilAt then
			return false
		end
	end
	return true
end

-- Keys that are on sale but stood down for an item that replaces them.
local function replacedKeys(catalogue: { Entry }, now: number): { [string]: boolean }
	local replaced = {}
	for _, entry in catalogue do
		local def = entry.def
		if type(def.replaces) == "string" and StoreOffers.isOnSale(def, now) then
			replaced[def.replaces] = true
		end
	end
	return replaced
end

-- Whether this item can be bought right now: on sale, and not replaced
-- by an offer that is.
function StoreOffers.isOffered(catalogue: { Entry }, def: Def, now: number): boolean
	return StoreOffers.isOnSale(def, now) and not replacedKeys(catalogue, now)[def.key]
end

-- Every item offered right now, in catalogue order.
function StoreOffers.offered(catalogue: { Entry }, now: number): { Def }
	local replaced = replacedKeys(catalogue, now)
	local list = {}
	for _, entry in catalogue do
		if StoreOffers.isOnSale(entry.def, now) and not replaced[entry.def.key] then
			table.insert(list, entry.def)
		end
	end
	return list
end

-- What to sell when a client asks for `key`: the offer replacing it
-- while one is on sale (asking for "season-pass" during the launch
-- offer gets the 99 R$ product), else the item itself if it's offered.
function StoreOffers.resolve(catalogue: { Entry }, key: string, now: number): Def?
	for _, entry in catalogue do
		local def = entry.def
		if def.replaces == key and StoreOffers.isOnSale(def, now) then
			return def
		end
	end
	for _, entry in catalogue do
		if entry.def.key == key and StoreOffers.isOffered(catalogue, entry.def, now) then
			return entry.def
		end
	end
	return nil
end

-- Plinth slot -> the item it shows right now. Validate keeps enabled
-- items' windows on one slot apart; if two still collide, the first in
-- catalogue order wins so every server shows the same one.
function StoreOffers.featured(catalogue: { Entry }, now: number): { [number]: Def }
	local bySlot: { [number]: Def } = {}
	for _, def in StoreOffers.offered(catalogue, now) do
		local slot = def.featuredSlot
		if type(slot) == "number" and bySlot[slot] == nil then
			bySlot[slot] = def
		end
	end
	return bySlot
end

-- The struck-through price to show, or nil for none. A coin item's sale
-- price is its coinPrice, so `wasPrice` always shows. A Robux item's
-- real price is whatever Roblox charges (`livePrice`, from
-- GetProductInfo; nil until it loads, then config's robuxPrice stands
-- in), so "was" shows only if that really is lower.
function StoreOffers.wasPrice(def: Def, livePrice: number?): number?
	local was = def.wasPrice
	if type(was) ~= "number" then
		return nil
	end
	local now = if def.kind == "CoinOffer" then def.coinPrice else (livePrice or def.robuxPrice)
	if type(now) ~= "number" or now >= was then
		return nil
	end
	return was
end

return StoreOffers
