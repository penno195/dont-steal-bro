--!strict
-- The pure half of the Locker and the queue strip: what the player owns,
-- what their loadout holds, and what "Same as last round" would bring
-- back. No Roblox API, no requires - registry lookups are passed in - so
-- it runs under Lune (tests/LockerLogic.spec).
--
-- Display only. The server re-checks every edit against the profile
-- (StoreLogic.setLoadoutSlot, repeatLoadout), so the worst this can be
-- wrong about is a button that does nothing until the next StoreState.
--
-- Practice pickups never reach this module: StoreState carries only the
-- profile's stock (design-decisions.md Q8, "the Locker and choosing a
-- loadout").

local LockerLogic = {}

-- The StoreState fields read here (StoreScreenLogic.StoreState).
export type State = {
	powerUpStock: { [string]: number },
	loadout: { string },
	lastLoadout: { string }?,
	ownedCosmetics: { string },
	equipped: { [string]: string },
	loadoutSlots: number,
	unlockedTitles: { string }?,
	equippedTitle: string?,
	wornTitle: string?,
}

local RARITY_RANK: { [string]: number } = { Common = 1, Uncommon = 2, Rare = 3 }

local function placedCount(loadout: { string }, powerUpId: string): number
	local n = 0
	for _, id in loadout do
		if id == powerUpId then
			n += 1
		end
	end
	return n
end

-- ===== power-ups ============================================================

-- One loadout slot. `powerUpId` nil = empty. `stock` is what the player
-- owns of it in total, the count badge.
export type Slot = { index: number, powerUpId: string?, stock: number }

function LockerLogic.slots(state: State): { Slot }
	local out = {}
	for index = 1, state.loadoutSlots do
		local id = state.loadout[index]
		table.insert(out, {
			index = index,
			powerUpId = id,
			stock = if id then state.powerUpStock[id] or 0 else 0,
		})
	end
	return out
end

-- One owned power-up. `free` is how many are not already in the
-- loadout, so a tap can add another copy only while it's above 0.
export type StockRow = { powerUpId: string, count: number, free: number }

-- Everything in stock, rarest first, then by name: the rare ones are what
-- a player is deciding whether to spend.
function LockerLogic.stock(state: State, rarityOf: (string) -> string?, nameOf: (string) -> string): { StockRow }
	local out = {}
	for id, count in state.powerUpStock do
		if count > 0 then
			table.insert(out, { powerUpId = id, count = count, free = count - placedCount(state.loadout, id) })
		end
	end
	table.sort(out, function(a, b)
		local ra, rb = RARITY_RANK[rarityOf(a.powerUpId) or ""] or 0, RARITY_RANK[rarityOf(b.powerUpId) or ""] or 0
		if ra ~= rb then
			return ra > rb
		end
		return nameOf(a.powerUpId) < nameOf(b.powerUpId)
	end)
	return out
end

-- Why a stock tile can't be added, or nil when it can. The tile shows it.
export type AddBlock = "LoadoutFull" | "AllPlaced"

function LockerLogic.addBlock(state: State, row: StockRow): AddBlock?
	if #state.loadout >= state.loadoutSlots then
		return "LoadoutFull"
	elseif row.free <= 0 then
		return "AllPlaced"
	end
	return nil
end

-- The slot index an add goes to: the next one after what's placed. The
-- server stores the loadout as a list, so slot 3 with slot 2 empty
-- appends anyway (StoreLogic.setLoadoutSlot).
function LockerLogic.nextSlot(state: State): number
	return #state.loadout + 1
end

-- ===== "Same as last round" =================================================

-- Last round's picks, each with the stock left behind it. Shown greyed on
-- the queue strip next to the button, with a red 0 where the stock has
-- run out, so the player sees what they'd get before tapping.
export type RepeatEntry = { powerUpId: string, stock: number }

function LockerLogic.repeatOffer(state: State): { RepeatEntry }?
	local last: { string } = state.lastLoadout or {}
	-- Offered only while nothing is picked: a loadout already set is the
	-- player's answer for this round.
	if #state.loadout > 0 or #last == 0 then
		return nil
	end
	local out = {}
	local anyStock = false
	for index, id in last do
		if index > state.loadoutSlots then
			break
		end
		local stock = state.powerUpStock[id] or 0
		anyStock = anyStock or stock > 0
		table.insert(out, { powerUpId = id, stock = stock })
	end
	-- Nothing left to re-arm: the button would do nothing, so don't offer it.
	return if anyStock then out else nil
