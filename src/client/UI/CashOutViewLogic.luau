--!strict
-- The pure half of banking a streak in the Hub (payoff-loop step 4;
-- design-decisions.md Q7's cash-out case): reading StoreState's `cashOut`
-- card, and every line the card, its confirm step and the result toast
-- say. No Roblox API, no requires; tested under Lune
-- (tests/CashOutViewLogic.spec).
--
-- The server works out every number (CashOutLogic) and only sends the
-- card on the Hub, to its owner. This only words it.

local CashOutViewLogic = {}

-- StoreState.cashOut, as the server sends it (StoreService.cashOutCard).
export type Card = {
	streak: number,
	wins: number, -- the wins paid for: fewer than the streak after a restore
	coins: number,
	available: boolean,
	refusal: string?, -- CashOutLogic.Refusal when not available
	minStreak: number,
	bestBanked: number,
}

local function isCount(value: any): boolean
	return type(value) == "number" and value == value and value >= 0
end

-- A card, checked for shape. nil (off the Hub, or malformed) hides the
-- launcher's bank button.
function CashOutViewLogic.parse(value: any): Card?
	if
		type(value) ~= "table"
		or not isCount(value.streak)
		or not isCount(value.wins)
		or not isCount(value.coins)
		or type(value.available) ~= "boolean"
		or not isCount(value.minStreak)
		or not isCount(value.bestBanked)
	then
		return nil
	end
	return {
		streak = value.streak,
		wins = value.wins,
		coins = value.coins,
		available = value.available,
		refusal = if type(value.refusal) == "string" then value.refusal else nil,
		minStreak = value.minStreak,
		bestBanked = value.bestBanked,
	}
end

CashOutViewLogic.TITLE = "Bank your streak"

-- Why it can't be banked yet, or what banking it pays.
function CashOutViewLogic.payLine(card: Card): string
	if card.available then
		if card.wins < card.streak then
			return string.format(
				"Bank it for %d coins. A restored streak pays only for wins since: %d so far.",
				card.coins,
				card.wins
			)
		end
		return string.format("Bank it for %d coins.", card.coins)
	elseif card.refusal == "NoWinSinceRestore" then
		return "Win once more to bank it: a restored streak pays only for wins since."
	end
	return string.format("Reach a streak of %d to bank it.", card.minStreak)
end

function CashOutViewLogic.bestLine(card: Card): string
	return if card.bestBanked > 0 then string.format("Best banked: %d", card.bestBanked) else "Nothing banked yet."
end

-- The card's body: the streak, what it pays, the best banked.
function CashOutViewLogic.body(card: Card): string
	return string.format(
		"Your streak: %d\n%s\n%s",
		card.streak,
		CashOutViewLogic.payLine(card),
		CashOutViewLogic.bestLine(card)
	)
end

function CashOutViewLogic.bankLabel(card: Card): string
	return if card.available then string.format("Bank for %d coins", card.coins) else "Can't bank yet"
end

-- The confirm step: banking can't be undone.
function CashOutViewLogic.confirmTitle(card: Card): string
	return string.format("Bank your %d-win streak?", card.streak)
end

CashOutViewLogic.CONFIRM_BODY =
	"Your streak goes back to 0. Your best streak, titles, leaderboard place and streak shields all stay."

function CashOutViewLogic.confirmLabel(card: Card): string
	return string.format("Bank %d coins", card.coins)
end

CashOutViewLogic.KEEP_LABEL = "Keep my streak"

-- StreakCashOutResult, worded for a toast. Returns the text and whether
-- it was a success.
function CashOutViewLogic.resultToast(payload: any): (string, boolean)
	if
		type(payload) == "table"
		and payload.status == "Banked"
		and isCount(payload.streak)
		and isCount(payload.coins)
	then
		return string.format("Banked your %d-win streak: +%d coins", payload.streak, payload.coins), true
	end
	local reason = if type(payload) == "table" then payload.reason else nil
	if reason == "StreakChanged" then
		return "Your streak changed. Check the new amount and try again.", false
	elseif reason == "NotHub" then
		return "You can only bank your streak in the Hub.", false
	elseif reason == "BelowMinimum" or reason == "NoWinSinceRestore" then
		return "That streak can't be banked yet.", false
	end
	return "Couldn't bank it right now. Your streak is safe.", false
end

CashOutViewLogic.TIMEOUT_TOAST = "No answer from the server. Your streak is safe."

return CashOutViewLogic
