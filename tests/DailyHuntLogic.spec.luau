--!strict
-- Covers DailyHuntLogic.luau: today's spot, once-a-day claiming and the
-- 50/50 reward (design-decisions.md Q1, "the daily hunt").
-- DailyHuntService itself touches tags, characters and remotes, so it's
-- exercised in Studio.

local TestRunner = require("./TestRunner")
local DailyHuntLogic = require("../src/server/DailyHuntLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function rolls(values: { number }): () -> number
	local i = 0
	return function(): number
		i += 1
		return values[i]
	end
end

local CONFIG = { powerUpChance = 0.5, coins = 25 }

describe("DailyHuntLogic.spotIndex", function()
	it("is the same for the same player and day, and within range", function()
		local a = DailyHuntLogic.spotIndex(12345, "2026-10-10", 7)
		expect(a):toBe(DailyHuntLogic.spotIndex(12345, "2026-10-10", 7))
		expect(a ~= nil and a >= 1 and a <= 7):toBeTruthy()
	end)

	it("has no spot when the hub has none", function()
		expect(DailyHuntLogic.spotIndex(12345, "2026-10-10", 0)):toBe(nil)
	end)

	it("spreads players and days over the spots", function()
		local seen: { [number]: boolean } = {}
		for userId = 1, 60 do
			seen[DailyHuntLogic.spotIndex(userId, "2026-10-10", 6) :: number] = true
		end
		local byDay: { [number]: boolean } = {}
		for day = 1, 28 do
			byDay[DailyHuntLogic.spotIndex(42, string.format("2026-10-%02d", day), 6) :: number] = true
		end
		for i = 1, 6 do
			expect(seen[i]):toBe(true)
			expect(byDay[i]):toBe(true)
		end
	end)

	it("stays exact on long input", function()
		local h = DailyHuntLogic.hash(string.rep("9", 500))
		expect(h >= 0 and h < 2147483647 and h % 1 == 0):toBeTruthy()
	end)
end)

describe("DailyHuntLogic.spotOrder", function()
	it("sorts by name, then position, without moving the spots", function()
		local spots = {
			{ name = "Hub.B", x = 0, y = 0, z = 0 },
			{ name = "Hub.A", x = 5, y = 0, z = 0 },
			{ name = "Hub.A", x = 1, y = 0, z = 0 },
		}
		local order = DailyHuntLogic.spotOrder(spots)
		expect(order[1]):toBe(3)
		expect(order[2]):toBe(2)
		expect(order[3]):toBe(1)
		expect(spots[1].name):toBe("Hub.B")
	end)
end)

describe("DailyHuntLogic.isOpen", function()
	it("is open once per UTC day", function()
		expect(DailyHuntLogic.isOpen(nil, "2026-10-10")):toBe(true)
		expect(DailyHuntLogic.isOpen("2026-10-09", "2026-10-10")):toBe(true)
		expect(DailyHuntLogic.isOpen("2026-10-10", "2026-10-10")):toBe(false)
	end)
end)

describe("DailyHuntLogic.rollReward", function()
	it("pays one power-up under the chance", function()
		local grant = DailyHuntLogic.rollReward(CONFIG, { "freeze", "blind" }, rolls({ 0.2, 0.9 }))
		expect(grant.kind):toBe("PowerUpStock")
		expect(grant.amount):toBe(1)
		expect(grant.powerUpId):toBe("blind")
	end)

	it("pays coins at or over the chance", function()
		local grant = DailyHuntLogic.rollReward(CONFIG, { "freeze" }, rolls({ 0.5 }))
		expect(grant.kind):toBe("Currency")
		expect(grant.amount):toBe(25)
	end)

	it("pays coins when no power-up may be given", function()
		local grant = DailyHuntLogic.rollReward(CONFIG, {}, rolls({ 0 }))
		expect(grant.kind):toBe("Currency")
	end)
end)
