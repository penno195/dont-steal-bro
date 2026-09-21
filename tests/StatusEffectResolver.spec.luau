--!strict
-- Covers StatusEffectResolver.luau (P2-8): the pure resolver, per-effect
-- stacking rules, and the central hard-control anti-frustration gate.
-- StatusEffects.luau itself isn't required here - it touches Players/
-- Humanoids/remotes at call time, so it's exercised manually in Studio
-- instead, same split as every other *.spec.luau in this suite.

local TestRunner = require("./TestRunner")
local StatusEffectResolver = require("../src/shared/StatusEffectResolver")

local function def(overrides: { [string]: any }): StatusEffectResolver.EffectDef
	local base = {
		id = "test-effect",
		kind = "Debuff",
		stat = "MoveSpeed",
		operation = "Multiply",
		magnitude = 1.0,
		durationSeconds = 5,
		stackingRule = "Refresh",
		stackCap = nil,
		priority = 0,
		category = "Movement",
		hardControlSoftFallbackId = nil,
	}
	for key, value in overrides do
		(base :: any)[key] = value
	end
	return base :: any
end

local function activeEffect(
	instanceId: string,
	effectDef: StatusEffectResolver.EffectDef,
	appliedAt: number,
	casterId: number?
): StatusEffectResolver.ActiveEffect
	return {
		instanceId = instanceId,
		def = effectDef,
		appliedAt = appliedAt,
		expiresAt = appliedAt + effectDef.durationSeconds,
		casterId = casterId,
	}
end

TestRunner.describe("StatusEffectResolver.resolve - overlapping speed buffs and slows", function()
	TestRunner.it("combines a Sprint Boost buff and a Slow Field debuff multiplicatively", function()
		local sprintBoost = def({ id = "sprint-boost", stat = "MoveSpeed", operation = "Multiply", magnitude = 1.35 })
		local slowField = def({ id = "slow-field", stat = "MoveSpeed", operation = "Multiply", magnitude = 0.6 })

		local stats = StatusEffectResolver.resolve({
			activeEffect("a", sprintBoost, 0, nil),
			activeEffect("b", slowField, 0, 5),
		})

		TestRunner.expect(stats.MoveSpeed):toBeCloseTo(1.35 * 0.6)
	end)

	TestRunner.it("clamps combined slows to the -70% floor regardless of how many stack", function()
		local slowField = def({ id = "slow-field", stat = "MoveSpeed", operation = "Multiply", magnitude = 0.6 })

		local stats = StatusEffectResolver.resolve({
			activeEffect("a", slowField, 0, 1),
			activeEffect("b", slowField, 0, 2),
			activeEffect("c", slowField, 0, 3),
			activeEffect("d", slowField, 0, 4),
		})

		-- 0.6^4 = 0.1296, well past the floor - must clamp to 0.3.
		TestRunner.expect(stats.MoveSpeed):toBeCloseTo(0.3)
	end)

	TestRunner.it("an unrelated buff on a different stat doesn't affect MoveSpeed", function()
		local taskInsight = def({ id = "task-insight", stat = "TaskSpeed", operation = "Multiply", magnitude = 1.2 })

		local stats = StatusEffectResolver.resolve({
			activeEffect("a", taskInsight, 0, nil),
		})

		TestRunner.expect(stats.MoveSpeed):toBeCloseTo(1.0)
		TestRunner.expect(stats.TaskSpeed):toBeCloseTo(1.2)
	end)

	TestRunner.it("Override wins over Add/Multiply regardless of which was inserted first, via priority", function()
		-- JumpPower, not MoveSpeed, deliberately - MoveSpeed's own -70%
		-- floor (tested above) would clamp an Override(0) back up to 0.3,
		-- which would make this test about the floor, not about Override
		-- actually winning.
		local reduceJump =
			def({ id = "reduce-jump", stat = "JumpPower", operation = "Multiply", magnitude = 0.5, priority = 0 })
		local lockJump =
			def({ id = "lock-jump", stat = "JumpPower", operation = "Override", magnitude = 0, priority = 10 })

		local stats = StatusEffectResolver.resolve({
			activeEffect("a", lockJump, 0, nil),
			activeEffect("b", reduceJump, 0, nil),
		})

		-- lockJump's higher priority means it resolves LAST, so its Override wins
		TestRunner.expect(stats.JumpPower):toBeCloseTo(0)
	end)
end)

