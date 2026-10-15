--!strict
-- Covers PrizeRevealLogic.luau: the tutorial reward reveal's spin
-- timeline - ticks that slow down and grow louder, with the reveal on
-- the beat after the last one, where the riser stops.

local TestRunner = require("./TestRunner")
local PrizeRevealLogic = require("../src/client/UI/PrizeRevealLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

describe("PrizeRevealLogic.ticks", function()
	it("starts at 0 and leaves the reveal one gap after the last tick", function()
		local ticks = PrizeRevealLogic.ticks()
		expect(#ticks):toBe(20)
		expect(ticks[1].at):toBe(0)
		local last = ticks[#ticks].at
		assert(last < PrizeRevealLogic.SPIN, "the last tick must come before the reveal")
		-- The final gap is the widest, so the reveal lands a slow beat late.
		local before = ticks[#ticks - 1].at
		assert(PrizeRevealLogic.SPIN - last > last - before, "the reveal beat should be the longest gap")
	end)

	it("slows down: every gap is wider than the one before", function()
		local ticks = PrizeRevealLogic.ticks()
		for i = 3, #ticks do
			assert(ticks[i].at - ticks[i - 1].at > ticks[i - 1].at - ticks[i - 2].at, "gap " .. i .. " didn't grow")
		end
	end)

	it("gets louder from QUIET to LOUD", function()
		local ticks = PrizeRevealLogic.ticks()
		expect(ticks[1].volume):toBe(PrizeRevealLogic.QUIET)
		expect(ticks[#ticks].volume):toBe(PrizeRevealLogic.LOUD)
		for i = 2, #ticks do
			assert(ticks[i].volume > ticks[i - 1].volume, "tick " .. i .. " didn't get louder")
		end
	end)

	it("fits any spin length and count", function()
		local ticks = PrizeRevealLogic.ticks(2, 5)
		expect(#ticks):toBe(5)
		assert(ticks[5].at < 2, "last tick past the reveal")
	end)
end)
