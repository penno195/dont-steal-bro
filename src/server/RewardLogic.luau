--!strict
-- What a win pays: design-decisions.md Q1's 2026-09-30 revision and its
-- 2026-10-02 applied case, as arithmetic. Every win pays currency for
-- its outcome tier, scaled by the winner's title-ladder rung, and rolls
-- a chance at one random drop (a power-up or a cosmetic) whose odds
-- improve with that rung. The service that applies the result to a
-- profile is not built yet (docs/rewards-roadmap.md step 2b).
--
-- Self-contained on purpose - no requires of sibling files, no Roblox
-- API calls - so it stays requirable under Lune for headless tests
-- (tests/RewardLogic.spec.luau), the same shape StoreLogic and
-- ProgressionLogic take (Ground Rule 4). The types below duplicate the
-- slices of Validate's types this module reads; Luau's structural typing
-- means real config values satisfy them with no cast.
--
-- Randomness comes in as `rng`, a function returning a number in [0, 1).
-- The server passes a Random's NextNumber; tests pass a fixed sequence,
-- so every branch of a roll is a deterministic test case.
--
-- Q1's rule that nothing BOUGHT is ever random is kept by where this is
-- called from, not by anything in here: a win is the only caller.

local RewardLogic = {}

-- ===== types ================================================================

export type OutcomeTag = "SoleStealer" | "LoneSharer" | "AllShare"
export type Rarity = "Common" | "Uncommon" | "Rare"

export type RarityNumbers = { Common: number, Uncommon: number, Rare: number }

export type DropRarityWeight = { weight: number, perRungGrowth: number }

export type WinRewardsConfig = {
	currency: { soleStealer: number, loneSharer: number, allShare: number, perRungBonus: number },
	drop: {
		baseChance: number,
		perRungChance: number,
		maxChance: number,
		rarityWeights: { Common: DropRarityWeight, Uncommon: DropRarityWeight, Rare: DropRarityWeight },
		powerUpAmount: number,
		duplicateCurrency: RarityNumbers,
	},
}

-- The slices of PowerUpDef and CosmeticDef the drop pool reads.
export type PowerUpSource = {
	id: string,
	rarity: Rarity,
	acquisition: { loadoutEligible: boolean, freelyEarnable: boolean },
}

export type CosmeticSource = {
	id: string,
	rarity: Rarity,
	enabled: boolean,
	winDrop: boolean?,
}

export type PoolItem = {
	kind: "PowerUp" | "Cosmetic",
	id: string,
	rarity: Rarity,
}

-- Structurally StoreLogic.Grant, so the result goes straight into
-- StoreLogic.applyGrants - one grant path for purchases and wins alike.
export type Grant = {
	kind: "Currency" | "PowerUpStock" | "Cosmetic",
	amount: number?,
	powerUpId: string?,
	cosmeticId: string?,
}

export type Drop = {
	item: PoolItem,
	duplicate: boolean, -- a cosmetic already owned: paid as currency instead
	grant: Grant,
}

export type WinReward = {
	rung: number,
	currency: number,
	drop: Drop?,
	grants: { Grant }, -- the currency, then the drop's grant if there was one
}

local RARITIES: { Rarity } = { "Common", "Uncommon", "Rare" }

-- ===== the rung =============================================================

-- How many ladder rungs `streak` reaches. `thresholds` is every title's
-- minStreak - the ladder IS the title list, so a new rung costs one
-- title file and nothing here. Called with the streak AFTER the win, so
-- a first-ever win is rung 1 (applied case, 2026-10-02).
function RewardLogic.rungFor(thresholds: { number }, streak: number): number
	local rung = 0
	for _, minStreak in thresholds do
		if streak >= minStreak then
			rung += 1
		end
	end
	return rung
end

-- ===== currency =============================================================

function RewardLogic.currencyFor(config: WinRewardsConfig, outcomeTag: OutcomeTag, rung: number): number
	local currency = config.currency
	local base = if outcomeTag == "SoleStealer"
		then currency.soleStealer
		elseif outcomeTag == "LoneSharer" then currency.loneSharer
		else currency.allShare
	-- The epsilon stops float error flooring an exact 55 to 54.
	return math.floor(base * (1 + currency.perRungBonus * rung) + 1e-9)
end

-- ===== the drop =============================================================

function RewardLogic.dropChanceFor(config: WinRewardsConfig, rung: number): number
	local drop = config.drop
	return math.min(drop.maxChance, drop.baseChance + drop.perRungChance * rung)
end

function RewardLogic.rarityWeightsFor(config: WinRewardsConfig, rung: number): RarityNumbers
	local weights = config.drop.rarityWeights
	local function at(entry: DropRarityWeight): number
		return entry.weight * (1 + entry.perRungGrowth * rung)
	end
	return {
		Common = at(weights.Common),
		Uncommon = at(weights.Uncommon),
		Rare = at(weights.Rare),
	}
