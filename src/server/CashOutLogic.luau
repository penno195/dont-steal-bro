--!strict
-- Banking a streak in the Hub (payoff-loop step 4; design-decisions.md
-- Q7's "streak cash-out" case), as arithmetic. ProgressionService is the
-- Roblox-touching half: it reads the profile, asks `offer`, and writes
-- the answer through the one progression writer.
--
-- THE RULES (owner, 2026-10-17):
--   - Banking pays coinsPerWinSquared * w^2 coins and resets the
--     streak to 0. bestStreak, titles and the leaderboard don't move.
--   - w is the wins paid for. Normally the whole streak, but a streak a
--     buy-back or Streak Save restored pays only for the wins since the
--     restore: otherwise "lose at 20, restore, bank 20" would buy coins
--     far cheaper than the coin packs. The profile keeps the streak the
--     last restore brought back (`streakRestoredAt`).
--   - The minimum (minStreak) checks the FULL streak, restored or not.
--   - Claude's call: a bank that would pay 0 coins is refused, since it
--     would only throw the streak away.
--   - "Best banked" is the full streak banked, the most ever.
--
-- No Roblox API, no requires: tested under Lune (tests/CashOutLogic.spec).

local CashOutLogic = {}

export type Config = {
	minStreak: number,
	coinsPerWinSquared: number,
}

export type Refusal =
	"BelowMinimum" -- the streak is under minStreak
	| "NoWinSinceRestore" -- restored, and not won since: it would pay 0
	| "StreakChanged" -- the streak isn't the one the player confirmed

export type Offer = {
	streak: number, -- the streak that would be banked
	wins: number, -- the wins paid for
	coins: number,
	available: boolean,
	refusal: Refusal?, -- why not, when not available
}

-- The wins a bank pays for: the streak, less what the last restore
-- brought back. A restore above the streak can't be current (the writer
-- clears it when the streak resets), so it's read as covering it all.
function CashOutLogic.paidWins(streak: number, restoredAt: number): number
	return math.max(0, streak - math.clamp(restoredAt, 0, math.max(streak, 0)))
end

function CashOutLogic.coinsFor(config: Config, wins: number): number
	return config.coinsPerWinSquared * wins * wins
end

-- What banking this streak would pay right now, and whether it may.
function CashOutLogic.offer(config: Config, streak: number, restoredAt: number): Offer
	local wins = CashOutLogic.paidWins(streak, restoredAt)
	local coins = CashOutLogic.coinsFor(config, wins)
	local refusal: Refusal? = nil
	if streak < config.minStreak then
		refusal = "BelowMinimum"
	elseif coins <= 0 then
		refusal = "NoWinSinceRestore"
	end
	return { streak = streak, wins = wins, coins = coins, available = refusal == nil, refusal = refusal }
end

-- The server's check on a bank request. `expectedStreak` is the streak
-- the player saw when they confirmed: a different one (a restore that
-- landed in between) is refused, so nobody banks a number they didn't
-- agree to.
function CashOutLogic.validate(offer: Offer, expectedStreak: number): (boolean, Refusal?)
	if not offer.available then
		return false, offer.refusal
	end
	if offer.streak ~= expectedStreak then
		return false, "StreakChanged"
	end
	return true, nil
end

-- The streak after a bank: 0, with the best untouched.
function CashOutLogic.after(before: { currentStreak: number, bestStreak: number }): {
	currentStreak: number,
	bestStreak: number,
}
	return { currentStreak = 0, bestStreak = before.bestStreak }
end

function CashOutLogic.bestBankedAfter(bestBanked: number, streak: number): number
	return math.max(bestBanked, streak)
end

-- What `streakRestoredAt` becomes once the streak is `streakAfter`: a
-- streak back at 0 (a loss, or a bank) has nothing restored in it any
-- more. Anything else keeps it - a win builds on the restored streak.
function CashOutLogic.restoredAtAfter(restoredAt: number, streakAfter: number): number
	return if streakAfter <= 0 then 0 else restoredAt
end

-- The audit line, beside ProgressionLogic.formatAudit's.
function CashOutLogic.formatAudit(playerName: string, offer: Offer, restoredAt: number): string
	return string.format(
		"Progression: %s reason=CashOut streak %d->0 paid %d wins (restored at %d) +%d coins",
		playerName,
		offer.streak,
		offer.wins,
		restoredAt,
		offer.coins
	)
end

return CashOutLogic
