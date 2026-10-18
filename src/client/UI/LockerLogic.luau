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
	-- The lifetime ladders' counts (payoff-loop step 9). Hub only, so nil
	-- on a match server; the ladders still list, without the counts.
	lifetimeCounts: { wins: number, studioVisits: number, stealWins: number }?,
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

-- A rung of the streak ladder (Validate.TitleDef's fields read here).
export type TitleDef = { id: string, minStreak: number }

-- A rung of a lifetime ladder (Validate.LifetimeTitleDef's fields read
-- here). The stat names are TitleLogic.LifetimeStat's.
export type LifetimeStat = "Wins" | "StudioVisits" | "StealWins"
export type LifetimeDef = { id: string, stat: LifetimeStat, threshold: number }

-- Which ladder a title sits on. "Streak" = the best-streak ladder.
export type Ladder = "Streak" | LifetimeStat

-- The Locker's grid is two cards wide. Each lifetime ladder starts on a
-- fresh row with its header card, so two ladders never share a row.
LockerLogic.TITLE_COLUMNS = 2

-- Display order of the lifetime ladders, under the streak ladder.
local LIFETIME_ORDER: { LifetimeStat } = { "Wins", "StudioVisits", "StealWins" }

-- One title. `picked` = the player chose it (tapping again un-picks it,
-- back to wearing the highest); `worn` = it's what they're shown in.
-- `threshold` is the rung's streak or lifetime count. `order` is its
-- grid cell (LayoutOrder), fixed by config alone so it never moves.
export type TitleRow = {
	titleId: string,
	ladder: Ladder,
	threshold: number,
	unlocked: boolean,
	worn: boolean,
	picked: boolean,
	order: number,
}

-- A lifetime ladder's header card. `count` is nil off the Hub (no
-- lifetimeCounts); `next` is the next rung's threshold, nil at the top.
export type LadderHeader = {
	stat: LifetimeStat,
	count: number?,
	next: number?,
	earned: number,
	total: number,
	order: number,
}

local function countFor(counts: { wins: number, studioVisits: number, stealWins: number }, stat: LifetimeStat): number
	if stat == "Wins" then
		return counts.wins
	elseif stat == "StudioVisits" then
		return counts.studioVisits
	end
	return counts.stealWins
end

-- Each lifetime ladder's rungs, lowest first. An empty ladder is absent.
local function lifetimeLadders(lifetime: { LifetimeDef }): { [LifetimeStat]: { LifetimeDef } }
	local out: { [LifetimeStat]: { LifetimeDef } } = {}
	for _, def in lifetime do
		local rungs = out[def.stat] or {}
		out[def.stat] = rungs
		table.insert(rungs, def)
	end
	for _, rungs in out do
		table.sort(rungs, function(a, b)
			return a.threshold < b.threshold
		end)
	end
	return out
end

-- Where each lifetime ladder's header sits, and the spacer cells before
-- it. The streak ladder fills from cell 1; each lifetime ladder is padded
-- to a row start, then its header, then its rungs.
local function plan(
	streakCount: number,
	ladders: { [LifetimeStat]: { LifetimeDef } }
): ({ [LifetimeStat]: number }, { number })
	local nextOrder = streakCount + 1
	local headerOrder: { [LifetimeStat]: number } = {}
	local spacers: { number } = {}
	for _, stat: LifetimeStat in LIFETIME_ORDER do
		local rungs = ladders[stat]
		if rungs == nil then
			continue
		end
		while (nextOrder - 1) % LockerLogic.TITLE_COLUMNS ~= 0 do
			table.insert(spacers, nextOrder)
			nextOrder += 1
		end
		headerOrder[stat] = nextOrder
		nextOrder += 1 + #rungs
	end
	return headerOrder, spacers
end

local function titleRow(state: State, id: string, ladder: Ladder, threshold: number, order: number): TitleRow
	return {
		titleId = id,
		ladder = ladder,
		threshold = threshold,
		unlocked = table.find(state.unlockedTitles or {}, id) ~= nil,
		worn = state.wornTitle == id,
		picked = state.equippedTitle == id,
		order = order,
	}
end

