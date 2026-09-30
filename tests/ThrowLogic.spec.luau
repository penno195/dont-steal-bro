--!strict
-- Covers ThrowLogic.luau: which items are thrown, flight time, the lob,
-- and the direction and size of the shunt and recoil. The projectile
-- and the shove themselves touch parts, so they're exercised in Studio.

local TestRunner = require("./TestRunner")
local ThrowLogic = require("../src/shared/ThrowLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local config = {
	projectileSpeedStuds = 90,
	maxFlightSeconds = 0.4,
	arcHeightStuds = 2.5,
	shuntSpeed = 28,
	shuntUpSpeed = 12,
	recoilSpeed = 10,
}
local origin = { x = 0, y = 0, z = 0 }
local east = { x = 18, y = 0, z = 0 }
local forward = { x = 0, y = 0, z = -1 }

describe("ThrowLogic.isThrown", function()
	it("throws only racer-targeted items", function()
		expect(ThrowLogic.isThrown("Aimed")):toBe(true)
		expect(ThrowLogic.isThrown("Nearest")):toBe(true)
		expect(ThrowLogic.isThrown("Self")):toBe(false)
		expect(ThrowLogic.isThrown("Area")):toBe(false)
	end)
end)

describe("ThrowLogic.flightSeconds", function()
	it("is distance over speed", function()
		expect(ThrowLogic.flightSeconds(origin, east, config)):toBeCloseTo(0.2)
	end)

	it("is capped for a long throw", function()
		expect(ThrowLogic.flightSeconds(origin, { x = 900, y = 0, z = 0 }, config)):toBe(0.4)
	end)

	it("is instant point-blank", function()
		expect(ThrowLogic.flightSeconds(origin, origin, config)):toBe(0)
	end)
end)

describe("ThrowLogic.shuntVelocity", function()
	it("shoves the victim away from the thrower, with a pop", function()
		local v = ThrowLogic.shuntVelocity(origin, east, forward, config, nil)
		expect(v.x):toBeCloseTo(28)
		expect(v.y):toBeCloseTo(12)
		expect(v.z):toBeCloseTo(0)
	end)

	it("ignores height difference for direction", function()
		local v = ThrowLogic.shuntVelocity(origin, { x = 0, y = 10, z = 5 }, forward, config, nil)
		expect(v.x):toBeCloseTo(0)
		expect(v.z):toBeCloseTo(28)
	end)

	it("scales by the item's shuntScale", function()
		local v = ThrowLogic.shuntVelocity(origin, east, forward, config, 2.5)
		expect(v.x):toBeCloseTo(70)
		expect(v.y):toBeCloseTo(30)
	end)

	it("falls back to the throw direction when on top of each other", function()
		local v = ThrowLogic.shuntVelocity(origin, origin, forward, config, nil)
		expect(v.x):toBeCloseTo(0)
		expect(v.z):toBeCloseTo(-28)
	end)
end)

describe("ThrowLogic.recoilVelocity", function()
	it("pushes the thrower straight back, flat", function()
		local v = ThrowLogic.recoilVelocity(origin, east, forward, config)
		expect(v.x):toBeCloseTo(-10)
		expect(v.y):toBe(0)
		expect(v.z):toBeCloseTo(0)
	end)
end)

describe("ThrowLogic.arcPoint", function()
	it("starts and ends on the endpoints and peaks halfway", function()
		local a = ThrowLogic.arcPoint(origin, east, 0, 2.5)
		expect(a.x):toBe(0)
		expect(a.y):toBe(0)
		local b = ThrowLogic.arcPoint(origin, east, 1, 2.5)
		expect(b.x):toBe(18)
		expect(b.y):toBe(0)
		local mid = ThrowLogic.arcPoint(origin, east, 0.5, 2.5)
		expect(mid.x):toBeCloseTo(9)
		expect(mid.y):toBeCloseTo(2.5)
	end)

	it("clamps alpha", function()
		expect(ThrowLogic.arcPoint(origin, east, 2, 2.5).x):toBe(18)
	end)
end)

describe("ThrowLogic.fitSize", function()
	it("scales the longest side to the target, keeping proportions", function()
		local s = ThrowLogic.fitSize({ x = 4, y = 2, z = 1 }, 1.1)
		expect(s.x):toBeCloseTo(1.1)
		expect(s.y):toBeCloseTo(0.55)
		expect(s.z):toBeCloseTo(0.275)
	end)

	it("grows a tiny mesh up to the target too", function()
		expect(ThrowLogic.fitSize({ x = 0.1, y = 0.2, z = 0.1 }, 1.1).y):toBeCloseTo(1.1)
	end)

	it("falls back to a cube for a degenerate mesh", function()
		for _, native in { { x = 0, y = 0, z = 0 }, { x = 0 / 0, y = 0 / 0, z = 0 / 0 } } do
			local s = ThrowLogic.fitSize(native, 1.1)
			expect(s.x):toBe(1.1)
			expect(s.y):toBe(1.1)
			expect(s.z):toBe(1.1)
		end
	end)
end)
