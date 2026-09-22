--!strict
-- Covers NPCBrainLogic.luau (P3-6): the utility score that decides when
-- a bot fires a power-up, and the Decision Studio's personality roll,
-- lock-in timing and line selection. NPCBrain.luau itself isn't
-- required here - it touches Instances, remotes and a real clock, so
-- it's exercised manually in Studio (docs/npc-notes.md's checklist),
-- the same split every other spec in this suite uses.
--
-- The two cases worth reading first are the ones that encode real
-- guarantees rather than arithmetic: a bot never locks in at or after
-- the Choose deadline, and a personality's steal rate actually matches
-- the probability on its config.

local TestRunner = require("./TestRunner")
local NPCBrainLogic = require("../src/server/NPCBrainLogic")
local NPCLogic = require("../src/server/NPCLogic")

local WEIGHTS: NPCBrainLogic.UtilityWeights = {
	baseScore = 0.3,
	deficitWeight = 0.35,
	proximityWeight = 0.5,
	travelWeight = 0.4,
	deficitSaturation = 3,
	travelSaturationStuds = 80,
	useThreshold = 0.6,
}

local function situation(overrides: { [string]: any }): NPCBrainLogic.Situation
	local base: { [string]: any } = {
		kind = "Debuff",
		onCooldown = false,
		progressDeficit = 0,
		distanceToNextStationStuds = nil,
		nearestAheadDistanceStuds = nil,
		useRangeStuds = 24,
	}
	for key, value in overrides do
		base[key] = value
	end
	return base :: any
end

local function personality(stealProbability: number): NPCBrainLogic.Personality
	return {
		id = "test",
		displayName = "Test",
		stealProbability = stealProbability,
		weight = 1,
		lines = {
			promises = { "p1", "p2" },
			pressure = { "x1", "x2" },
			accusations = { "a1", "a2" },
			wobbles = { "w1", "w2" },
		},
	}
end

TestRunner.describe("NPCBrainLogic.scoreAction - cooldown is a hard gate", function()
	TestRunner.it("scores zero for an item on cooldown, however good the situation is", function()
		-- Not a low score - zero. A bot that wants something the
		-- validator would reject just wastes its decision tick.
		local score = NPCBrainLogic.scoreAction(
			situation({ onCooldown = true, progressDeficit = 5, nearestAheadDistanceStuds = 1 }),
			WEIGHTS
		)
		TestRunner.expect(score):toBe(0)
	end)
end)

TestRunner.describe("NPCBrainLogic.scoreAction - offensive items", function()
	TestRunner.it("scores zero with nobody ahead to hit", function()
		TestRunner.expect(NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = nil }), WEIGHTS)):toBe(0)
	end)

	TestRunner.it("scores zero for a target beyond the server's own use range", function()
		-- Measured against the same range the validator enforces, so the
		-- brain can never want a use that would be rejected for range.
		local score =
			NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = 30, useRangeStuds = 24 }), WEIGHTS)
		TestRunner.expect(score):toBe(0)
	end)

	TestRunner.it("scores a close target above a distant one", function()
		local close = NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = 2 }), WEIGHTS)
		local far = NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = 22 }), WEIGHTS)
		assert(close > far, string.format("expected a close target to score higher (%f vs %f)", close, far))
	end)

	TestRunner.it("scores higher the further behind the bot is", function()
		local level =
			NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = 12, progressDeficit = 0 }), WEIGHTS)
		local behind =
			NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = 12, progressDeficit = 3 }), WEIGHTS)
		assert(behind > level, "expected a bot that's behind to be less patient")
	end)

	TestRunner.it("saturates the deficit component rather than growing without bound", function()
		local atSaturation =
			NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = 12, progressDeficit = 3 }), WEIGHTS)
		local farBeyond =
			NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = 12, progressDeficit = 50 }), WEIGHTS)
		TestRunner.expect(farBeyond):toBeCloseTo(atSaturation)
	end)

	TestRunner.it("holds rather than fires when nothing about the situation is urgent", function()
		-- A target at the very edge of range, bot not behind: legal, but
		-- not worth the item. baseScore alone must not clear the bar.
		local score =
			NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = 24, progressDeficit = 0 }), WEIGHTS)
		TestRunner.expect(NPCBrainLogic.shouldUse(score, WEIGHTS)):toBe(false)
	end)

	TestRunner.it("fires on a close target while behind", function()
		local score =
			NPCBrainLogic.scoreAction(situation({ nearestAheadDistanceStuds = 4, progressDeficit = 2 }), WEIGHTS)
		TestRunner.expect(NPCBrainLogic.shouldUse(score, WEIGHTS)):toBe(true)
	end)
end)

