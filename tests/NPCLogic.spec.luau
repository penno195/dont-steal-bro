--!strict
-- Covers NPCLogic.luau (P3-5): fill count, skill draws, the fairness
-- floor, the nav-graph search, and name generation. NPCService.luau
-- itself isn't required here - it touches PathfindingService, Instances
-- and a real clock, so it's exercised manually in Studio instead (see
-- docs/npc-notes.md's checklist), the same split every other spec in
-- this suite uses.
--
-- The cases that matter most are the fairness ones: "an NPC never beats
-- the median human time for a task" is a claim about the leaderboard's
-- credibility (threat-model.md §8), so it's asserted directly rather
-- than inferred from the config's numbers looking about right.

local TestRunner = require("./TestRunner")
local NPCLogic = require("../src/server/NPCLogic")

local CASUAL: NPCLogic.SkillProfile = { id = "Casual", weight = 0.3, durationScale = 1.35, moveSpeedScale = 0.9 }
local AVERAGE: NPCLogic.SkillProfile = { id = "Average", weight = 0.5, durationScale = 1.1, moveSpeedScale = 1.0 }
local SWEATY: NPCLogic.SkillProfile = { id = "Sweaty", weight = 0.2, durationScale = 0.9, moveSpeedScale = 1.05 }
local PROFILES = { CASUAL, AVERAGE, SWEATY }

TestRunner.describe("NPCLogic.deriveFillCount", function()
	TestRunner.it("fills every empty seat", function()
		TestRunner.expect(NPCLogic.deriveFillCount(0, 6)):toBe(6)
		TestRunner.expect(NPCLogic.deriveFillCount(2, 6)):toBe(4)
		TestRunner.expect(NPCLogic.deriveFillCount(5, 6)):toBe(1)
	end)

	TestRunner.it("spawns nothing for a full server", function()
		TestRunner.expect(NPCLogic.deriveFillCount(6, 6)):toBe(0)
	end)

	TestRunner.it("never returns a negative count, even with more humans than seats", function()
		-- A real possibility on a server that was over-filled by a
		-- matchmaking race, and the one case that would otherwise turn
		-- into a negative loop bound in the caller.
		TestRunner.expect(NPCLogic.deriveFillCount(9, 6)):toBe(0)
	end)
end)

TestRunner.describe("NPCLogic.pickSkillProfile", function()
	TestRunner.it("maps a roll to the profile whose cumulative weight covers it", function()
		-- Weights 0.3 / 0.5 / 0.2 over a total of 1.0.
		TestRunner.expect(NPCLogic.pickSkillProfile(PROFILES, 0).id):toBe("Casual")
		TestRunner.expect(NPCLogic.pickSkillProfile(PROFILES, 0.29).id):toBe("Casual")
		TestRunner.expect(NPCLogic.pickSkillProfile(PROFILES, 0.31).id):toBe("Average")
		TestRunner.expect(NPCLogic.pickSkillProfile(PROFILES, 0.79).id):toBe("Average")
		TestRunner.expect(NPCLogic.pickSkillProfile(PROFILES, 0.81).id):toBe("Sweaty")
	end)

	TestRunner.it("handles a roll at the very top of the range without falling off the end", function()
		TestRunner.expect(NPCLogic.pickSkillProfile(PROFILES, 0.9999999).id):toBe("Sweaty")
	end)

	TestRunner.it("does not require the weights to sum to 1", function()
		local unnormalized = {
			{ id = "A", weight = 30, durationScale = 1, moveSpeedScale = 1 },
			{ id = "B", weight = 70, durationScale = 1, moveSpeedScale = 1 },
		}
		TestRunner.expect(NPCLogic.pickSkillProfile(unnormalized, 0.2).id):toBe("A")
		TestRunner.expect(NPCLogic.pickSkillProfile(unnormalized, 0.5).id):toBe("B")
	end)
end)

TestRunner.describe("NPCLogic.median", function()
	TestRunner.it("returns the middle value of an odd-length list", function()
		TestRunner.expect(NPCLogic.median({ 5, 1, 3 })):toBe(3)
	end)

	TestRunner.it("averages the two middle values of an even-length list", function()
		TestRunner.expect(NPCLogic.median({ 4, 1, 3, 2 })):toBe(2.5)
	end)

	TestRunner.it("returns nil - not zero - for no samples", function()
		-- A fabricated 0 here would read as "humans finish instantly"
		-- to the fairness floor and wipe out the guarantee entirely.
		TestRunner.expect(NPCLogic.median({})):toBe(nil)
	end)

	TestRunner.it("does not sort the caller's own list in place", function()
		local samples = { 9, 2, 5 }
		NPCLogic.median(samples)
		TestRunner.expect(samples[1]):toBe(9)
	end)
end)

