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

describe("TutorialLogic.levelUpXp", function()
	it("pays a fresh account the whole first level", function()
		expect(TutorialLogic.levelUpXp({ xpIntoLevel = 0, xpForNext = 100 })):toBe(100)
	end)

	it("pays only what's left of a part-filled level", function()
		expect(TutorialLogic.levelUpXp({ xpIntoLevel = 70, xpForNext = 125 })):toBe(55)
	end)

	it("pays nothing at the level cap", function()
		expect(TutorialLogic.levelUpXp({ xpIntoLevel = 0, xpForNext = 0 })):toBe(0)
	end)
end)

describe("TutorialLogic.botMayFinish", function()
	it("lets two bots finish ahead of one unfinished player, not a third", function()
		expect(TutorialLogic.botMayFinish(0, 1, 3)):toBe(true)
		expect(TutorialLogic.botMayFinish(1, 1, 3)):toBe(true)
		expect(TutorialLogic.botMayFinish(2, 1, 3)):toBe(false)
	end)

	it("frees the bots once the player is done or gone", function()
		expect(TutorialLogic.botMayFinish(2, 0, 3)):toBe(true)
		expect(TutorialLogic.botMayFinish(5, 0, 3)):toBe(true)
	end)
end)

describe("TutorialLogic.easyProfile", function()
	it("slows a profile without touching the original", function()
		local profile = { id = "Sweaty", weight = 0.2, durationScale = 0.9, moveSpeedScale = 1.0 }
		local easy = TutorialLogic.easyProfile(profile, 1.5, 0.8)
		expect(easy.id):toBe("Sweaty")
		expect(math.abs(easy.durationScale - 1.35) < 1e-9):toBe(true)
		expect(math.abs(easy.moveSpeedScale - 0.8) < 1e-9):toBe(true)
		expect(profile.durationScale):toBe(0.9)
	end)
end)

describe("TutorialLogic.practicePickupId", function()
	local ids = { "push-trip", "blind", "task-scramble" }
	local function all(_id: string): boolean
		return true
	end

	it("spreads the roll over the list, ends included", function()
		expect(TutorialLogic.practicePickupId(ids, all, 0)):toBe("push-trip")
		expect(TutorialLogic.practicePickupId(ids, all, 0.5)):toBe("blind")
		expect(TutorialLogic.practicePickupId(ids, all, 0.999)):toBe("task-scramble")
	end)

	it("skips switched-off items, and is nil when none is left", function()
		local function noBlind(id: string): boolean
			return id ~= "blind"
		end
		expect(TutorialLogic.practicePickupId(ids, noBlind, 0.6)):toBe("task-scramble")
		expect(TutorialLogic.practicePickupId(ids, function()
			return false
		end, 0.5)):toBe(nil)
	end)
end)

describe("TutorialLogic.inHubTutorial", function()
	it("is only a loaded player who hasn't seen it, with the tutorial on", function()
		expect(TutorialLogic.inHubTutorial(true, true, false)):toBe(true)
		expect(TutorialLogic.inHubTutorial(true, true, true)):toBe(false)
		expect(TutorialLogic.inHubTutorial(true, false, false)):toBe(false)
		expect(TutorialLogic.inHubTutorial(false, true, false)):toBe(false)
	end)
end)
