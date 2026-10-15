--!strict
-- Covers TutorialLogic.luau: what finishing the guided practice round
-- pays (design-decisions.md, "the first-time tutorial"). The once-only
-- write is DataService.claimTutorialReward, exercised in Studio.

local TestRunner = require("./TestRunner")
local TutorialLogic = require("../src/server/TutorialLogic")
local StoreLogic = require("../src/server/StoreLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local CONFIG = {
	rewardCosmeticId = "hat-rookie-cap",
	rewardCurrency = 100,
	rewardPowerUps = { freeze = 1 },
}

describe("TutorialLogic.rewardGrants", function()
	it("pays the cap, the coins and the power-up", function()
		local grants = TutorialLogic.rewardGrants(CONFIG, true)
		expect(#grants):toBe(3)
		expect(grants[1].kind):toBe("Cosmetic")
		expect(grants[1].cosmeticId):toBe("hat-rookie-cap")
		expect(grants[2].kind):toBe("Currency")
		expect(grants[2].amount):toBe(100)
		expect(grants[3].kind):toBe("PowerUpStock")
		expect(grants[3].powerUpId):toBe("freeze")
		expect(grants[3].amount):toBe(1)
	end)

	it("leaves the cap out while its cosmetic is disabled", function()
		local grants = TutorialLogic.rewardGrants(CONFIG, false)
		expect(#grants):toBe(2)
		expect(grants[1].kind):toBe("Currency")
	end)

	it("skips zero amounts and sorts power-ups by id", function()
		local grants = TutorialLogic.rewardGrants({
			rewardCosmeticId = "x",
			rewardCurrency = 0,
			rewardPowerUps = { freeze = 2, blind = 1, ["sprint-boost"] = 0 },
		}, false)
		expect(#grants):toBe(2)
		expect(grants[1].powerUpId):toBe("blind")
		expect(grants[2].powerUpId):toBe("freeze")
		expect(grants[2].amount):toBe(2)
	end)

	it("applies cleanly through StoreLogic.applyGrants", function()
		local after = StoreLogic.applyGrants({
			currency = 5,
			powerUpStock = { freeze = 1 },
			ownedCosmetics = {},
			unlockedTitles = {},
		}, TutorialLogic.rewardGrants(CONFIG, true) :: any)
		expect(after.currency):toBe(105)
		expect(after.powerUpStock.freeze):toBe(2)
		expect(table.find(after.ownedCosmetics, "hat-rookie-cap") ~= nil):toBe(true)
	end)
end)