-- Every title, locked rungs included: the player's own next goals. The
-- streak ladder lowest rung first, then each lifetime ladder (Wins,
-- Studio visits, steals won) lowest first. Only their own best streak
-- and counts are implied, and only to them (StoreState is targeted).
function LockerLogic.titles(state: State, ladder: { TitleDef }, lifetime: { LifetimeDef }?): { TitleRow }
	local streak = table.clone(ladder)
	table.sort(streak, function(a, b)
		if a.minStreak ~= b.minStreak then
			return a.minStreak < b.minStreak
		end
		return a.id < b.id
	end)
	local out = {}
	for i, def in streak do
		table.insert(out, titleRow(state, def.id, "Streak", def.minStreak, i))
	end
	local ladders = lifetimeLadders(lifetime or {})
	local headerOrder = plan(#streak, ladders)
	for _, stat: LifetimeStat in LIFETIME_ORDER do
		local rungs: { LifetimeDef } = ladders[stat] or {}
		for i, def in rungs do
			table.insert(out, titleRow(state, def.id, stat, def.threshold, headerOrder[stat] + i))
		end
	end
	return out
end

-- One header card per lifetime ladder with rungs, in grid order.
function LockerLogic.ladderHeaders(state: State, ladder: { TitleDef }, lifetime: { LifetimeDef }): { LadderHeader }
	local ladders = lifetimeLadders(lifetime)
	local headerOrder = plan(#ladder, ladders)
	local unlocked = state.unlockedTitles or {}
	local counts = state.lifetimeCounts
	local out = {}
	for _, stat: LifetimeStat in LIFETIME_ORDER do
		local rungs = ladders[stat]
		if rungs == nil then
			continue
		end
		local earned = 0
		for _, def in rungs do
			if table.find(unlocked, def.id) ~= nil then
				earned += 1
			end
		end
		local count = if counts then countFor(counts, stat) else nil
		local nextThreshold: number? = nil
		if count ~= nil then
			for _, def in rungs do
				if def.threshold > count then
					nextThreshold = def.threshold
					break
				end
			end
		end
		table.insert(out, {
			stat = stat,
			count = count,
			next = nextThreshold,
			earned = earned,
			total = #rungs,
			order = headerOrder[stat],
		})
	end
	return out
end

-- The empty cells that start each lifetime ladder on a fresh row.
function LockerLogic.titleSpacers(ladder: { TitleDef }, lifetime: { LifetimeDef }): { number }
	local _, spacers = plan(#ladder, lifetimeLadders(lifetime))
	return spacers
end

local LADDER_NAME: { [LifetimeStat]: string } = {
	Wins = "Wins",
	StudioVisits = "Studio visits",
	StealWins = "Steals won",
}

local UNIT: { [LifetimeStat]: { string } } = {
	Wins = { "win", "wins" },
	StudioVisits = { "Studio visit", "Studio visits" },
	StealWins = { "steal won", "steals won" },
}

-- "1 win", "50 wins".
function LockerLogic.countText(stat: LifetimeStat, n: number): string
	local unit = UNIT[stat]
	return string.format("%d %s", n, if n == 1 then unit[1] else unit[2])
end

-- A header card's first line.
function LockerLogic.ladderName(stat: LifetimeStat): string
	return LADDER_NAME[stat]
end

-- A title card's second line.
function LockerLogic.titleDetail(row: TitleRow): string
	local need = if row.ladder == "Streak"
		then string.format("best streak %d", row.threshold)
		else LockerLogic.countText(row.ladder :: LifetimeStat, row.threshold)
	if not row.unlocked then
		return "Locked · " .. need
	elseif row.worn then
		return if row.picked then "✓ Wearing" else "✓ Wearing (your highest)"
	end
	return if row.ladder == "Streak" then string.format("Streak %d", row.threshold) else need
end

-- A header card's second line: "12 / 50 wins" toward the next rung,
-- "All 6 earned" at the top, or "2 / 6 earned" off the Hub (no counts).
function LockerLogic.headerDetail(header: LadderHeader): string
	if header.count == nil then
		return string.format("%d / %d earned", header.earned, header.total)
	elseif header.next == nil then
		return string.format("All %d earned", header.total)
	end
	return string.format("%d / %d %s", header.count :: number, header.next :: number, UNIT[header.stat][2])
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

-- ===== unlock toast =========================================================

-- One TitleUnlocked payload as the toast reads it: a streak rung carries
-- `minStreak`, a lifetime rung `lifetime` (TitleService's grant and
-- grantLifetime).
export type Unlock = {
	name: string,
	minStreak: number?,
	lifetime: { stat: LifetimeStat, threshold: number }?,
}

-- The toast for unlocks that arrived together (a join's backfill can be
-- several). One names the title and what earned it; more are counted.
function LockerLogic.unlockToast(unlocks: { Unlock }): string?
	if #unlocks == 0 then
		return nil
	elseif #unlocks > 1 then
		return string.format("%d new titles! Wear one from the Locker.", #unlocks)
	end
	local u = unlocks[1]
	local earned = if u.lifetime ~= nil
		then LockerLogic.countText(u.lifetime.stat, u.lifetime.threshold)
		else string.format("best streak %d", u.minStreak or 0)
	return string.format("New title: %s (%s). Wear it from the Locker.", u.name, earned)
end

-- Whether to hold the toast back. The server already holds streak
-- unlocks until Results (TitleLogic.mayAnnounceUnlock), but the Studio's
-- reveal can still be playing then, and a toast over it would spoil the
-- outcome. Held through Qualified, the Studio and its reveal.
local HOLD_STATES: { [string]: boolean } = { Qualified = true, DecisionStudio = true }

function LockerLogic.holdsUnlockToast(roundState: string?, studioActive: boolean): boolean
	return studioActive or (roundState ~= nil and HOLD_STATES[roundState] == true)
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
