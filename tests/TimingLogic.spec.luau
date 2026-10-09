--!strict
-- Covers TimingLogic.luau: the Timing verb's shared sweep maths (Reactor
-- Sync, Airlock Cycle) and the stop-claim clamp the server relies on.

local TestRunner = require("./TestRunner")
local TimingLogic = require("../src/shared/TimingLogic")

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end

TestRunner.describe("TimingLogic.position", function()
	TestRunner.it("rests at 0 until the sweep starts", function()
		TestRunner.expect(TimingLogic.position(0, 0.8, 1)):toBe(0)
		TestRunner.expect(TimingLogic.position(0.8, 0.8, 1)):toBe(0)
	end)

	TestRunner.it("crosses the track in one period, then bounces back", function()
		TestRunner.expect(near(TimingLogic.position(1.5, 1, 1), 0.5)):toBe(true)
		TestRunner.expect(near(TimingLogic.position(2, 1, 1), 1)):toBe(true)
		TestRunner.expect(near(TimingLogic.position(2.25, 1, 1), 0.75)):toBe(true)
		TestRunner.expect(near(TimingLogic.position(3, 1, 1), 0)):toBe(true)
		TestRunner.expect(near(TimingLogic.position(3.5, 1, 1), 0.5)):toBe(true)
	end)

	TestRunner.it("never leaves 0..1", function()
		for i = 0, 400 do
			local pos = TimingLogic.position(i * 0.037, 0.5, 0.7)
			TestRunner.expect(pos >= 0 and pos <= 1):toBe(true)
		end
	end)
end)

TestRunner.describe("TimingLogic.within", function()
	TestRunner.it("includes the band's edges and nothing past them", function()
		TestRunner.expect(TimingLogic.within(0.58, 0.5, 0.08)):toBe(true)
		TestRunner.expect(TimingLogic.within(0.5, 0.5, 0.08)):toBe(true)
		TestRunner.expect(TimingLogic.within(0.59, 0.5, 0.08)):toBe(false)
		TestRunner.expect(TimingLogic.within(0.41, 0.5, 0.08)):toBe(false)
	end)
end)

TestRunner.describe("TimingLogic.clampStop", function()
	TestRunner.it("keeps an honest claim inside the lag window", function()
		TestRunner.expect(TimingLogic.clampStop(4.8, 5, nil)):toBe(4.8)
	end)

	TestRunner.it("never lets a claim be in the future", function()
		TestRunner.expect(TimingLogic.clampStop(9, 5, nil)):toBe(5)
	end)

	TestRunner.it("pulls a stale claim forward to the lag limit", function()
		TestRunner.expect(TimingLogic.clampStop(1, 5, nil)):toBe(5 - TimingLogic.MAX_LAG_SECONDS)
	end)

	TestRunner.it("never goes back to or before the previous stop", function()
		TestRunner.expect(TimingLogic.clampStop(4.7, 5, 4.8)):toBe(5)
		TestRunner.expect(TimingLogic.clampStop(4.9, 5, 4.8)):toBe(4.9)
	end)

	TestRunner.it("drops a stop with no honest time left", function()
		TestRunner.expect(TimingLogic.clampStop(5, 5, 5)):toBe(nil)
	end)
end)
