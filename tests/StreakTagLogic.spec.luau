--!strict
-- Covers StreakTagLogic.luau: where the Hub streak counter may exist
-- (design-decisions.md Q7 condition 1) and which racers get one.
-- StreakTagService itself touches Players and remotes, so it's exercised
-- in Studio.

local TestRunner = require("./TestRunner")
local StreakTagLogic = require("../src/server/StreakTagLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

describe("StreakTagLogic.isHub", function()
	it("is the hub only on the hub place", function()
		expect(StreakTagLogic.isHub(111, 111, false, false)):toBe(true)
		expect(StreakTagLogic.isHub(222, 111, false, true)):toBe(false)
	end)

	it("never counts a live server as the hub while the hub id is unset", function()
		expect(StreakTagLogic.isHub(222, 0, false, true)):toBe(false)
		expect(StreakTagLogic.isHub(0, 0, true, false)):toBe(false)
		expect(StreakTagLogic.isHub(0, 0, true, true)):toBe(true)
	end)
end)

describe("StreakTagLogic.tags", function()
	it("tags live streaks only, keeping the flair", function()
		local out = StreakTagLogic.tags({
			{ racerId = 1, streak = 0, flairId = "flair-wildfire" },
			{ racerId = 2, streak = 7, flairId = "flair-wildfire" },
			{ racerId = 3, streak = 1 },
			{ racerId = 4, streak = 2.5 },
		})
		expect(#out):toBe(2)
		expect(out[1].racerId):toBe(2)
		expect(out[1].flairId):toBe("flair-wildfire")
		expect(out[2].racerId):toBe(3)
		expect(out[2].flairId):toBe(nil)
	end)
end)
