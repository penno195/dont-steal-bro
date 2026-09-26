--!strict
-- Covers DoorLogic.luau: the open/close hysteresis and the swing side.
-- DoorService (tags, characters, attributes) and DoorController (the
-- tween) need a live DataModel, so they are verified in Studio.

local TestRunner = require("./TestRunner")
local DoorLogic = require("../src/server/DoorLogic")

local function v(x: number, z: number, y: number?): DoorLogic.Vec3
	return { x = x, y = y or 0, z = z }
end

local DOOR = v(0, 0)
local OPEN, CLOSE = 10, 13

TestRunner.describe("DoorLogic.nextOpen", function()
	TestRunner.it("stays shut with nobody around", function()
		TestRunner.expect(DoorLogic.nextOpen(false, DOOR, {}, OPEN, CLOSE)):toBe(false)
	end)

	TestRunner.it("opens when someone comes within the open radius", function()
		TestRunner.expect(DoorLogic.nextOpen(false, DOOR, { v(30, 0), v(9, 0) }, OPEN, CLOSE)):toBe(true)
	end)

	TestRunner.it("doesn't open for someone between the two radii", function()
		TestRunner.expect(DoorLogic.nextOpen(false, DOOR, { v(12, 0) }, OPEN, CLOSE)):toBe(false)
	end)

	TestRunner.it("stays open while someone is between the two radii (no flapping)", function()
		TestRunner.expect(DoorLogic.nextOpen(true, DOOR, { v(12, 0) }, OPEN, CLOSE)):toBe(true)
	end)

	TestRunner.it("closes once nobody is within the close radius", function()
		TestRunner.expect(DoorLogic.nextOpen(true, DOOR, { v(14, 0) }, OPEN, CLOSE)):toBe(false)
		TestRunner.expect(DoorLogic.nextOpen(true, DOOR, {}, OPEN, CLOSE)):toBe(false)
	end)

	TestRunner.it("ignores height: someone on the floor above counts by ground distance", function()
		TestRunner.expect(DoorLogic.nextOpen(false, DOOR, { v(5, 0, 40) }, OPEN, CLOSE)):toBe(true)
	end)
end)

TestRunner.describe("DoorLogic.swingSide", function()
	local normal = v(0, 1) -- the closed door faces +Z

	TestRunner.it("swings away from an opener on the +normal side", function()
		TestRunner.expect(DoorLogic.swingSide(DOOR, normal, v(1, 5))):toBe(-1)
	end)

	TestRunner.it("swings away from an opener on the -normal side", function()
		TestRunner.expect(DoorLogic.swingSide(DOOR, normal, v(-1, -5))):toBe(1)
	end)

	TestRunner.it("is defined for someone exactly in the door's plane", function()
		TestRunner.expect(DoorLogic.swingSide(DOOR, normal, v(4, 0))):toBe(1)
	end)
end)