TestRunner.describe("NPCBrainLogic.scoreAction - self buffs", function()
	TestRunner.it("scores zero with nowhere left to walk", function()
		-- A finished bot burning a Sprint Boost for nothing is the exact
		-- waste this guard exists for.
		local score = NPCBrainLogic.scoreAction(situation({ kind = "Buff", distanceToNextStationStuds = nil }), WEIGHTS)
		TestRunner.expect(score):toBe(0)
	end)

	TestRunner.it("scores a long leg above a short one", function()
		local long = NPCBrainLogic.scoreAction(situation({ kind = "Buff", distanceToNextStationStuds = 80 }), WEIGHTS)
		local short = NPCBrainLogic.scoreAction(situation({ kind = "Buff", distanceToNextStationStuds = 5 }), WEIGHTS)
		assert(long > short, "expected a buff to be worth more at the start of a long walk")
	end)

	TestRunner.it("ignores a nearby opponent entirely - a buff isn't aimed at anyone", function()
		local alone = NPCBrainLogic.scoreAction(situation({ kind = "Buff", distanceToNextStationStuds = 40 }), WEIGHTS)
		local crowded = NPCBrainLogic.scoreAction(
			situation({ kind = "Buff", distanceToNextStationStuds = 40, nearestAheadDistanceStuds = 1 }),
			WEIGHTS
		)
		TestRunner.expect(crowded):toBeCloseTo(alone)
	end)

	TestRunner.it("fires on a long leg while behind", function()
		local score = NPCBrainLogic.scoreAction(
			situation({ kind = "Buff", distanceToNextStationStuds = 90, progressDeficit = 2 }),
			WEIGHTS
		)
		TestRunner.expect(NPCBrainLogic.shouldUse(score, WEIGHTS)):toBe(true)
	end)
end)

TestRunner.describe("NPCBrainLogic.pickPersonality", function()
	local pool = {
		personality(0.7),
		personality(0.2),
		personality(0.5),
	}
	pool[1].id, pool[2].id, pool[3].id = "greedy", "loyal", "chaotic"

	TestRunner.it("maps a roll to the personality whose weight covers it", function()
		TestRunner.expect(NPCBrainLogic.pickPersonality(pool, 0).id):toBe("greedy")
		TestRunner.expect(NPCBrainLogic.pickPersonality(pool, 0.5).id):toBe("loyal")
		TestRunner.expect(NPCBrainLogic.pickPersonality(pool, 0.9).id):toBe("chaotic")
	end)

	TestRunner.it("handles the very top of the range", function()
		TestRunner.expect(NPCBrainLogic.pickPersonality(pool, 0.9999999).id):toBe("chaotic")
	end)
end)

TestRunner.describe("NPCBrainLogic.rollChoice", function()
	TestRunner.it("steals below the probability and shares at or above it", function()
		local greedy = personality(0.7)
		TestRunner.expect(NPCBrainLogic.rollChoice(greedy, 0.69)):toBe("Steal")
		TestRunner.expect(NPCBrainLogic.rollChoice(greedy, 0.7)):toBe("Share")
	end)

	TestRunner.it("produces a steal rate matching the configured probability over many rolls", function()
		-- The claim architecture.md §4 actually makes ("Greedy {steal
		-- 0.7}"), checked against a real stream rather than assumed from
		-- the comparison above.
		local greedy = personality(0.7)
		local rng = NPCLogic.newRng(4242)
		local steals = 0
		local trials = 4000
		for _ = 1, trials do
			if NPCBrainLogic.rollChoice(greedy, rng()) == "Steal" then
				steals += 1
			end
		end
		TestRunner.expect(steals / trials):toBeCloseTo(0.7, 0.03)
	end)

	TestRunner.it("a loyal bot still betrays sometimes - it's a probability, not a rule", function()
		local loyal = personality(0.2)
		local rng = NPCLogic.newRng(99)
		local steals = 0
		for _ = 1, 1000 do
			if NPCBrainLogic.rollChoice(loyal, rng()) == "Steal" then
				steals += 1
			end
		end
		assert(steals > 0, "expected a Loyal bot to steal at least once in 1000 rounds")
		assert(steals < 400, "expected a Loyal bot to mostly share")
	end)
end)

