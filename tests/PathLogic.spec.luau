--!strict
-- Covers PathLogic.luau: where a point sits against a route, and a
-- route's length. Navigation uses both, on the server to tell when a
-- player has left their line and on the client to drop the part run.

local TestRunner = require("./TestRunner")
local PathLogic = require("../src/shared/PathLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function p(x: number, z: number): PathLogic.Point
	return { x = x, y = 0, z = z }
end

describe("PathLogic.closest", function()
	local from = p(0, 0)
	local route = { p(10, 0), p(10, 10) }

	it("finds the segment and how far along it", function()
		local c = PathLogic.closest(p(4, 2), from, route)
		expect(c.segment):toBe(1)
		expect(c.t):toBe(0.4)
		expect(c.distance):toBe(2)
	end)

	it("picks the later segment once the player is past the corner", function()
		local c = PathLogic.closest(p(12, 6), from, route)
		expect(c.segment):toBe(2)
		expect(c.distance):toBe(2)
	end)

	it("clamps to the ends", function()
		expect(PathLogic.closest(p(-3, 0), from, route).distance):toBe(3)
	end)
end)

describe("PathLogic.length", function()
	it("adds up every leg from the start", function()
		expect(PathLogic.length(p(0, 0), { p(3, 4), p(3, 10) })):toBe(11)
	end)

	it("is zero for an empty route", function()
		expect(PathLogic.length(p(0, 0), {})):toBe(0)
	end)
end)
