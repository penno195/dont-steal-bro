--!strict
-- The pure half of showing a win's payout (rewards-roadmap.md step 3):
-- parsing it off the wire, and wording it. Shared by the Decision
-- Studio's reveal (DecisionPersonalResult) and the results screen
-- (RoundRecap), so the two can't word the same win differently. No
-- Roblox API, no requires; tested under Lune (tests/PayoutLogic.spec).
--
-- What may show, and when (design-decisions.md Q7's 2026-10-02 applied
-- case): amounts and levels only once every choice is locked in. Both
-- packets this parses are sent after that point, to their owner only -
-- the reveal shows your own payout, never another finalist's (user
-- decision, recorded under the same applied case).

local PayoutLogic = {}

export type Drop = {
	kind: string, -- "PowerUp" | "Cosmetic"
	id: string,
	rarity: string, -- "Common" | "Uncommon" | "Rare"
	duplicate: boolean, -- an owned cosmetic, paid in coins instead
}

export type Payout = {
	currency: number,
	rung: number,
	drop: Drop?,
	-- The drop grant's amount: a power-up's stock count, or a
	-- duplicate's coins. nil if the server didn't send one.
	dropAmount: number?,
}

-- A display name for a drop, from the config registries. Returns nil
-- for an id it doesn't know, and the line falls back to the raw id.
export type NameOf = (kind: string, id: string) -> string?

local function parseDrop(raw: any): Drop?
	if type(raw) ~= "table" then
		return nil
	end
	if type(raw.kind) ~= "string" or type(raw.id) ~= "string" or type(raw.rarity) ~= "string" then
		return nil
	end
	return table.freeze({
		kind = raw.kind,
		id = raw.id,
		rarity = raw.rarity,
		duplicate = raw.duplicate == true,
	})
end

-- nil for anything malformed: a payout the screen can't trust is one it
-- leaves out rather than half-shows.
function PayoutLogic.parse(raw: any): Payout?
	if type(raw) ~= "table" or type(raw.currency) ~= "number" or type(raw.rung) ~= "number" then
		return nil
	end
	return table.freeze({
		currency = raw.currency,
		rung = raw.rung,
		drop = parseDrop(raw.drop),
		dropAmount = if type(raw.dropAmount) == "number" then raw.dropAmount else nil,
	})
end

function PayoutLogic.coinsLine(payout: Payout): string
	return string.format("+%d coins", payout.currency)
end

-- The drop's own line, or nil when nothing dropped.
--   "2x Freeze"
--   "Rubber Duck"
--   "Rubber Duck - already yours, +40 coins"
function PayoutLogic.dropLine(payout: Payout, nameOf: NameOf?): string?
	local drop = payout.drop
	if drop == nil then
		return nil
	end
	local name = (if nameOf then nameOf(drop.kind, drop.id) else nil) or drop.id
	if drop.duplicate then
		return if payout.dropAmount ~= nil
			then string.format("%s - already yours, +%d coins", name, payout.dropAmount)
			else string.format("%s - already yours, paid in coins", name)
	end
	if drop.kind == "PowerUp" and payout.dropAmount ~= nil and payout.dropAmount > 1 then
		return string.format("%dx %s", payout.dropAmount, name)
	end
	return name
end

-- The caption over the drop: "Rare drop".
function PayoutLogic.dropLabel(drop: Drop): string
	return drop.rarity .. " drop"
end

