--!strict
-- Covers TaskHandlers/Types.luau's completionDelaySeconds: the
-- plausible-time floor applies to the completing submission only, and
-- holds it until the floor instead of dropping it.

local TestRunner = require("./TestRunner")
local Types = require("../src/server/TaskHandlers/Types")

local expect = TestRunner.expect

TestRunner.describe("TaskHandlers.Types.completionDelaySeconds", function()
	TestRunner.it("holds a too-fast solve until 40% of the expected minimum", function()
		-- fuse-rewire: min 8 s, so the floor is 3.2 s.
		expect(Types.completionDelaySeconds(8, 1)):toBeCloseTo(2.2)
	end)

	TestRunner.it("completes at once once the floor has passed", function()
		expect(Types.completionDelaySeconds(8, 3.2)):toBe(0)
		expect(Types.completionDelaySeconds(8, 10)):toBe(0)
	end)

	TestRunner.it("never delays a task with no definition", function()
		expect(Types.completionDelaySeconds(nil, 0)):toBe(0)
	end)
end)
