--!strict
-- Covers the pure-logic half of the networking layer (P1-3): schema
-- validation, the token-bucket rate limiter, the round-state gate, and
-- escalation. NetGuard.luau itself isn't required here - it touches
-- `game`/Players/RemoteEvent at call time, so it's exercised manually in
-- Studio instead (see ci.yml's comment on this split).

local TestRunner = require("./TestRunner")
local Net = require("../src/shared/Net")

TestRunner.describe("Net.struct", function()
	local PingSchema = Net.struct({
		value = Net.number({ min = 1, max = 100, integer = true }),
	})

	TestRunner.it("accepts a well-formed payload", function()
		local ok, value, err = PingSchema.validate({ value = 42 })
		TestRunner.expect(ok):toBe(true)
		TestRunner.expect(err):toBe(nil)
		TestRunner.expect((value :: any).value):toBe(42)
	end)

	TestRunner.it("rejects a hostile payload with a spoofed extra field", function()
		-- Same well-formed `value` as above, plus an extra field a real
		-- client would never send through the UI - exactly the shape a
		-- compromised client would try to sneak past a looser validator
		-- that only checked the fields it expected, not the fields that
		-- were actually there.
		local ok, value, err = PingSchema.validate({ value = 42, isAdmin = true })
		TestRunner.expect(ok):toBe(false)
		TestRunner.expect(value):toBe(nil)
		TestRunner.expect(err):toBeTruthy()
	end)

	TestRunner.it("rejects a missing required field", function()
		local ok = PingSchema.validate({})
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("rejects an out-of-range value", function()
		local ok = PingSchema.validate({ value = 9001 })
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("rejects the wrong type entirely", function()
		local ok = PingSchema.validate("not a table")
		TestRunner.expect(ok):toBe(false)
	end)
end)

TestRunner.describe("Net.number", function()
	TestRunner.it("rejects non-integers when integer is required", function()
		local ok = Net.number({ integer = true }).validate(1.5)
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("rejects NaN", function()
		local nan = 0 / 0
		local ok = Net.number({}).validate(nan)
		TestRunner.expect(ok):toBe(false)
	end)
end)

TestRunner.describe("Net.string", function()
	TestRunner.it("accepts a well-formed string within the default bounds", function()
		local ok = Net.string().validate("station-01")
		TestRunner.expect(ok):toBe(true)
	end)

	TestRunner.it("rejects the wrong type entirely", function()
		local ok = Net.string().validate(42)
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("rejects a string shorter than minLength", function()
		local ok = Net.string({ minLength = 3 }).validate("ab")
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("rejects a string longer than maxLength - the abuse case an unbounded string would allow", function()
		local ok = Net.string({ maxLength = 8 }).validate(string.rep("x", 5000))
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("defaults maxLength to 64 rather than leaving it unbounded", function()
		local ok = Net.string().validate(string.rep("x", 65))
		TestRunner.expect(ok):toBe(false)
	end)
end)

TestRunner.describe("Net.optional", function()
	local OptionalNumber = Net.optional(Net.number({ min = 1, integer = true }))

	TestRunner.it("accepts a missing field (nil)", function()
		local ok, value = OptionalNumber.validate(nil)
		TestRunner.expect(ok):toBe(true)
		TestRunner.expect(value):toBe(nil)
	end)

	TestRunner.it("accepts a well-formed present value", function()
		local ok, value = OptionalNumber.validate(5)
		TestRunner.expect(ok):toBe(true)
		TestRunner.expect(value):toBe(5)
	end)

	TestRunner.it("still rejects a present but malformed value - optional isn't a bypass", function()
		local ok = OptionalNumber.validate(0.5)
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("composes inside Net.struct as a genuinely optional field", function()
		local Schema = Net.struct({ hint = Net.optional(Net.number({ min = 1 })) })
		local ok1 = Schema.validate({})
		local ok2 = Schema.validate({ hint = 5 })
		local ok3 = Schema.validate({ hint = -1 })
		TestRunner.expect(ok1):toBe(true)
		TestRunner.expect(ok2):toBe(true)
		TestRunner.expect(ok3):toBe(false)
	end)
end)

TestRunner.describe("Net.stringEnum", function()
	local ChoiceSchema = Net.stringEnum({ "Steal", "Share" })

	TestRunner.it("accepts a declared value", function()
		local ok = ChoiceSchema.validate("Steal")
		TestRunner.expect(ok):toBe(true)
	end)

	TestRunner.it("rejects an undeclared value", function()
		local ok = ChoiceSchema.validate("StealAndShare")
		TestRunner.expect(ok):toBe(false)
	end)
end)

TestRunner.describe("Net.tryConsume (token bucket)", function()
	TestRunner.it("allows calls up to capacity then rejects the burst", function()
		local state = Net.newRateLimiterState({ capacity = 3, refillPerSecond = 1 }, 0)

		TestRunner.expect(Net.tryConsume(state, 0)):toBe(true)
		TestRunner.expect(Net.tryConsume(state, 0)):toBe(true)
		TestRunner.expect(Net.tryConsume(state, 0)):toBe(true)
		TestRunner.expect(Net.tryConsume(state, 0)):toBe(false)
	end)

	TestRunner.it("refills over elapsed time", function()
		local state = Net.newRateLimiterState({ capacity = 1, refillPerSecond = 1 }, 0)

		TestRunner.expect(Net.tryConsume(state, 0)):toBe(true)
		TestRunner.expect(Net.tryConsume(state, 0.1)):toBe(false)
		TestRunner.expect(Net.tryConsume(state, 1.1)):toBe(true)
	end)
end)

TestRunner.describe("Net.isStateAllowed", function()
	TestRunner.it("allows any state when the remote declares none", function()
		local allowed = Net.isStateAllowed(
			{ name = "X", direction = "ServerIntent", schema = nil, rateLimit = nil, states = nil },
			"Race"
		)
		TestRunner.expect(allowed):toBe(true)
	end)

	TestRunner.it("allows a declared state", function()
		local def = { name = "X", direction = "ServerIntent", schema = nil, rateLimit = nil, states = { "Race" } }
		TestRunner.expect(Net.isStateAllowed(def, "Race")):toBe(true)
	end)

	TestRunner.it("rejects an undeclared state", function()
		local def = { name = "X", direction = "ServerIntent", schema = nil, rateLimit = nil, states = { "Race" } }
		TestRunner.expect(Net.isStateAllowed(def, "DecisionStudio")):toBe(false)
	end)

	TestRunner.it("fails closed when the current state is unknown", function()
		local def = { name = "X", direction = "ServerIntent", schema = nil, rateLimit = nil, states = { "Race" } }
		TestRunner.expect(Net.isStateAllowed(def, nil)):toBe(false)
	end)
end)

TestRunner.describe("Net.recordViolation", function()
	TestRunner.it("fires exactly once when the count reaches the threshold", function()
		local tracker = Net.newViolationTracker(0)

		TestRunner.expect(Net.recordViolation(tracker, 0, 10, 3)):toBe(false)
		TestRunner.expect(Net.recordViolation(tracker, 0, 10, 3)):toBe(false)
		TestRunner.expect(Net.recordViolation(tracker, 0, 10, 3)):toBe(true)
		TestRunner.expect(Net.recordViolation(tracker, 0, 10, 3)):toBe(false)
	end)

	TestRunner.it("resets the count once the window rolls over", function()
		local tracker = Net.newViolationTracker(0)

		Net.recordViolation(tracker, 0, 10, 3)
		Net.recordViolation(tracker, 0, 10, 3)
		Net.recordViolation(tracker, 20, 10, 3) -- past the window: count resets to 1
		TestRunner.expect(tracker.count):toBe(1)
	end)
end)