-- The Icons key for a drop. Power-up ids are Icons keys already
-- (Icons.luau's power-up section); cosmetics have no per-item icon yet,
-- so they share one.
function PayoutLogic.dropIcon(drop: Drop): string
	return if drop.kind == "PowerUp" then drop.id else "gem"
end

-- Everything on one line, for the reveal's result card:
--   "+110 coins"
--   "+110 coins · Rare drop: Rubber Duck"
function PayoutLogic.summary(payout: Payout, nameOf: NameOf?): string
	local coins = PayoutLogic.coinsLine(payout)
	local drop = payout.drop
	local dropText = PayoutLogic.dropLine(payout, nameOf)
	if drop == nil or dropText == nil then
		return coins
	end
	return string.format("%s · %s: %s", coins, PayoutLogic.dropLabel(drop), dropText)
end

-- ===== the stakes, before the choice ========================================
--
-- What each outcome would pay you, shown over the hold buttons from the
-- intro on (DecisionStakes; design-decisions.md Q1's 2026-10-08 case,
-- your own numbers only - the one pre-lock-in exception to Q7).

export type Stakes = {
	soleStealer: number,
	loneSharer: number,
	allShare: number,
	stealDropChance: number, -- 0..1, a sole stealer's win
	shareDropChance: number, -- 0..1, a sharer's win
	streak: number?, -- your own streak (payoff-loop step 6); nil hides its line only
}

export type StakesCopy = {
	amount: string, -- the large-type number
	caption: string, -- when it pays
}

-- nil for anything malformed, the same stance as parse: no panel
-- beats a wrong number.
function PayoutLogic.parseStakes(raw: any): Stakes?
	if type(raw) ~= "table" then
		return nil
	end
	for _, key in { "soleStealer", "loneSharer", "allShare", "stealDropChance", "shareDropChance" } do
		if type(raw[key]) ~= "number" then
			return nil
		end
	end
	return table.freeze({
		soleStealer = raw.soleStealer,
		loneSharer = raw.loneSharer,
		allShare = raw.allShare,
		stealDropChance = math.clamp(raw.stealDropChance, 0, 1),
		shareDropChance = math.clamp(raw.shareDropChance, 0, 1),
		-- Optional: a bad streak drops its line, not the whole panel.
		streak = if type(raw.streak) == "number" and raw.streak >= 0 then math.floor(raw.streak) else nil,
	})
end

-- The Studio's own-streak line (payoff-loop step 6; design-decisions.md
-- Q7). "At stake" even with a shield held (owner, 2026-10-18), and at 0
-- there's nothing to lose, so it points at the win instead.
function PayoutLogic.ownStreakLine(streak: number): string
	if streak <= 0 then
		return "No streak yet: win to start one"
	end
	return string.format("Your streak: %d, at stake", streak)
end

-- A button's own stakes. Share's large number is the all-share amount,
-- captioned with the lone-sharer one (user decision, 2026-10-08).
function PayoutLogic.stakesCopy(stakes: Stakes, choice: string): StakesCopy
	if choice == "Steal" then
		return table.freeze({ amount = tostring(stakes.soleStealer), caption = "only if both share" })
	end
	return table.freeze({
		amount = tostring(stakes.allShare),
		caption = string.format("%d if both steal", stakes.loneSharer),
	})
end

-- "10% item drop", for the win that choice can bring: a sole stealer's
-- roll is the higher one (owner, 2026-10-16). Rounded, so a 0.3 that
-- floats as 0.29999 still reads 30.
function PayoutLogic.dropChanceLine(stakes: Stakes, choice: string): string
	local chance = if choice == "Steal" then stakes.stealDropChance else stakes.shareDropChance
	return string.format("%d%% item drop", math.floor(chance * 100 + 0.5))
end

-- A finale-card prize box's own numbers (owner, 2026-10-16): the same
-- stakes as the hold buttons, up earlier so there's longer to study
-- them. BIG is the sole stealer's win, MEDIUM the lone sharer's, SMALL
-- everyone sharing. nil for NOTHING, or any prize it doesn't know.
local TILE_STAKES: { [string]: { coins: string, steal: boolean } } = {
	Big = { coins = "soleStealer", steal = true },
	Medium = { coins = "loneSharer", steal = false },
	Small = { coins = "allShare", steal = false },
}

function PayoutLogic.tileLine(stakes: Stakes, prize: string): string?
	local entry = TILE_STAKES[prize]
	if entry == nil then
		return nil
	end
	local coins = (stakes :: any)[entry.coins] :: number
	local chance = if entry.steal then stakes.stealDropChance else stakes.shareDropChance
	return string.format("%d coins · %d%% drop", coins, math.floor(chance * 100 + 0.5))
end

return PayoutLogic
