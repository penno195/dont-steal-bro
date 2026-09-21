--!strict
-- Covers Qualification.luau (P2-4): the pure ranking/tie-break function.
-- TaskService.luau itself isn't required here - it touches Players/
-- workspace/remotes at call time, so it's exercised manually in Studio
-- instead, same split as every other *.spec.luau in this suite.

local TestRunner = require("./TestRunner")
local Qualification = require("../src/shared/Qualification")

local QUALIFIER_COUNT = 3
local MIN_COMPLETION_RATE = 0.5

local function entry(
	playerId: number,
	tasksCompleted: number,
	tasksAssigned: number,
	lastCompletionTime: number?,
	distanceToNextStation: number?
): Qualification.PlayerProgress
	return {
		playerId = playerId,
		tasksAssigned = tasksAssigned,
		tasksCompleted = tasksCompleted,
		lastCompletionTime = lastCompletionTime,
		distanceToNextStation = distanceToNextStation,
	}
end

TestRunner.describe("Qualification.rank - fewer than three finishers", function()
	TestRunner.it("qualifies only the players who meet the completion floor, and no more", function()
		local result = Qualification.rank({
			entry(1, 6, 6, 100, nil), -- finished, 100%
			entry(2, 2, 6, 40, 5), -- 33%, below the 0.5 floor
			entry(3, 1, 6, 20, 8), -- 17%, below the floor
		}, QUALIFIER_COUNT, MIN_COMPLETION_RATE)

		TestRunner.expect(#result.qualifiers):toBe(1)
		TestRunner.expect(result.qualifiers[1]):toBe(1)
		TestRunner.expect(result.alternate):toBe(nil)
	end)

	TestRunner.it("still ranks everyone, even players who never qualify", function()
		local result = Qualification.rank({
			entry(1, 6, 6, 100, nil),
			entry(2, 0, 6, nil, 50),
		}, QUALIFIER_COUNT, MIN_COMPLETION_RATE)

		TestRunner.expect(#result.ranked):toBe(2)
		TestRunner.expect(result.ranked[2].playerId):toBe(2)
		TestRunner.expect(result.ranked[2].qualifies):toBe(false)
	end)

	TestRunner.it("offers no alternate when nobody past the qualifiers meets the floor", function()
		local result = Qualification.rank({
			entry(1, 6, 6, 100, nil),
			entry(2, 6, 6, 200, nil),
			entry(3, 2, 6, 50, 10), -- below the floor
		}, QUALIFIER_COUNT, MIN_COMPLETION_RATE)

		TestRunner.expect(#result.qualifiers):toBe(2)
		TestRunner.expect(result.alternate):toBe(nil)
	end)
end)

TestRunner.describe("Qualification.rank - exact ties on task count", function()
	TestRunner.it("breaks a tie by the earlier last-completion timestamp", function()
		local result = Qualification.rank({
			entry(1, 4, 6, 200, 10),
			entry(2, 4, 6, 100, 10), -- same task count, completed their 4th earlier
		}, QUALIFIER_COUNT, MIN_COMPLETION_RATE)

		TestRunner.expect(result.ranked[1].playerId):toBe(2)
		TestRunner.expect(result.ranked[2].playerId):toBe(1)
		TestRunner.expect(result.ranked[2].decidedBy):toBe("lastCompletionTime")
	end)

	TestRunner.it("falls through to distance-to-next-station when task count AND last-completion tie", function()
		local result = Qualification.rank({
			entry(1, 4, 6, 100, 30),
			entry(2, 4, 6, 100, 5), -- same count, same timestamp, closer to their next station
		}, QUALIFIER_COUNT, MIN_COMPLETION_RATE)

		TestRunner.expect(result.ranked[1].playerId):toBe(2)
		TestRunner.expect(result.ranked[2].decidedBy):toBe("distanceToNextStation")
	end)

	TestRunner.it("falls through to playerId as the final deterministic tie-break", function()
		local result = Qualification.rank({
			entry(5, 4, 6, 100, 10),
			entry(2, 4, 6, 100, 10), -- identical on every named criterion
		}, QUALIFIER_COUNT, MIN_COMPLETION_RATE)

		TestRunner.expect(result.ranked[1].playerId):toBe(2)
		TestRunner.expect(result.ranked[2].decidedBy):toBe("playerId")
	end)

	TestRunner.it("rank 1 is always decided by 'onlyEntry' - nothing ranks above it", function()
		local result = Qualification.rank({
			entry(1, 6, 6, 100, nil),
			entry(2, 3, 6, 50, 10),
		}, QUALIFIER_COUNT, MIN_COMPLETION_RATE)

		TestRunner.expect(result.ranked[1].decidedBy):toBe("onlyEntry")
	end)
end)

TestRunner.describe("Qualification.rank - a leaver (fewer entries than the usual player count)", function()
	TestRunner.it("ranks correctly with only 5 entries, no assumption of a fixed 6", function()
		local result = Qualification.rank({
			entry(1, 6, 6, 100, nil),
			entry(2, 6, 6, 150, nil),
			entry(3, 5, 6, 140, 4),
			entry(4, 4, 6, 130, 6),
			entry(5, 3, 6, 120, 8),
		}, QUALIFIER_COUNT, MIN_COMPLETION_RATE)

		TestRunner.expect(#result.ranked):toBe(5)
		TestRunner.expect(#result.qualifiers):toBe(3)
		TestRunner.expect(result.qualifiers[1]):toBe(1)
		TestRunner.expect(result.qualifiers[2]):toBe(2)
		TestRunner.expect(result.qualifiers[3]):toBe(3)
		TestRunner.expect(result.alternate):toBe(4)
	end)
end)

TestRunner.describe("Qualification.rank - all six finishing inside the timer", function()
	TestRunner.it("qualifies the first three finishers in order and names the fourth as the alternate", function()
		local result = Qualification.rank({
			entry(1, 6, 6, 400, nil),
			entry(2, 6, 6, 100, nil), -- finished first
			entry(3, 6, 6, 200, nil),
			entry(4, 6, 6, 300, nil),
			entry(5, 6, 6, 500, nil),
			entry(6, 6, 6, 600, nil), -- finished last
		}, QUALIFIER_COUNT, MIN_COMPLETION_RATE)

		TestRunner.expect(#result.ranked):toBe(6)
		TestRunner.expect(result.qualifiers[1]):toBe(2)
		TestRunner.expect(result.qualifiers[2]):toBe(3)
		TestRunner.expect(result.qualifiers[3]):toBe(4)
		TestRunner.expect(result.alternate):toBe(1)
		TestRunner.expect(result.ranked[6].playerId):toBe(6)
	end)
end)
