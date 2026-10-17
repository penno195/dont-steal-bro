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
		-- Recorded, so banking it later pays only for wins since (step 4).
		TestRunner.expect(after.streakRestoredAt):toBe(4)
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

TestRunner.describe("Streak Saves", function()
	local function withSaves(saves: number?, offer: StoreLogic.BuyBackOffer?): StoreLogic.GrantState
		local s = state(offer)
		s.streakSaves = saves
		return s
	end

	TestRunner.it("stacks a bought save on top of those held", function()
		local after, lines = StoreLogic.applyGrants(withSaves(2, nil), { { kind = "StreakSave", amount = 1 } })
		TestRunner.expect(after.streakSaves):toBe(3)
		TestRunner.expect(lines[1]):toBe("streak saves +1 (now 3)")
	end)

	TestRunner.it("reads no saves held as 0", function()
		local after = StoreLogic.applyGrants(withSaves(nil, nil), { { kind = "StreakSave", amount = 2 } })
		TestRunner.expect(after.streakSaves):toBe(2)
	end)

	TestRunner.it("spends one to restore the open offer's streak, like a buy-back", function()
		local before = withSaves(2, { roundId = "srv:3", streak = 7 })
		local after, line = StoreLogic.useStreakSave(before)
		TestRunner.expect(after ~= nil):toBe(true)
		local saved = after :: StoreLogic.GrantState
		TestRunner.expect(saved.currentStreak):toBe(7)
		TestRunner.expect(saved.streakRestoredAt):toBe(7)
		TestRunner.expect(saved.streakSaves):toBe(1)
		TestRunner.expect(saved.buyBackOffer == nil):toBe(true)
		TestRunner.expect(line):toBe("streak saved 0 -> 7 with a Streak Save (round srv:3, 1 left)")
		-- The state passed in is untouched.
		TestRunner.expect(before.streakSaves):toBe(2)
		TestRunner.expect(before.buyBackOffer ~= nil):toBe(true)
	end)

	TestRunner.it("refuses with no save held", function()
		local after, reason = StoreLogic.useStreakSave(withSaves(0, { roundId = "srv:3", streak = 7 }))
		TestRunner.expect(after == nil):toBe(true)
		TestRunner.expect(reason):toBe("no Streak Save held")
	end)

	TestRunner.it("refuses with no offer open, and keeps the save", function()
		local before = withSaves(1, nil)
		local after, reason = StoreLogic.useStreakSave(before)
		TestRunner.expect(after == nil):toBe(true)
		TestRunner.expect(reason):toBe("no streak buy-back offer is open")
		TestRunner.expect(before.streakSaves):toBe(1)
	end)
end)