TestRunner.describe("NPCBrainLogic.lockInOffsetSeconds", function()
	TestRunner.it("never lands at or after the deadline, at any roll", function()
		-- The guarantee that matters: a lock-in racing the phase timer
		-- is a coin flip between the bot's own choice and the configured
		-- default, decided by scheduler ordering.
		for step = 0, 100 do
			local offset = NPCBrainLogic.lockInOffsetSeconds(15, step / 100, 0.25, 0.8)
			assert(offset < 15, string.format("roll %.2f produced %.3fs in a 15s window", step / 100, offset))
		end
	end)

	TestRunner.it("never lands before the earliest fraction either", function()
		for step = 0, 100 do
			local offset = NPCBrainLogic.lockInOffsetSeconds(15, step / 100, 0.25, 0.8)
			assert(
				offset >= 15 * 0.25 - 1e-9,
				string.format("roll %.2f locked in too early (%.3fs)", step / 100, offset)
			)
		end
	end)

	TestRunner.it("spreads across the window rather than clustering", function()
		local early = NPCBrainLogic.lockInOffsetSeconds(15, 0, 0.25, 0.8)
		local late = NPCBrainLogic.lockInOffsetSeconds(15, 0.99, 0.25, 0.8)
		assert(late - early > 5, "expected a real spread of lock-in times across the window")
	end)

	TestRunner.it("survives a zero-length window without producing a negative offset", function()
		TestRunner.expect(NPCBrainLogic.lockInOffsetSeconds(0, 0.5, 0.25, 0.8)):toBe(0)
	end)
end)

TestRunner.describe("NPCBrainLogic.lineScheduleSeconds", function()
	TestRunner.it("schedules the requested number of lines inside the window", function()
		local schedule = NPCBrainLogic.lineScheduleSeconds(45, 3, 6, NPCLogic.newRng(1))
		TestRunner.expect(#schedule):toBe(3)
		for _, at in schedule do
			assert(at >= 0 and at < 45, string.format("%.2fs is outside the 45s window", at))
		end
	end)

	TestRunner.it("keeps every pair of lines at least the minimum gap apart", function()
		for seed = 1, 25 do
			local schedule = NPCBrainLogic.lineScheduleSeconds(45, 3, 6, NPCLogic.newRng(seed))
			for index = 2, #schedule do
				local gap = schedule[index] - schedule[index - 1]
				assert(gap >= 6 - 1e-9, string.format("seed %d produced a %.2fs gap", seed, gap))
			end
		end
	end)

	TestRunner.it("drops lines rather than cramming them into a short window", function()
		-- Two things said at a believable pace beat three on top of each
		-- other.
		local schedule = NPCBrainLogic.lineScheduleSeconds(10, 5, 6, NPCLogic.newRng(3))
		assert(#schedule < 5, "expected a short window to fit fewer lines")
	end)

	TestRunner.it("leaves the end of the window quiet", function()
		local schedule = NPCBrainLogic.lineScheduleSeconds(45, 3, 6, NPCLogic.newRng(7))
		for _, at in schedule do
			assert(at <= 45 * 0.85 + 1e-9, string.format("%.2fs lands in the quiet tail", at))
		end
	end)

	TestRunner.it("returns nothing for zero lines or a zero window", function()
		TestRunner.expect(#NPCBrainLogic.lineScheduleSeconds(45, 0, 6, NPCLogic.newRng(1))):toBe(0)
		TestRunner.expect(#NPCBrainLogic.lineScheduleSeconds(0, 3, 6, NPCLogic.newRng(1))):toBe(0)
	end)
end)

TestRunner.describe("NPCBrainLogic.categoryForProgress", function()
	TestRunner.it("escalates promises -> pressure -> accusations -> wobbles", function()
		TestRunner.expect(NPCBrainLogic.categoryForProgress(0)):toBe("promises")
		TestRunner.expect(NPCBrainLogic.categoryForProgress(0.5)):toBe("pressure")
		TestRunner.expect(NPCBrainLogic.categoryForProgress(0.7)):toBe("accusations")
		TestRunner.expect(NPCBrainLogic.categoryForProgress(0.95)):toBe("wobbles")
	end)

	TestRunner.it("clamps a progress value outside 0-1", function()
		TestRunner.expect(NPCBrainLogic.categoryForProgress(-2)):toBe("promises")
		TestRunner.expect(NPCBrainLogic.categoryForProgress(4)):toBe("wobbles")
	end)
end)

TestRunner.describe("NPCBrainLogic.selectLine", function()
	TestRunner.it("draws from the category the progress selects", function()
		local line = NPCBrainLogic.selectLine(personality(0.5), 0, 0, {})
		TestRunner.expect(line):toBe("p1")
	end)

	TestRunner.it("avoids repeating a line already said this window", function()
		-- A bot repeating itself inside one 45-second window is the most
		-- obvious possible tell that it isn't a person.
		local line = NPCBrainLogic.selectLine(personality(0.5), 0, 0, { p1 = true })
		TestRunner.expect(line):toBe("p2")
	end)

	TestRunner.it("falls back to the full pool once every line in it has been used", function()
		local line = NPCBrainLogic.selectLine(personality(0.5), 0, 0, { p1 = true, p2 = true })
		TestRunner.expect(line):toBe("p1")
	end)

	TestRunner.it("returns nil for a personality missing that category entirely", function()
		local broken = personality(0.5);
		(broken.lines :: any).wobbles = {}
		TestRunner.expect(NPCBrainLogic.selectLine(broken, 1, 0, {})):toBe(nil)
	end)
end)
