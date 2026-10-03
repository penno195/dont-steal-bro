--!strict
-- Covers TaskAssignment.luau (P2-4): the pure per-round station
-- assignment function. TaskService.luau itself isn't required here - see
-- Qualification.spec.luau's header comment for why.

local TestRunner = require("./TestRunner")
local TaskAssignment = require("../src/shared/TaskAssignment")

local function stationPool(count: number): { TaskAssignment.StationInfo }
	local stations = {}
	for i = 1, count do
		table.insert(
			stations,
			{ stationId = string.format("station-%02d", i), acceptedTaskIds = { "pressure-valve", "vent-purge" } }
		)
	end
	return stations
end

-- 12 stations, 6 players x 6 tasks each = 36 demand. Capacity 4 (supply
-- 48) gives the random dealing order real headroom above the bare
-- theoretical minimum (ceil(36/12) = 3) - see TaskAssignment.assign's
-- own doc comment for why capacity needs slack, not just to exactly
-- cover demand, for a non-backtracking greedy to reliably succeed.
local CAPACITY_WITH_HEADROOM = 4

TestRunner.describe("TaskAssignment.assign - determinism", function()
	TestRunner.it("the same seed produces the exact same assignment", function()
		local a = TaskAssignment.assign(42, stationPool(12), { 1, 2, 3, 4, 5, 6 }, 6, CAPACITY_WITH_HEADROOM)
		local b = TaskAssignment.assign(42, stationPool(12), { 1, 2, 3, 4, 5, 6 }, 6, CAPACITY_WITH_HEADROOM)

		for _, playerId in { 1, 2, 3, 4, 5, 6 } do
			TestRunner.expect(#a[playerId]):toBe(#b[playerId])
			for index, assignment in a[playerId] do
				TestRunner.expect(assignment.stationId):toBe(b[playerId][index].stationId)
				TestRunner.expect(assignment.taskId):toBe(b[playerId][index].taskId)
			end
		end
	end)

	TestRunner.it("a different seed can produce a different assignment", function()
		local a = TaskAssignment.assign(1, stationPool(12), { 1, 2, 3, 4, 5, 6 }, 6, CAPACITY_WITH_HEADROOM)
		local b = TaskAssignment.assign(2, stationPool(12), { 1, 2, 3, 4, 5, 6 }, 6, CAPACITY_WITH_HEADROOM)

		local identical = true
		for index, assignment in a[1] do
			if assignment.stationId ~= b[1][index].stationId then
				identical = false
			end
		end
		TestRunner.expect(identical):toBe(false)
	end)
end)

TestRunner.describe("TaskAssignment.assign - shape", function()
	TestRunner.it("gives every player exactly tasksPerPlayer distinct stations", function()
		local result = TaskAssignment.assign(7, stationPool(12), { 1, 2, 3, 4, 5, 6 }, 6, CAPACITY_WITH_HEADROOM)
		for _, playerId in { 1, 2, 3, 4, 5, 6 } do
			local assignments = result[playerId]
			TestRunner.expect(#assignments):toBe(6)

			local seen: { [string]: boolean } = {}
			for _, assignment in assignments do
				TestRunner.expect(seen[assignment.stationId]):toBe(nil)
				seen[assignment.stationId] = true
			end
		end
	end)

	TestRunner.it("respects per-station capacity - no station goes to more players than capacityPerStation", function()
		-- 4 stations, 6 players x 2 tasks each = 12 demand; capacity 4
		-- (supply 16) leaves the same kind of headroom as above.
		local result = TaskAssignment.assign(11, stationPool(4), { 1, 2, 3, 4, 5, 6 }, 2, 4)
		local usageCount: { [string]: number } = {}
		for _, playerId in { 1, 2, 3, 4, 5, 6 } do
			for _, assignment in result[playerId] do
				usageCount[assignment.stationId] = (usageCount[assignment.stationId] or 0) + 1
			end
		end
		for _, count in usageCount do
			TestRunner.expect(count <= 4):toBe(true)
		end
	end)

	TestRunner.it("avoids giving every player an identical route, across a real-sized pool", function()
		local result = TaskAssignment.assign(99, stationPool(12), { 1, 2, 3, 4, 5, 6 }, 6, CAPACITY_WITH_HEADROOM)
		local routeKey = function(playerId: number): string
			local ids = {}
			for _, assignment in result[playerId] do
				table.insert(ids, assignment.stationId)
			end
			return table.concat(ids, ",")
		end

		local allIdentical = true
		local first = routeKey(1)
		for _, playerId in { 2, 3, 4, 5, 6 } do
			if routeKey(playerId) ~= first then
				allIdentical = false
			end
		end
		TestRunner.expect(allIdentical):toBe(false)
	end)
end)

TestRunner.describe("TaskAssignment.assign - infeasible input fails loudly", function()
	TestRunner.it("errors rather than silently under-assigning when capacity can't cover every player", function()
		local ok = pcall(function()
			TaskAssignment.assign(1, stationPool(2), { 1, 2, 3, 4, 5, 6 }, 6, 1)
		end)
		TestRunner.expect(ok):toBe(false)
	end)
end)

-- The SpaceStation shape: 16 stations, each offering 2 of 3 tasks.
local function overlappingPool(): { TaskAssignment.StationInfo }
	local pairs_ = {
		{ "code-playback", "pressure-valve" },
		{ "pressure-valve", "fuse-rewire" },
		{ "fuse-rewire", "code-playback" },
		{ "vent-purge", "pressure-valve" },
	}
	local stations = {}
	for i = 1, 16 do
		table.insert(stations, { stationId = string.format("s-%02d", i), acceptedTaskIds = pairs_[(i % 4) + 1] })
	end
	return stations
end

TestRunner.describe("TaskAssignment.assign - task variety", function()
	TestRunner.it("never repeats a task until every task on offer has been dealt, then spreads repeats", function()
		for seed = 1, 50 do
			local result = TaskAssignment.assign(seed, overlappingPool(), { 1, 2, 3, 4, 5, 6 }, 6, 4)
			for _, route in result do
				local counts: { [string]: number } = {}
				for index, assignment in route do
					counts[assignment.taskId] = (counts[assignment.taskId] or 0) + 1
					if index <= 4 then
						-- 4 distinct tasks exist, so the first 4 picks are all different.
						TestRunner.expect(counts[assignment.taskId]):toBe(1)
					end
				end
				for _, count in counts do
					TestRunner.expect(count <= 2):toBe(true)
				end
			end
		end
	end)
end)

TestRunner.describe("TaskAssignment.assign - rare tasks", function()
	TestRunner.it("deals a task offered on one shared station before that station is used up", function()
		-- "rare" lives only on the station that also offers "common". Dealing
		-- "common" there first strands "rare" and forces a repeat.
		local stations: { TaskAssignment.StationInfo } = {
			{ stationId = "shared", acceptedTaskIds = { "common", "rare" } },
			{ stationId = "common-1", acceptedTaskIds = { "common" } },
			{ stationId = "common-2", acceptedTaskIds = { "common" } },
			{ stationId = "other", acceptedTaskIds = { "other" } },
		}
		for seed = 1, 100 do
			local route = TaskAssignment.assign(seed, stations, { 1 }, 3, 1)[1]
			local seen: { [string]: boolean } = {}
			for _, assignment in route do
				TestRunner.expect(seen[assignment.taskId] == nil):toBe(true)
				seen[assignment.taskId] = true
			end
			TestRunner.expect(seen.rare):toBe(true)
		end
	end)
end)
