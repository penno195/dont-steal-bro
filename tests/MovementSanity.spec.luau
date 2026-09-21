--!strict
-- Covers MovementSanity.luau (P2-9): the pure threshold/scoring math.
-- MovementWatch.luau itself isn't required here - it touches Players/
-- Humanoids/timers at call time, so it's exercised manually in Studio
-- instead, same split as every other *.spec.luau in this suite.

local TestRunner = require("./TestRunner")
local MovementSanity = require("../src/shared/MovementSanity")

TestRunner.describe("MovementSanity.excessRatio", function()
	TestRunner.it("is 0 exactly at the tolerance cap", function()
		TestRunner.expect(MovementSanity.excessRatio(20, 16, 1.25)):toBeCloseTo(0)
	end)

	TestRunner.it("is negative when comfortably under the cap", function()
		local ratio = MovementSanity.excessRatio(10, 16, 1.25)
		TestRunner.expect(ratio < 0):toBe(true)
	end)

	TestRunner.it("is positive and proportional when over the cap", function()
		-- cap = 20; observed 30 -> (30-20)/20 = 0.5
		TestRunner.expect(MovementSanity.excessRatio(30, 16, 1.25)):toBeCloseTo(0.5)
	end)

	TestRunner.it(
		"treats any movement as maximum severity when the allowed speed is 0 (a ControlLock effect)",
		function()
			local ratio = MovementSanity.excessRatio(5, 0, 1.25)
			TestRunner.expect(ratio > 1):toBeTruthy()
		end
	)

	TestRunner.it("treats zero movement as clean when the allowed speed is 0", function()
		TestRunner.expect(MovementSanity.excessRatio(0, 0, 1.25)):toBe(0)
	end)

	TestRunner.it("clamps an extreme outlier rather than returning an unbounded ratio", function()
		local ratio = MovementSanity.excessRatio(100000, 16, 1.25)
		TestRunner.expect(ratio <= 20):toBeTruthy()
	end)
end)

TestRunner.describe("MovementSanity.applySample - rolling score", function()
	TestRunner.it("accumulates across repeated violations", function()
		local state: MovementSanity.ScoreState = { score = 0, lastSampleAt = 0 }
		state = MovementSanity.applySample(state, 1.0, 1, 0) -- no decay, isolate accumulation
		state = MovementSanity.applySample(state, 1.0, 2, 0)
		TestRunner.expect(state.score):toBeCloseTo(2.0)
	end)

	TestRunner.it("decays over elapsed time between samples", function()
		local state: MovementSanity.ScoreState = { score = 10, lastSampleAt = 0 }
		state = MovementSanity.applySample(state, 0, 5, 1) -- 5s elapsed, decay 1/s, no new violation
		TestRunner.expect(state.score):toBeCloseTo(5)
	end)

	TestRunner.it("never decays below 0", function()
		local state: MovementSanity.ScoreState = { score = 1, lastSampleAt = 0 }
		state = MovementSanity.applySample(state, 0, 100, 1)
		TestRunner.expect(state.score):toBe(0)
	end)

	TestRunner.it("a clean sample never subtracts beyond ordinary decay", function()
		local state: MovementSanity.ScoreState = { score = 5, lastSampleAt = 0 }
		state = MovementSanity.applySample(state, -0.5, 0, 0) -- comfortably clean, zero elapsed (no decay)
		TestRunner.expect(state.score):toBeCloseTo(5)
	end)
end)

TestRunner.describe("MovementSanity.levelFor - separate log/flag/act thresholds", function()
	local LOG, FLAG, ACT = 1.0, 3.0, 6.0

	TestRunner.it("is Clean below the log threshold", function()
		TestRunner.expect(MovementSanity.levelFor(0.5, LOG, FLAG, ACT)):toBe("Clean")
	end)

	TestRunner.it("is Log at and above the log threshold, below flag", function()
		TestRunner.expect(MovementSanity.levelFor(1.0, LOG, FLAG, ACT)):toBe("Log")
		TestRunner.expect(MovementSanity.levelFor(2.9, LOG, FLAG, ACT)):toBe("Log")
	end)

	TestRunner.it("is Flag at and above the flag threshold, below act", function()
		TestRunner.expect(MovementSanity.levelFor(3.0, LOG, FLAG, ACT)):toBe("Flag")
		TestRunner.expect(MovementSanity.levelFor(5.9, LOG, FLAG, ACT)):toBe("Flag")
	end)

	TestRunner.it("is Act at and above the act threshold", function()
		TestRunner.expect(MovementSanity.levelFor(6.0, LOG, FLAG, ACT)):toBe("Act")
		TestRunner.expect(MovementSanity.levelFor(50, LOG, FLAG, ACT)):toBe("Act")
	end)
end)

TestRunner.describe("MovementSanity.horizontalDistance / horizontalSpeed - falling", function()
	TestRunner.it("ignores a purely vertical drop entirely", function()
		local top = { x = 0, y = 50, z = 0 }
		local bottom = { x = 0, y = 0, z = 0 }
		TestRunner.expect(MovementSanity.horizontalDistance(top, bottom)):toBeCloseTo(0)
	end)

	TestRunner.it("a fast fall never reads as a horizontal speed violation", function()
		-- 50 studs straight down in 0.5s (a very fast fall) - horizontal speed is still 0
		local top = { x = 5, y = 50, z = 5 }
		local bottom = { x = 5, y = 0, z = 5 }
		local speed = MovementSanity.horizontalSpeed(top, bottom, 0.5)
		TestRunner.expect(speed):toBeCloseTo(0)
	end)

	TestRunner.it("measures real horizontal movement correctly regardless of vertical change", function()
		local previous = { x = 0, y = 10, z = 0 }
		local current = { x = 8, y = 5, z = 6 } -- horizontal distance = sqrt(8^2+6^2) = 10
		local speed = MovementSanity.horizontalSpeed(previous, current, 0.5)
		TestRunner.expect(speed):toBeCloseTo(20)
	end)

	TestRunner.it("returns 0 for a non-positive elapsed interval rather than dividing by zero", function()
		local a = { x = 0, y = 0, z = 0 }
		local b = { x = 10, y = 0, z = 0 }
		TestRunner.expect(MovementSanity.horizontalSpeed(a, b, 0)):toBe(0)
		TestRunner.expect(MovementSanity.horizontalSpeed(a, b, -1)):toBe(0)
	end)
end)