end

-- Everything a win can drop (applied case, 2026-10-02): power-ups that
-- are freely earnable AND loadout-eligible (a drop is loadout stock, so
-- an item that can't go in a loadout would be a dead grant), plus
-- enabled cosmetics that opt in with `winDrop`. Sorted by id so a roll
-- never depends on registry order.
function RewardLogic.buildDropPool(powerUps: { PowerUpSource }, cosmetics: { CosmeticSource }): { PoolItem }
	local pool: { PoolItem } = {}
	for _, def in powerUps do
		if def.acquisition.freelyEarnable and def.acquisition.loadoutEligible then
			table.insert(pool, { kind = "PowerUp", id = def.id, rarity = def.rarity })
		end
	end
	for _, def in cosmetics do
		if def.enabled and def.winDrop == true then
			table.insert(pool, { kind = "Cosmetic", id = def.id, rarity = def.rarity })
		end
	end
	table.sort(pool, function(a, b)
		return a.id < b.id
	end)
	return pool
end

-- Picks an index into `weights` with probability proportional to its
-- weight. `roll` is in [0, 1). Zero-weight entries are never picked.
local function pickWeighted(weights: { number }, roll: number): number?
	local total = 0
	for _, weight in weights do
		total += weight
	end
	if total <= 0 then
		return nil
	end
	local target = roll * total
	local running = 0
	local last: number? = nil
	for index, weight in weights do
		if weight > 0 then
			running += weight
			last = index
			if target < running then
				return index
			end
		end
	end
	return last -- float rounding at roll ~ 1
end

-- One drop roll: whether anything drops, which rarity, which item. Three
-- `rng` calls at most, in that order. A rarity with no items in the pool
-- is left out of the rarity roll, so an empty Rare tier can't swallow a
-- drop the chance roll already granted.
function RewardLogic.rollDrop(
	config: WinRewardsConfig,
	rung: number,
	pool: { PoolItem },
	ownedCosmetics: { string },
	rng: () -> number
): Drop?
	if #pool == 0 or rng() >= RewardLogic.dropChanceFor(config, rung) then
		return nil
	end

	-- Keyed by plain string: iterating RARITIES widens Rarity to string.
	local byRarity: { [string]: { PoolItem } } = { Common = {}, Uncommon = {}, Rare = {} }
	for _, item in pool do
		table.insert(byRarity[item.rarity], item)
	end

	local rarityWeights = RewardLogic.rarityWeightsFor(config, rung)
	-- In RARITIES order.
	local weights: { number } = { rarityWeights.Common, rarityWeights.Uncommon, rarityWeights.Rare }
	for index, rarity in RARITIES do
		if #byRarity[rarity] == 0 then
			weights[index] = 0
		end
	end
	local rarityIndex = pickWeighted(weights, rng())
	if rarityIndex == nil then
		return nil -- every rarity that has items has weight 0
	end

	local candidates = byRarity[RARITIES[rarityIndex]]
	local item = candidates[math.min(#candidates, math.floor(rng() * #candidates) + 1)]

	if item.kind == "PowerUp" then
		return {
			item = item,
			duplicate = false,
			grant = { kind = "PowerUpStock", powerUpId = item.id, amount = config.drop.powerUpAmount },
		}
	end
	if table.find(ownedCosmetics, item.id) ~= nil then
		return {
			item = item,
			duplicate = true,
			grant = { kind = "Currency", amount = config.drop.duplicateCurrency[item.rarity] },
		}
	end
	return { item = item, duplicate = false, grant = { kind = "Cosmetic", cosmeticId = item.id } }
end

-- ===== the whole win ========================================================

-- Everything one win pays. `streakAfter` is the streak this win took the
-- winner to. The grants are ready for StoreLogic.applyGrants.
function RewardLogic.rollWinReward(
	config: WinRewardsConfig,
	outcomeTag: OutcomeTag,
	streakAfter: number,
	thresholds: { number },
	pool: { PoolItem },
	ownedCosmetics: { string },
	rng: () -> number
): WinReward
	local rung = RewardLogic.rungFor(thresholds, streakAfter)
	local currency = RewardLogic.currencyFor(config, outcomeTag, rung)
	local drop = RewardLogic.rollDrop(config, rung, pool, ownedCosmetics, rng)

	local grants: { Grant } = { { kind = "Currency", amount = currency } }
	if drop ~= nil then
		table.insert(grants, drop.grant)
	end
	return { rung = rung, currency = currency, drop = drop, grants = grants }
end

return RewardLogic
