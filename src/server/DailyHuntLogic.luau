--!strict
-- The daily hunt (design-decisions.md Q1, "the daily hunt"): which spot
-- is a player's today, whether they may still claim it, and what it pays.
-- Pure; DailyHuntService supplies the clock, the spots and the roll.
--
-- WHICH SPOT: a hash of "<userId>|<dayKey>" into the hub's spots, in a
-- fixed order (spotOrder), so the server picks the same one on every
-- server and every rejoin that day, and friends get different spots.
-- The day is PeriodKeys.dayKey's UTC day, so the client can't move it.
--
-- WHAT IT PAYS: a 50/50 (GameConfig.dailyHunt.powerUpChance) between
-- one freely earnable power-up and a power-up's coin price. It doesn't
-- grow with consecutive days (the season pass's free track rewards
-- coming back), so nothing here reads past claims beyond the last day.

local DailyHuntLogic = {}

export type Config = {
	powerUpChance: number,
	coins: number,
}

-- Structurally StoreLogic.Grant (only the two kinds the hunt pays).
export type Grant = {
	kind: "Currency" | "PowerUpStock",
	amount: number,
	powerUpId: string?,
}

export type SpotKey = {
	name: string, -- the spot's full name in the DataModel
	x: number,
	y: number,
	z: number,
}

-- A 31-bit string hash (polynomial, mod the prime 2^31 - 1). Every step
-- stays below 2^37, well inside a double's exact range, so it gives the
-- same answer in Studio, on a live server and under Lune. Not secure:
-- it only has to spread players over spots, and the server never trusts
-- a client's idea of which spot is theirs.
function DailyHuntLogic.hash(text: string): number
	local h = 0
	for i = 1, #text do
		h = (h * 31 + string.byte(text, i)) % 2147483647
	end
	return h
end

-- Today's spot for this player, as a 1-based index into `spotCount`
-- spots in spotOrder's order; nil when the hub has none.
function DailyHuntLogic.spotIndex(userId: number, dayKey: string, spotCount: number): number?
	if spotCount < 1 then
		return nil
	end
	return DailyHuntLogic.hash(string.format("%d|%s", userId, dayKey)) % spotCount + 1
end

-- The order spots are indexed in: by full name, then position, so two
-- same-named spots still sort the same way on every server. Returns
-- indices into `spots`, which it doesn't reorder.
function DailyHuntLogic.spotOrder(spots: { SpotKey }): { number }
	local order: { number } = {}
	for i = 1, #spots do
		order[i] = i
	end
	table.sort(order, function(a: number, b: number): boolean
		local sa, sb = spots[a], spots[b]
		if sa.name ~= sb.name then
			return sa.name < sb.name
		end
		if sa.x ~= sb.x then
			return sa.x < sb.x
		end
		if sa.y ~= sb.y then
			return sa.y < sb.y
		end
		return sa.z < sb.z
	end)
	return order
end

-- Once per UTC day: a claim is open unless the last one was today.
function DailyHuntLogic.isOpen(lastHuntDay: string?, dayKey: string): boolean
	return lastHuntDay ~= dayKey
end

-- What a claim pays. `powerUpIds` are the power-ups it may give (freely
-- earnable, loadout-eligible and switched on); with none, it pays coins.
-- `roll` returns [0, 1), and is called twice at most: once for the
-- 50/50, once for which power-up.
function DailyHuntLogic.rollReward(config: Config, powerUpIds: { string }, roll: () -> number): Grant
	if #powerUpIds > 0 and roll() < config.powerUpChance then
		local pick = math.clamp(math.floor(roll() * #powerUpIds) + 1, 1, #powerUpIds)
		return { kind = "PowerUpStock", amount = 1, powerUpId = powerUpIds[pick] }
	end
	return { kind = "Currency", amount = config.coins }
end

return DailyHuntLogic
