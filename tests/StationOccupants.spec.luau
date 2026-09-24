--!strict
-- The Occupants attribute's wire format (P7-6).

local StationOccupants = require("../src/shared/StationOccupants")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

describe("StationOccupants.encode", function()
	it("encodes nobody as nil, so the attribute is removed", function()
		expect(StationOccupants.encode({})):toBe(nil)
	end)

	it("sorts, so the same set always writes the same string", function()
		expect(StationOccupants.encode({ 418823, -2, 7 })):toBe("-2,7,418823")
	end)

	it("doesn't reorder the caller's list", function()
		local ids = { 3, 1 }
		StationOccupants.encode(ids)
		expect(ids[1]):toBe(3)
	end)
end)

describe("StationOccupants.decode", function()
	it("round-trips an encoded set", function()
		local ids = StationOccupants.decode(StationOccupants.encode({ 5, -1 }))
		expect(#ids):toBe(2)
		expect(ids[1]):toBe(-1)
		expect(ids[2]):toBe(5)
	end)

	it("reads a missing or mistyped attribute as nobody", function()
		expect(#StationOccupants.decode(nil)):toBe(0)
		expect(#StationOccupants.decode(12)):toBe(0)
		expect(#StationOccupants.decode("")):toBe(0)
	end)

	it("skips junk tokens", function()
		expect(#StationOccupants.decode("4,x,,9")):toBe(2)
	end)
end)

describe("StationOccupants.split", function()
	it("tells your own attempt apart from rivals'", function()
		local mine, others = StationOccupants.split("-3,10,99", 10)
		expect(mine):toBe(true)
		expect(others):toBe(2)
	end)

	it("counts an NPC as a rival", function()
		local mine, others = StationOccupants.split("-3", 10)
		expect(mine):toBe(false)
		expect(others):toBe(1)
	end)

	it("is empty with no attribute", function()
		local mine, others = StationOccupants.split(nil, 10)
		expect(mine):toBe(false)
		expect(others):toBe(0)
	end)
end)