TestRunner.describe("NPCLogic.fairnessFloorSeconds", function()
	local expected = { min = 10, max = 20 }

	TestRunner.it("falls back to the catalogue range's midpoint before any human has finished", function()
		TestRunner.expect(NPCLogic.fairnessFloorSeconds(expected, nil, 1, 1)):toBe(15)
	end)

	TestRunner.it("prefers a real observed median once one exists", function()
		TestRunner.expect(NPCLogic.fairnessFloorSeconds(expected, 12, 1, 1)):toBe(12)
	end)

	TestRunner.it("scales with the map's difficulty modifier", function()
		TestRunner.expect(NPCLogic.fairnessFloorSeconds(expected, 12, 1.5, 1)):toBe(18)
	end)

	TestRunner.it("scales with the floor scale, so bots can be made softer without touching profiles", function()
		TestRunner.expect(NPCLogic.fairnessFloorSeconds(expected, 12, 1, 1.25)):toBe(15)
	end)
end)

TestRunner.describe("NPCLogic.sampleWorkSeconds - the fairness guarantee", function()
	local expected = { min = 10, max = 20 }

	local function sample(profile: NPCLogic.SkillProfile, roll: number, observedMedian: number?)
		return NPCLogic.sampleWorkSeconds({
			expected = expected,
			profile = profile,
			mapDifficultyModifier = 1,
			observedMedianSeconds = observedMedian,
			floorScale = 1,
			roll = roll,
		})
	end

	TestRunner.it("never returns a time faster than the observed human median, at ANY roll", function()
		-- The whole claim, swept rather than spot-checked: the fastest
		-- profile, across the entire roll range, against a median far
		-- below its own scaled range.
		for step = 0, 100 do
			local result = sample(SWEATY, step / 100, 14)
			assert(
				result.seconds >= 14,
				string.format("roll %.2f produced %.3fs, which beats the 14s human median", step / 100, result.seconds)
			)
		end
	end)

	TestRunner.it("reports which floor bound a sample, so an always-floored profile is visible", function()
		local floored = sample(SWEATY, 0, 14) -- 10 * 0.9 = 9s raw, floored to 14
		TestRunner.expect(floored.seconds):toBe(14)
		TestRunner.expect(floored.flooredBy):toBe(14)
	end)

	TestRunner.it("leaves a sample alone when it was already slower than the floor", function()
		local unfloored = sample(CASUAL, 0.99, 12) -- ~20 * 1.35 = ~27s, well clear
		TestRunner.expect(unfloored.flooredBy):toBe(nil)
		assert(unfloored.seconds > 26, "expected a slow casual sample to stay slow")
	end)

	TestRunner.it("still floors before any human has finished, using the catalogue midpoint", function()
		-- The gap that matters: a bot must not be free to run away with
		-- the race during the opening seconds, when no human has
		-- completed anything yet and there is no observed median.
		local result = sample(SWEATY, 0, nil)
		TestRunner.expect(result.seconds):toBe(15)
	end)

	TestRunner.it("a weaker profile is genuinely slower than a stronger one on the same roll", function()
		local casual = sample(CASUAL, 0.9, nil)
		local sweaty = sample(SWEATY, 0.9, nil)
		assert(casual.seconds > sweaty.seconds, "expected Casual to be slower than Sweaty on an identical roll")
	end)
end)

TestRunner.describe("NPCLogic.chooseNextStation", function()
	local candidates = {
		{ stationId = "far", distance = 90 },
		{ stationId = "near", distance = 10 },
		{ stationId = "mid", distance = 40 },
	}

	TestRunner.it("picks among the k nearest, never the far one at k=2", function()
		TestRunner.expect(NPCLogic.chooseNextStation(candidates, 0, 2)):toBe("near")
		TestRunner.expect(NPCLogic.chooseNextStation(candidates, 0.9, 2)):toBe("mid")
	end)

	TestRunner.it("always takes the nearest at k=1", function()
		TestRunner.expect(NPCLogic.chooseNextStation(candidates, 0.9, 1)):toBe("near")
	end)

	TestRunner.it("clamps k to the number of candidates", function()
		TestRunner.expect(NPCLogic.chooseNextStation({ { stationId = "only", distance = 5 } }, 0.99, 4)):toBe("only")
	end)

	TestRunner.it("breaks distance ties by station id, so the result never depends on input order", function()
		local tied = {
			{ stationId = "b", distance = 10 },
			{ stationId = "a", distance = 10 },
		}
		TestRunner.expect(NPCLogic.chooseNextStation(tied, 0, 1)):toBe("a")
	end)

	TestRunner.it("returns nil when there is nothing left to do", function()
		TestRunner.expect(NPCLogic.chooseNextStation({}, 0.5, 2)):toBe(nil)
	end)
end)