TestRunner.describe("StatusEffectResolver.decideHardControlApplication - immunity window", function()
	TestRunner.it("blocks a freeze landing during the 3s post-effect immunity window", function()
		local history: StatusEffectResolver.HardControlHistory =
			{ lastEndedAt = 100, recentApplications = {}, totalDisabledSeconds = 2.5 }

		local decision = StatusEffectResolver.decideHardControlApplication(history, 101, 2.5)

		TestRunner.expect(decision.allowed):toBe(false)
		TestRunner.expect(decision.effectiveDurationSeconds):toBe(0)
	end)

	TestRunner.it("allows a freeze landing exactly at the immunity window's edge", function()
		local history: StatusEffectResolver.HardControlHistory =
			{ lastEndedAt = 100, recentApplications = {}, totalDisabledSeconds = 2.5 }

		local decision = StatusEffectResolver.decideHardControlApplication(history, 103, 2.5)

		TestRunner.expect(decision.allowed):toBe(true)
	end)

	TestRunner.it("allows a freeze with no prior history at all", function()
		local history: StatusEffectResolver.HardControlHistory =
			{ lastEndedAt = nil, recentApplications = {}, totalDisabledSeconds = 0 }

		local decision = StatusEffectResolver.decideHardControlApplication(history, 0, 2.5)

		TestRunner.expect(decision.allowed):toBe(true)
		TestRunner.expect(decision.effectiveDurationSeconds):toBeCloseTo(2.5)
	end)
end)

TestRunner.describe("StatusEffectResolver.decideHardControlApplication - three freezes in ten seconds", function()
	TestRunner.it("applies diminishing returns: full, then -50%, then -75%", function()
		local history: StatusEffectResolver.HardControlHistory =
			{ lastEndedAt = nil, recentApplications = {}, totalDisabledSeconds = 0 }

		local first = StatusEffectResolver.decideHardControlApplication(history, 0, 2.5)
		TestRunner.expect(first.effectiveDurationSeconds):toBeCloseTo(2.5)

		local second = StatusEffectResolver.decideHardControlApplication(first.updatedHistory, 4, 2.5)
		TestRunner.expect(second.effectiveDurationSeconds):toBeCloseTo(1.25)

		local third = StatusEffectResolver.decideHardControlApplication(second.updatedHistory, 8, 2.5)
		TestRunner.expect(third.effectiveDurationSeconds):toBeCloseTo(0.625)
	end)

	TestRunner.it("never shrinks below the 0.5s floor even for a short base duration", function()
		local history: StatusEffectResolver.HardControlHistory = {
			lastEndedAt = nil,
			recentApplications = { 0, 1 }, -- this would be the 3rd in the window
			totalDisabledSeconds = 2,
		}

		local decision = StatusEffectResolver.decideHardControlApplication(history, 2, 1)

		TestRunner.expect(decision.effectiveDurationSeconds):toBeCloseTo(0.5)
	end)

	TestRunner.it("resets to full strength once the 20s window has fully elapsed", function()
		local history: StatusEffectResolver.HardControlHistory =
			{ lastEndedAt = nil, recentApplications = { 0, 1 }, totalDisabledSeconds = 2 }

		local decision = StatusEffectResolver.decideHardControlApplication(history, 25, 2.5)

		TestRunner.expect(decision.effectiveDurationSeconds):toBeCloseTo(2.5)
	end)
end)

TestRunner.describe("StatusEffectResolver.decideHardControlApplication - rolling per-round cap", function()
	TestRunner.it("downgrades to a soft effect once 15s of disable time has accumulated this round", function()
		local history: StatusEffectResolver.HardControlHistory =
			{ lastEndedAt = nil, recentApplications = {}, totalDisabledSeconds = 15 }

		local decision = StatusEffectResolver.decideHardControlApplication(history, 100, 2.5)

		TestRunner.expect(decision.allowed):toBe(true) -- allowed, but...
		TestRunner.expect(decision.downgradedToSoft):toBe(true)
		TestRunner.expect(decision.effectiveDurationSeconds):toBe(0)
	end)

	TestRunner.it("still applies at full strength just under the cap", function()
		local history: StatusEffectResolver.HardControlHistory =
			{ lastEndedAt = nil, recentApplications = {}, totalDisabledSeconds = 14.9 }

		local decision = StatusEffectResolver.decideHardControlApplication(history, 100, 2.5)

		TestRunner.expect(decision.downgradedToSoft):toBe(false)
		TestRunner.expect(decision.updatedHistory.totalDisabledSeconds):toBeCloseTo(14.9 + 2.5)
	end)
end)

