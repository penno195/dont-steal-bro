--!strict
-- Covers PowerUpLogic.luau (P2-7): the pure half of the power-up
-- service - cooldowns, inventory-full policy, pool selection, and
-- range/cone targeting. PowerUpService.luau itself isn't required here -
-- it touches Players/CollectionService/remotes at call time, so it's
-- exercised manually in Studio instead, same split as every other
-- *.spec.luau in this suite.

local TestRunner = require("./TestRunner")
local PowerUpLogic = require("../src/shared/PowerUpLogic")

TestRunner.describe("PowerUpLogic.isOnCooldown / cooldownRemaining", function()
	TestRunner.it("is never on cooldown before first use", function()
		TestRunner.expect(PowerUpLogic.isOnCooldown(nil, 20, 100)):toBe(false)
		TestRunner.expect(PowerUpLogic.cooldownRemaining(nil, 20, 100)):toBe(0)
	end)

	TestRunner.it("is on cooldown immediately after use", function()
		TestRunner.expect(PowerUpLogic.isOnCooldown(100, 20, 105)):toBe(true)
		TestRunner.expect(PowerUpLogic.cooldownRemaining(100, 20, 105)):toBe(15)
	end)

	TestRunner.it("clears exactly at the cooldown boundary", function()
		TestRunner.expect(PowerUpLogic.isOnCooldown(100, 20, 120)):toBe(false)
		TestRunner.expect(PowerUpLogic.cooldownRemaining(100, 20, 120)):toBe(0)
	end)

	TestRunner.it("never reports a negative remaining time", function()
		TestRunner.expect(PowerUpLogic.cooldownRemaining(100, 20, 500)):toBe(0)
	end)
end)

TestRunner.describe("PowerUpLogic.slotForPickup", function()
	TestRunner.it("fills slot 1 of an empty inventory", function()
		TestRunner.expect(PowerUpLogic.slotForPickup({}, 3, "Refuse")):toBe(1)
	end)

	TestRunner.it("fills the lowest hole, not the end, after a middle slot is used", function()
		TestRunner.expect(PowerUpLogic.slotForPickup({ [1] = 10, [3] = 30 }, 3, "Refuse")):toBe(2)
	end)

	TestRunner.it("refuses when full under the Refuse policy", function()
		TestRunner.expect(PowerUpLogic.slotForPickup({ 10, 20, 30 }, 3, "Refuse")):toBe(nil)
	end)

	TestRunner.it("evicts the oldest slot when full under the Swap policy", function()
		TestRunner.expect(PowerUpLogic.slotForPickup({ 20, 5, 30 }, 3, "Swap")):toBe(2)
	end)

	TestRunner.it("ignores an entry past maxSlots", function()
		TestRunner.expect(PowerUpLogic.slotForPickup({ [1] = 10, [4] = 1 }, 1, "Refuse")):toBe(nil)
	end)
end)

TestRunner.describe("PowerUpLogic.aimForward", function()
	TestRunner.it("normalizes a ground-plane direction", function()
		local forward = PowerUpLogic.aimForward(3, 4) :: PowerUpLogic.Vec3
		TestRunner.expect(math.abs(forward.x - 0.6) < 1e-9):toBe(true)
		TestRunner.expect(forward.y):toBe(0)
		TestRunner.expect(math.abs(forward.z - 0.8) < 1e-9):toBe(true)
	end)

	TestRunner.it("is nil with no aim, a missing half, or a near-zero vector", function()
		TestRunner.expect(PowerUpLogic.aimForward(nil, nil)):toBe(nil)
		TestRunner.expect(PowerUpLogic.aimForward(1, nil)):toBe(nil)
		TestRunner.expect(PowerUpLogic.aimForward(0, 0.0001)):toBe(nil)
	end)
end)

TestRunner.describe("PowerUpLogic.selectUniform", function()
	TestRunner.it("picks the first element at roll = 0", function()
		TestRunner.expect(PowerUpLogic.selectUniform({ "a", "b", "c" }, 0)):toBe("a")
	end)

	TestRunner.it("picks the last element as roll approaches 1", function()
		TestRunner.expect(PowerUpLogic.selectUniform({ "a", "b", "c" }, 0.9999999)):toBe("c")
	end)

	TestRunner.it("picks the middle element at roll = 0.5", function()
		TestRunner.expect(PowerUpLogic.selectUniform({ "a", "b", "c" }, 0.5)):toBe("b")
	end)

	TestRunner.it("errors on an empty pool rather than returning nil", function()
		local ok = pcall(function()
			PowerUpLogic.selectUniform({}, 0.5)
		end)
		TestRunner.expect(ok):toBe(false)
	end)
end)

