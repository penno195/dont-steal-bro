--!strict
-- Covers CashOutViewLogic.luau: the Hub's bank card (payoff-loop step 4)
-- - reading StoreState.cashOut, and what the card, the confirm step and
-- the result toast say.

local TestRunner = require("./TestRunner")
local CashOutViewLogic = require("../src/client/UI/CashOutViewLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function card(overrides: { [string]: any }?): CashOutViewLogic.Card
	local c: any = {
		streak = 5,
		wins = 5,
		coins = 625,
		available = true,
		refusal = nil,
		minStreak = 3,
		bestBanked = 0,
	}
	for k, v in overrides or {} do
		c[k] = v
	end
	return c
end

describe("CashOutViewLogic.parse", function()
	it("reads the server's card", function()
		local parsed = CashOutViewLogic.parse({
			streak = 22,
			wins = 2,
			coins = 100,
			available = true,
			minStreak = 3,
			bestBanked = 9,
		})
		expect(parsed and parsed.coins):toBe(100)
		expect(parsed and parsed.refusal):toBe(nil)
	end)

	it("drops a missing or malformed card, which hides the button", function()
		expect(CashOutViewLogic.parse(nil)):toBe(nil)
		expect(CashOutViewLogic.parse({ streak = 5 })):toBe(nil)
		expect(CashOutViewLogic.parse({
			streak = -1,
			wins = 0,
			coins = 0,
			available = false,
			minStreak = 3,
			bestBanked = 0,
		})):toBe(nil)
	end)
end)

describe("CashOutViewLogic card copy", function()
	it("says what banking pays", function()
		expect(CashOutViewLogic.body(card())):toBe("Your streak: 5\nBank it for 625 coins.\nNothing banked yet.")
		expect(CashOutViewLogic.bankLabel(card())):toBe("Bank for 625 coins")
	end)

	it("explains a restored streak paying only for wins since", function()
		local restored = card({ streak = 22, wins = 2, coins = 100, bestBanked = 9 })
		expect(CashOutViewLogic.payLine(restored)):toBe(
			"Bank it for 100 coins. A restored streak pays only for wins since: 2 so far."
		)
		expect(CashOutViewLogic.bestLine(restored)):toBe("Best banked: 9")
	end)

	it("says why not, when it can't be banked yet", function()
		local low = card({ streak = 2, wins = 2, coins = 100, available = false, refusal = "BelowMinimum" })
		expect(CashOutViewLogic.payLine(low)):toBe("Reach a streak of 3 to bank it.")
		expect(CashOutViewLogic.bankLabel(low)):toBe("Can't bank yet")
		local noWin = card({ streak = 20, wins = 0, coins = 0, available = false, refusal = "NoWinSinceRestore" })
		expect(CashOutViewLogic.payLine(noWin)):toBe(
			"Win once more to bank it: a restored streak pays only for wins since."
		)
	end)

	it("asks before banking, naming the streak and the coins", function()
		expect(CashOutViewLogic.confirmTitle(card())):toBe("Bank your 5-win streak?")
		expect(CashOutViewLogic.confirmLabel(card())):toBe("Bank 625 coins")
	end)
end)

describe("CashOutViewLogic.resultToast", function()
	it("toasts a bank as a success", function()
		local text, ok = CashOutViewLogic.resultToast({ status = "Banked", streak = 5, coins = 625 })
		expect(text):toBe("Banked your 5-win streak: +625 coins")
		expect(ok):toBe(true)
	end)

	it("words each refusal, and anything odd as a safe failure", function()
		local changed, ok = CashOutViewLogic.resultToast({ status = "Refused", reason = "StreakChanged" })
		expect(changed):toBe("Your streak changed. Check the new amount and try again.")
		expect(ok):toBe(false)
		expect((CashOutViewLogic.resultToast({ status = "Refused", reason = "NotHub" }))):toBe(
			"You can only bank your streak in the Hub."
		)
		expect((CashOutViewLogic.resultToast(nil))):toBe("Couldn't bank it right now. Your streak is safe.")
		expect((CashOutViewLogic.resultToast({ status = "Banked" }))):toBe(
			"Couldn't bank it right now. Your streak is safe."
		)
	end)
end)