TestRunner.describe("NPCLogic.findNodePath", function()
	--  a - b - c
	--  |       |
	--  d ----- e        (f is deliberately orphaned)
	local graph: NPCLogic.NavGraph = {
		a = { "b", "d" },
		b = { "a", "c" },
		c = { "b", "e" },
		d = { "a", "e" },
		e = { "c", "d" },
		f = {},
	}

	TestRunner.it("finds the fewest-hop route, not just any route", function()
		local route = NPCLogic.findNodePath(graph, "a", "e")
		TestRunner.expect(route ~= nil):toBe(true)
		TestRunner.expect(#(route :: { string })):toBe(3) -- a -> d -> e, not a -> b -> c -> e
		TestRunner.expect((route :: { string })[2]):toBe("d")
	end)

	TestRunner.it("includes both endpoints", function()
		local route = NPCLogic.findNodePath(graph, "a", "b") :: { string }
		TestRunner.expect(route[1]):toBe("a")
		TestRunner.expect(route[2]):toBe("b")
	end)

	TestRunner.it("returns the single node when start and finish are the same", function()
		local route = NPCLogic.findNodePath(graph, "c", "c") :: { string }
		TestRunner.expect(#route):toBe(1)
		TestRunner.expect(route[1]):toBe("c")
	end)

	TestRunner.it("returns nil for an unreachable node - map-kit-spec.md's disconnected graph", function()
		TestRunner.expect(NPCLogic.findNodePath(graph, "a", "f")):toBe(nil)
	end)

	TestRunner.it("returns nil for a node id that isn't in the graph at all", function()
		TestRunner.expect(NPCLogic.findNodePath(graph, "a", "nope")):toBe(nil)
	end)

	TestRunner.it("ignores an edge pointing at a node that doesn't exist", function()
		-- A real possibility: ConnectedNodeIds is a hand-typed attribute
		-- on a hand-built map, so a typo'd edge is a builder error this
		-- must survive rather than throw on.
		local typo: NPCLogic.NavGraph = { a = { "b", "typpo" }, b = { "a" } }
		local route = NPCLogic.findNodePath(typo, "a", "b") :: { string }
		TestRunner.expect(#route):toBe(2)
	end)
end)

TestRunner.describe("NPCLogic.generateDisplayName", function()
	local function neverTaken(_name: string): boolean
		return false
	end

	TestRunner.it("produces a name no Roblox username could ever equal", function()
		local rng = NPCLogic.newRng(1234)
		for _ = 1, 50 do
			local name = NPCLogic.generateDisplayName(rng, neverTaken)
			assert(
				NPCLogic.isUsernameCollisionProof(name),
				string.format("%q contains only username-legal characters", name)
			)
		end
	end)

	TestRunner.it("avoids a name that's already in use", function()
		local rng = NPCLogic.newRng(7)
		local first = NPCLogic.generateDisplayName(rng, neverTaken)

		local secondRng = NPCLogic.newRng(7)
		local second = NPCLogic.generateDisplayName(secondRng, function(name: string): boolean
			return name == first
		end)

		assert(second ~= first, "expected the taken name to be rejected and redrawn")
		TestRunner.expect(NPCLogic.isUsernameCollisionProof(second)):toBe(true)
	end)

	TestRunner.it("gives up safely rather than looping forever when everything is taken", function()
		local rng = NPCLogic.newRng(99)
		local name = NPCLogic.generateDisplayName(rng, function(_name: string): boolean
			return true
		end)
		-- Still collision-proof on the giving-up path, which is the
		-- property that actually matters here.
		TestRunner.expect(NPCLogic.isUsernameCollisionProof(name)):toBe(true)
	end)

	TestRunner.it("is reproducible from a seed", function()
		local a = NPCLogic.generateDisplayName(NPCLogic.newRng(42), neverTaken)
		local b = NPCLogic.generateDisplayName(NPCLogic.newRng(42), neverTaken)
		TestRunner.expect(a):toBe(b)
	end)
end)

TestRunner.describe("NPCLogic.earnsStreakCredit", function()
	TestRunner.it("credits a round at or below the threshold", function()
		TestRunner.expect(NPCLogic.earnsStreakCredit(0, 3)):toBe(true)
		TestRunner.expect(NPCLogic.earnsStreakCredit(3, 3)):toBe(true)
	end)

	TestRunner.it("refuses credit above it - threat-model.md §8's 'more than N seats'", function()
		TestRunner.expect(NPCLogic.earnsStreakCredit(4, 3)):toBe(false)
		TestRunner.expect(NPCLogic.earnsStreakCredit(5, 3)):toBe(false)
	end)

	TestRunner.it("supports a zero threshold - no bots at all, or no credit", function()
		TestRunner.expect(NPCLogic.earnsStreakCredit(0, 0)):toBe(true)
		TestRunner.expect(NPCLogic.earnsStreakCredit(1, 0)):toBe(false)
	end)
end)

TestRunner.describe("NPCLogic.newRng", function()
	TestRunner.it("is deterministic for a given seed", function()
		local a, b = NPCLogic.newRng(5), NPCLogic.newRng(5)
		for _ = 1, 10 do
			TestRunner.expect(a()):toBe(b())
		end
	end)

	TestRunner.it("stays inside [0, 1)", function()
		local rng = NPCLogic.newRng(11)
		for _ = 1, 500 do
			local value = rng()
			assert(value >= 0 and value < 1, string.format("%f is outside [0, 1)", value))
		end
	end)

	TestRunner.it("gives different streams to different NPC ids", function()
		-- How NPCService actually seeds each bot: round seed + id * 7919.
		local first = NPCLogic.newRng(1000 + -1 * 7919)
		local second = NPCLogic.newRng(1000 + -2 * 7919)
		assert(first() ~= second(), "expected two NPCs to draw independently")
	end)
end)
