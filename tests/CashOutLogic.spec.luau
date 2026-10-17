--!strict
-- Covers CashOutLogic.luau: banking a streak in the Hub (payoff-loop
-- step 4; design-decisions.md Q7's "streak cash-out" case). The curve,
-- the streak-3 minimum, a restored streak paying only for wins since,
-- the server's check, and what the bank leaves behind.

local TestRunner = require("./TestRunner")
local CashOutLogic = require("../src/server/CashOutLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local CONFIG: CashOutLogic.Config = { minStreak = 3, coinsPerWinSquared = 25 }

describe("CashOutLogic.offer", function()
	it("pays 25 x s^2 for an unrestored streak, from streak 3", function()
		local three = CashOutLogic.offer(CONFIG, 3, 0)
		expect(three.available):toBe(true)
		expect(three.coins):toBe(225)
		expect(CashOutLogic.offer(CONFIG, 5, 0).coins):toBe(625)
		expect(CashOutLogic.offer(CONFIG, 10, 0).coins):toBe(2500)
		expect(CashOutLogic.offer(CONFIG, 20, 0).coins):toBe(10000)
	end)

	it("refuses a streak under the minimum", function()
		local two = CashOutLogic.offer(CONFIG, 2, 0)
		expect(two.available):toBe(false)
		expect(two.refusal):toBe("BelowMinimum")
		expect(CashOutLogic.offer(CONFIG, 0, 0).refusal):toBe("BelowMinimum")
	end)

	it("pays a restored streak only for the wins since the restore", function()
		local offer = CashOutLogic.offer(CONFIG, 22, 20)
		expect(offer.wins):toBe(2)
		expect(offer.coins):toBe(100)
		expect(offer.available):toBe(true)
	end)

	it("checks the minimum against the full streak, restored or not", function()
		-- Restored at 2, won once: 3 is enough to bank, and pays for 1 win.
		local offer = CashOutLogic.offer(CONFIG, 3, 2)
		expect(offer.available):toBe(true)
		expect(offer.wins):toBe(1)
		expect(offer.coins):toBe(25)
	end)

	it("refuses a restored streak with no win since, which would pay 0", function()
		local offer = CashOutLogic.offer(CONFIG, 20, 20)
		expect(offer.available):toBe(false)
		expect(offer.refusal):toBe("NoWinSinceRestore")
		expect(offer.coins):toBe(0)
	end)

	it("never pays for more wins than the streak, or fewer than none", function()
		expect(CashOutLogic.paidWins(5, 9)):toBe(0)
		expect(CashOutLogic.paidWins(5, -3)):toBe(5)
		expect(CashOutLogic.paidWins(0, 0)):toBe(0)
	end)
end)

describe("CashOutLogic.validate", function()
	it("takes the streak the player confirmed", function()
		local ok, refusal = CashOutLogic.validate(CashOutLogic.offer(CONFIG, 5, 0), 5)
		expect(ok):toBe(true)
		expect(refusal):toBe(nil)
	end)

	it("refuses a streak that changed since the player confirmed", function()
		local ok, refusal = CashOutLogic.validate(CashOutLogic.offer(CONFIG, 7, 0), 5)
		expect(ok):toBe(false)
		expect(refusal):toBe("StreakChanged")
	end)

	it("passes an unavailable offer's own reason on", function()
		local ok, refusal = CashOutLogic.validate(CashOutLogic.offer(CONFIG, 2, 0), 2)
		expect(ok):toBe(false)
		expect(refusal):toBe("BelowMinimum")
	end)
end)

describe("CashOutLogic after a bank", function()
	it("resets the streak to 0 and leaves the best alone", function()
		local after = CashOutLogic.after({ currentStreak = 6, bestStreak = 11 })
		expect(after.currentStreak):toBe(0)
		expect(after.bestStreak):toBe(11)
	end)

	it("keeps the best banked as the most ever banked", function()
		expect(CashOutLogic.bestBankedAfter(0, 5)):toBe(5)
		expect(CashOutLogic.bestBankedAfter(9, 5)):toBe(9)
	end)

	it("clears the restore once the streak is back at 0, and keeps it otherwise", function()
		expect(CashOutLogic.restoredAtAfter(20, 0)):toBe(0)
		expect(CashOutLogic.restoredAtAfter(20, 21)):toBe(20)
	end)

	it("logs one audit line on the Progression prefix", function()
		local line = CashOutLogic.formatAudit("Alex", CashOutLogic.offer(CONFIG, 22, 20), 20)
		expect(line):toBe("Progression: Alex reason=CashOut streak 22->0 paid 2 wins (restored at 20) +100 coins")
	end)
end)