TestRunner.describe("PowerUpLogic.isWithinRangeAndCone", function()
	local caster = { x = 0, y = 0, z = 0 }
	local facingPositiveZ = { x = 0, y = 0, z = 1 }

	TestRunner.it("accepts a target directly ahead, in range", function()
		local target = { x = 0, y = 0, z = 10 }
		TestRunner.expect(PowerUpLogic.isWithinRangeAndCone(caster, facingPositiveZ, target, 24, 90)):toBe(true)
	end)

	TestRunner.it("rejects a target beyond range, even directly ahead", function()
		local target = { x = 0, y = 0, z = 30 }
		TestRunner.expect(PowerUpLogic.isWithinRangeAndCone(caster, facingPositiveZ, target, 24, 90)):toBe(false)
	end)

	TestRunner.it("rejects a target within range but behind the caster", function()
		local target = { x = 0, y = 0, z = -10 }
		TestRunner.expect(PowerUpLogic.isWithinRangeAndCone(caster, facingPositiveZ, target, 24, 90)):toBe(false)
	end)

	TestRunner.it("rejects a target within range but outside a narrow cone", function()
		-- 45 degrees off axis; a 30-degree full cone (15-degree half-angle) excludes it
		local target = { x = 10, y = 0, z = 10 }
		TestRunner.expect(PowerUpLogic.isWithinRangeAndCone(caster, facingPositiveZ, target, 24, 30)):toBe(false)
	end)

	TestRunner.it("accepts the same off-axis target under a wide enough cone", function()
		local target = { x = 10, y = 0, z = 10 }
		TestRunner.expect(PowerUpLogic.isWithinRangeAndCone(caster, facingPositiveZ, target, 24, 180)):toBe(true)
	end)
end)

TestRunner.describe("PowerUpLogic.nearestInCone", function()
	local caster = { x = 0, y = 0, z = 0 }
	local facingPositiveZ = { x = 0, y = 0, z = 1 }

	TestRunner.it("returns the nearest of several valid candidates", function()
		local candidates = {
			{ id = 1, position = { x = 0, y = 0, z = 15 } },
			{ id = 2, position = { x = 0, y = 0, z = 5 } },
			{ id = 3, position = { x = 0, y = 0, z = 10 } },
		}
		TestRunner.expect(PowerUpLogic.nearestInCone(caster, facingPositiveZ, candidates, 24, 90)):toBe(2)
	end)

	TestRunner.it("excludes every candidate beyond range, even the nearest of them", function()
		local candidates = {
			{ id = 1, position = { x = 0, y = 0, z = 30 } }, -- nearest of the two, still beyond a range of 24
			{ id = 2, position = { x = 0, y = 0, z = 50 } },
		}
		TestRunner.expect(PowerUpLogic.nearestInCone(caster, facingPositiveZ, candidates, 24, 90)):toBe(nil)
	end)

	TestRunner.it("skips a nearer candidate that's outside the cone", function()
		local candidates = {
			{ id = 1, position = { x = 10, y = 0, z = 1 } }, -- nearest by raw distance, but far outside a narrow cone
			{ id = 2, position = { x = 0, y = 0, z = 8 } },
		}
		TestRunner.expect(PowerUpLogic.nearestInCone(caster, facingPositiveZ, candidates, 24, 30)):toBe(2)
	end)

	TestRunner.it("returns nil when no candidate qualifies", function()
		local candidates = {
			{ id = 1, position = { x = 0, y = 0, z = -10 } }, -- behind
		}
		TestRunner.expect(PowerUpLogic.nearestInCone(caster, facingPositiveZ, candidates, 24, 90)):toBe(nil)
	end)

	TestRunner.it("breaks an exact-distance tie by the lower id, deterministically", function()
		local tiedCandidates = {
			{ id = 5, position = { x = 0, y = 0, z = 10 } },
			{ id = 2, position = { x = 0, y = 0, z = 10 } },
		}
		TestRunner.expect(PowerUpLogic.nearestInCone(caster, facingPositiveZ, tiedCandidates, 24, 90)):toBe(2)
	end)
end)

TestRunner.describe("PowerUpLogic.nearestInRange", function()
	local caster = { x = 0, y = 0, z = 0 }

	TestRunner.it("finds the nearest candidate with no facing requirement at all", function()
		local candidates = {
			{ id = 1, position = { x = 0, y = 0, z = -5 } }, -- behind - still valid, unlike nearestInCone
			{ id = 2, position = { x = 0, y = 0, z = 10 } },
		}
		TestRunner.expect(PowerUpLogic.nearestInRange(caster, candidates, 24)):toBe(1)
	end)

	TestRunner.it("excludes a candidate beyond range", function()
		local candidates = {
			{ id = 1, position = { x = 0, y = 0, z = 100 } },
		}
		TestRunner.expect(PowerUpLogic.nearestInRange(caster, candidates, 24)):toBe(nil)
	end)
end)

TestRunner.describe("PowerUpLogic.isWithinPickupReach (P8-1)", function()
	local pickup = { x = 0, y = 2, z = 0 }

	TestRunner.it("accepts a character standing on the pickup", function()
		TestRunner.expect(PowerUpLogic.isWithinPickupReach({ x = 1, y = 3, z = 1 }, pickup, 10)):toBe(true)
	end)

	TestRunner.it("accepts exactly at the reach boundary", function()
		TestRunner.expect(PowerUpLogic.isWithinPickupReach({ x = 10, y = 2, z = 0 }, pickup, 10)):toBe(true)
	end)

	TestRunner.it("refuses a touch reported from across the map", function()
		TestRunner.expect(PowerUpLogic.isWithinPickupReach({ x = 200, y = 2, z = 40 }, pickup, 10)):toBe(false)
	end)
end)
