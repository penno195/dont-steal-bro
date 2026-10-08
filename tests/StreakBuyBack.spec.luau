--!strict
-- Covers buying back a lost streak (design-decisions.md Q7, "buying back
-- a streak"): which losses open an offer (ProgressionLogic.buyBackOffer),
-- which price tier covers it, what the grant restores, and when the
-- offer may be shown (StoreLogic).

local TestRunner = require("./TestRunner")
local ProgressionLogic = require("../src/server/ProgressionLogic")
local StoreLogic = require("../src/server/StoreLogic")

local function tier(min: number, max: number?): StoreLogic.Grant
	return { kind = "StreakBuyBack", minStreak = min, maxStreak = max }
end

local function state(offer: StoreLogic.BuyBackOffer?): StoreLogic.GrantState
	return {
		currency = 0,
		powerUpStock = {},
		ownedCosmetics = {},
		unlockedTitles = {},
		currentStreak = 0,
		buyBackOffer = offer,
	}
end

TestRunner.describe("ProgressionLogic.buyBackOffer", function()
	TestRunner.it("opens an offer for any loss of a streak of 1 or more", function()
		local before = { currentStreak = 5, bestStreak = 9 }
		for _, reason in { "StudioLoss", "FailedToQualify", "ForfeitDisconnect" } do
			local offer = ProgressionLogic.buyBackOffer("r1", before, reason :: any)
			TestRunner.expect(offer and offer.streak):toBe(5)
			TestRunner.expect(offer and offer.roundId):toBe("r1")
		end
	end)

	TestRunner.it("opens none for a win or for losing a streak of 0", function()
		TestRunner.expect(
			ProgressionLogic.buyBackOffer("r1", { currentStreak = 5, bestStreak = 5 }, "StudioWinAllShare") == nil
		)
			:toBe(true)
		TestRunner.expect(
			ProgressionLogic.buyBackOffer("r1", { currentStreak = 0, bestStreak = 5 }, "StudioLoss") == nil
		)
			:toBe(true)
	end)
end)

TestRunner.describe("StoreLogic.buyBackCovers", function()
	TestRunner.it("prices a streak inside its tier only", function()
		TestRunner.expect(StoreLogic.buyBackCovers(tier(2, 2), 2)):toBe(true)
		TestRunner.expect(StoreLogic.buyBackCovers(tier(2, 2), 1)):toBe(false)
		TestRunner.expect(StoreLogic.buyBackCovers(tier(2, 2), 3)):toBe(false)
	end)

	TestRunner.it("reads an open top tier as that many or more", function()
		TestRunner.expect(StoreLogic.buyBackCovers(tier(8, nil), 8)):toBe(true)
		TestRunner.expect(StoreLogic.buyBackCovers(tier(8, nil), 40)):toBe(true)
		TestRunner.expect(StoreLogic.buyBackCovers(tier(8, nil), 7)):toBe(false)
	end)

	TestRunner.it("never matches another grant kind", function()
		TestRunner.expect(StoreLogic.buyBackCovers({ kind = "Currency", amount = 1, minStreak = 1 }, 1)):toBe(false)
	end)
end)

TestRunner.describe("StoreLogic.applyGrants and StreakBuyBack", function()
	TestRunner.it("restores the lost streak, no higher, and closes the offer", function()
		local after, lines = StoreLogic.applyGrants(state({ roundId = "r1", streak = 4 }), { tier(4, 4) })
		TestRunner.expect(after.currentStreak):toBe(4)
		TestRunner.expect(after.buyBackOffer == nil):toBe(true)
		TestRunner.expect(string.find(lines[1], "bought back 0 -> 4", 1, true) ~= nil):toBeTruthy()
	end)

	TestRunner.it("buys nothing with no offer open", function()
		local after, lines = StoreLogic.applyGrants(state(nil), { tier(1, 1) })
		TestRunner.expect(after.currentStreak):toBe(0)
		TestRunner.expect(string.find(lines[1], "NOTHING", 1, true) ~= nil):toBeTruthy()
	end)

	TestRunner.it("buys nothing in the wrong tier, and leaves the offer open", function()
		local after = StoreLogic.applyGrants(state({ roundId = "r1", streak = 12 }), { tier(1, 1) })
		TestRunner.expect(after.currentStreak):toBe(0)
		TestRunner.expect(after.buyBackOffer and after.buyBackOffer.streak):toBe(12)
	end)

	TestRunner.it("knows which products sell a buy-back", function()
		TestRunner.expect(StoreLogic.grantsStreakBuyBack({ tier(1, 1) })):toBe(true)
		TestRunner.expect(StoreLogic.grantsStreakBuyBack({ { kind = "Currency", amount = 1 } })):toBe(false)
	end)
end)

TestRunner.describe("StoreLogic.mayShowBuyBack", function()
	local offer = { roundId = "srv:3", streak = 6 }

	TestRunner.it("holds this round's offer back until Results (Q7)", function()
		for _, phase in { "Race", "Qualified", "DecisionStudio" } do
			TestRunner.expect(StoreLogic.mayShowBuyBack(offer, "srv:3", phase)):toBe(false)
		end
		TestRunner.expect(StoreLogic.mayShowBuyBack(offer, "srv:3", "Results")):toBe(true)
		TestRunner.expect(StoreLogic.mayShowBuyBack(offer, "srv:3", "Cleanup")):toBe(true)
	end)

	TestRunner.it("shows an earlier round's offer anywhere, the Hub included", function()
		TestRunner.expect(StoreLogic.mayShowBuyBack(offer, "pre-round", "WaitingForPlayers")):toBe(true)
	end)

	TestRunner.it("shows nothing with no offer", function()
		TestRunner.expect(StoreLogic.mayShowBuyBack(nil, "srv:3", "Results")):toBe(false)
	end)
end)