end

-- What the queue strip shows: the loadout going in ("Set"), last
-- round's picks on offer ("Offer", greyed, beside the button), or empty
-- slots ("None"). Always `loadoutSlots` tiles, so the strip never jumps.
export type StripMode = "Set" | "Offer" | "None"
export type StripTile = { powerUpId: string?, stock: number }
export type Strip = { mode: StripMode, tiles: { StripTile } }

function LockerLogic.strip(state: State): Strip
	local mode: StripMode = "None"
	local filled: { StripTile } = {}
	if #state.loadout > 0 then
		mode = "Set"
		for _, slot in LockerLogic.slots(state) do
			if slot.powerUpId ~= nil then
				table.insert(filled, { powerUpId = slot.powerUpId, stock = slot.stock })
			end
		end
	else
		local offer = LockerLogic.repeatOffer(state)
		if offer ~= nil then
			mode = "Offer"
			for _, entry in offer do
				table.insert(filled, { powerUpId = entry.powerUpId, stock = entry.stock })
			end
		end
	end
	local tiles: { StripTile } = {}
	for index = 1, state.loadoutSlots do
		tiles[index] = filled[index] or { powerUpId = nil, stock = 0 }
	end
	return { mode = mode, tiles = tiles }
end

-- ===== titles ===============================================================

-- A rung of the title ladder (Validate.TitleDef's fields read here).
export type TitleDef = { id: string, minStreak: number }

-- One title. `picked` = the player chose it (tapping again un-picks it,
-- back to wearing the highest); `worn` = it's what they're shown in.
export type TitleRow = { titleId: string, minStreak: number, unlocked: boolean, worn: boolean, picked: boolean }

-- The whole ladder, lowest rung first, locked rungs included: the
-- player's own next goals. Only their own best streak is implied, and
-- only to them (StoreState is targeted).
function LockerLogic.titles(state: State, ladder: { TitleDef }): { TitleRow }
	local unlocked = state.unlockedTitles or {}
	local out = {}
	for _, def in ladder do
		table.insert(out, {
			titleId = def.id,
			minStreak = def.minStreak,
			unlocked = table.find(unlocked, def.id) ~= nil,
			worn = state.wornTitle == def.id,
			picked = state.equippedTitle == def.id,
		})
	end
	table.sort(out, function(a, b)
		if a.minStreak ~= b.minStreak then
			return a.minStreak < b.minStreak
		end
		return a.titleId < b.titleId
	end)
	return out
end

-- What tapping a title asks for: wear it, or (tapping your own pick)
-- go back to the highest rung, which is TitleEquipIntent's nil. A locked
-- title does nothing; the server would refuse it anyway.
export type TitleTap = { titleId: string? }

function LockerLogic.titleTap(row: TitleRow): TitleTap?
	if not row.unlocked then
		return nil
	end
	return { titleId = if row.picked then nil else row.titleId }
end

-- ===== cosmetics ============================================================

-- One owned cosmetic and the equip slot it goes in. `slot` nil means its
-- category has no slot the client knows about (a newer server); the tile
-- shows it but can't equip it.
export type CosmeticRow = { cosmeticId: string, slot: string?, equipped: boolean }

-- Owned cosmetics, grouped by category in `categoryOrder`, then by name.
function LockerLogic.cosmetics(
	state: State,
	categoryOf: (string) -> string?,
	slotFor: (string) -> string?,
	nameOf: (string) -> string,
	categoryOrder: { string }
): { CosmeticRow }
	local rank: { [string]: number } = {}
	for i, category in categoryOrder do
		rank[category] = i
	end
	local out = {}
	for _, id in state.ownedCosmetics do
		local category = categoryOf(id)
		if category == nil then
			continue -- removed from config since it was granted; nothing to draw
		end
		local slot = slotFor(category)
		table.insert(out, {
			cosmeticId = id,
			slot = slot,
			equipped = slot ~= nil and state.equipped[slot] == id,
		})
	end
	table.sort(out, function(a, b)
		local ca = rank[categoryOf(a.cosmeticId) or ""] or math.huge
		local cb = rank[categoryOf(b.cosmeticId) or ""] or math.huge
		if ca ~= cb then
			return ca < cb
		end
		return nameOf(a.cosmeticId) < nameOf(b.cosmeticId)
	end)
	return out
end

return LockerLogic