TestRunner.describe(
	"StatusEffectResolver.activeAt - an effect expiring in the same frame as a round transition",
	function()
		TestRunner.it("treats an effect expiring exactly at `now` as already gone", function()
			local freeze = def({ id = "freeze", durationSeconds = 5 })
			local effects = { activeEffect("a", freeze, 0, nil) } -- expiresAt = 5

			TestRunner.expect(#StatusEffectResolver.activeAt(effects, 5)):toBe(0)
		end)

		TestRunner.it("keeps an effect that expires one instant after `now`", function()
			local freeze = def({ id = "freeze", durationSeconds = 5 })
			local effects = { activeEffect("a", freeze, 0, nil) }

			TestRunner.expect(#StatusEffectResolver.activeAt(effects, 4.999)):toBe(1)
		end)

		TestRunner.it(
			"a round transition (now advanced to the transition instant) clears everything that expired by then",
			function()
				local freeze = def({ id = "freeze", durationSeconds = 2 })
				local sprintBoost = def({ id = "sprint-boost", durationSeconds = 10 })
				local effects = {
					activeEffect("a", freeze, 0, nil), -- expires at 2
					activeEffect("b", sprintBoost, 0, nil), -- expires at 10
				}

				local stillActive = StatusEffectResolver.activeAt(effects, 2) -- the round-transition instant
				TestRunner.expect(#stillActive):toBe(1)
				TestRunner.expect(stillActive[1].instanceId):toBe("b")
			end
		)
	end
)

TestRunner.describe("StatusEffectResolver.applyStacking", function()
	TestRunner.it("Refresh replaces the single existing instance of the same id", function()
		local sprintBoost = def({ id = "sprint-boost", stackingRule = "Refresh" })
		local existing = { activeEffect("old", sprintBoost, 0, nil) }
		local newOne = activeEffect("new", sprintBoost, 10, nil)

		local result = StatusEffectResolver.applyStacking(existing, newOne)

		TestRunner.expect(#result):toBe(1)
		TestRunner.expect(result[1].instanceId):toBe("new")
	end)

	TestRunner.it("Ignore does nothing when one is already active", function()
		local freeze = def({ id = "freeze", stackingRule = "Ignore" })
		local existing = { activeEffect("old", freeze, 0, nil) }
		local newOne = activeEffect("new", freeze, 1, nil)

		local result = StatusEffectResolver.applyStacking(existing, newOne)

		TestRunner.expect(#result):toBe(1)
		TestRunner.expect(result[1].instanceId):toBe("old")
	end)

	TestRunner.it("Ignore still applies normally when none is active yet", function()
		local freeze = def({ id = "freeze", stackingRule = "Ignore" })
		local newOne = activeEffect("new", freeze, 0, nil)

		local result = StatusEffectResolver.applyStacking({}, newOne)

		TestRunner.expect(#result):toBe(1)
	end)

	TestRunner.it("StackWithCap allows multiple simultaneous instances up to the cap", function()
		local slowField = def({ id = "slow-field", stackingRule = "StackWithCap", stackCap = 3 })
		local existing = {
			activeEffect("a", slowField, 0, 1),
			activeEffect("b", slowField, 0, 2),
		}
		local newOne = activeEffect("c", slowField, 5, 3)

		local result = StatusEffectResolver.applyStacking(existing, newOne)

		TestRunner.expect(#result):toBe(3)
	end)

	TestRunner.it("StackWithCap evicts the oldest instance once the cap is exceeded", function()
		local slowField = def({ id = "slow-field", stackingRule = "StackWithCap", stackCap = 2 })
		local existing = {
			activeEffect("oldest", slowField, 0, 1),
			activeEffect("middle", slowField, 5, 2),
		}
		local newOne = activeEffect("newest", slowField, 10, 3)

		local result = StatusEffectResolver.applyStacking(existing, newOne)

		TestRunner.expect(#result):toBe(2)
		local ids = {}
		for _, effect in result do
			ids[effect.instanceId] = true
		end
		TestRunner.expect(ids["oldest"]):toBe(nil)
		TestRunner.expect(ids["middle"]):toBe(true)
		TestRunner.expect(ids["newest"]):toBe(true)
	end)

	TestRunner.it("Replace clears every OTHER effect sharing its category, not just its own id", function()
		local freeze = def({ id = "freeze", category = "HardControl", stackingRule = "Replace" })
		local pushTrip = def({ id = "push-trip", category = "HardControl", stackingRule = "Refresh" })
		local sprintBoost = def({ id = "sprint-boost", category = "Movement", stackingRule = "Refresh" })

		local existing = {
			activeEffect("push", pushTrip, 0, nil),
			activeEffect("sprint", sprintBoost, 0, nil),
		}
		local newFreeze = activeEffect("freeze", freeze, 5, nil)

		local result = StatusEffectResolver.applyStacking(existing, newFreeze)

		TestRunner.expect(#result):toBe(2) -- sprint (different category) + the new freeze
		local ids = {}
		for _, effect in result do
			ids[effect.instanceId] = true
		end
		TestRunner.expect(ids["push"]):toBe(nil) -- same category, replaced
		TestRunner.expect(ids["sprint"]):toBe(true)
		TestRunner.expect(ids["freeze"]):toBe(true)
	end)
end)
