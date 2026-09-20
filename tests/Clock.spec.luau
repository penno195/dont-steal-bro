--!strict
-- Covers Clock.luau (P2-2): the pure half of the countdown helper -
-- secondsRemaining and both formatters. Clock.now() and Clock.subscribe()
-- aren't required here - they touch workspace/RunService at call time, so
-- they're exercised manually in Studio instead, same split as every other
-- *.spec.luau in this suite (see testing-conventions.md).

local TestRunner = require("./TestRunner")
local Clock = require("../src/shared/Clock")

TestRunner.describe("Clock.secondsRemaining", function()
	TestRunner.it("returns a positive value before the deadline", function()
		TestRunner.expect(Clock.secondsRemaining(100, 60)):toBe(40)
	end)

	TestRunner.it("returns exactly 0 at the deadline", function()
		TestRunner.expect(Clock.secondsRemaining(100, 100)):toBe(0)
	end)

	TestRunner.it("returns a negative value past the deadline - a late joiner or an already-elapsed timer", function()
		TestRunner.expect(Clock.secondsRemaining(100, 140)):toBe(-40)
	end)
end)

TestRunner.describe("Clock.formatMMSS", function()
	TestRunner.it("formats a sub-minute value", function()
		TestRunner.expect(Clock.formatMMSS(45)):toBe("0:45")
	end)

	TestRunner.it("formats a multi-minute value", function()
		TestRunner.expect(Clock.formatMMSS(125)):toBe("2:05")
	end)

	TestRunner.it("rounds to the nearest second rather than flooring", function()
		TestRunner.expect(Clock.formatMMSS(59.6)):toBe("1:00")
	end)

	TestRunner.it("clamps a past deadline to 00:00, never negative", function()
		TestRunner.expect(Clock.formatMMSS(-40)):toBe("0:00")
	end)

	TestRunner.it("clamps exactly-zero to 00:00", function()
		TestRunner.expect(Clock.formatMMSS(0)):toBe("0:00")
	end)
end)

TestRunner.describe("Clock.formatFinalCountdown", function()
	TestRunner.it("shows the ceiling of seconds remaining inside the default 3s window", function()
		TestRunner.expect(Clock.formatFinalCountdown(2.4)):toBe("3")
	end)

	TestRunner.it("shows 1 for a fraction of a second left", function()
		TestRunner.expect(Clock.formatFinalCountdown(0.2)):toBe("1")
	end)

	TestRunner.it("returns nil outside the window (still further out than the threshold)", function()
		TestRunner.expect(Clock.formatFinalCountdown(3.1)):toBe(nil)
	end)

	TestRunner.it("returns nil at exactly zero - a past deadline has nothing left to count down", function()
		TestRunner.expect(Clock.formatFinalCountdown(0)):toBe(nil)
	end)

	TestRunner.it("returns nil past the deadline", function()
		TestRunner.expect(Clock.formatFinalCountdown(-5)):toBe(nil)
	end)

	TestRunner.it("respects a custom threshold", function()
		TestRunner.expect(Clock.formatFinalCountdown(4.5, 5)):toBe("5")
		TestRunner.expect(Clock.formatFinalCountdown(5.5, 5)):toBe(nil)
	end)
end)
