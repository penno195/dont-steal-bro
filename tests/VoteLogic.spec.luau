--!strict
-- Covers VoteLogic.luau (P5-3): the ballot draw and its recency
-- weighting, casting and changing votes, the tally, locking, and the
-- random tie-break, including that the tie-break is uniform. VoteService
-- itself needs MemoryStore and live players, so it is verified in Studio
-- instead (docs/voting.md), the same split every other spec uses.

local TestRunner = require("./TestRunner")
local VoteLogic = require("../src/server/VoteLogic")
local MatchmakingLogic = require("../src/server/MatchmakingLogic")

type VoteState = VoteLogic.VoteState

-- A seeded stand-in for Roblox's Random, which doesn't exist under Lune.
-- Same LCG constants as TaskAssignment.luau.
local function seededRng(seed: number): VoteLogic.Rng
	local state = seed % 2 ^ 32
	local function nextFloat(): number
		state = (1664525 * state + 1013904223) % 2 ^ 32
		return state / 2 ^ 32
	end
	return {
		NextNumber = function(_self: any): number
			return nextFloat()
		end,
		NextInteger = function(_self: any, min: number, max: number): number
			return min + math.floor(nextFloat() * (max - min + 1))
		end,
	}
end

local BALLOT = { "Docks", "Foundry", "Greenhouse", "Observatory" }
local MEMBERS = { 11, 22, 33, 44, 55, 66 }
local WEIGHTING: VoteLogic.Weighting = { floorWeight = 0.2, decay = 0.5 }

local function state(votes: { { u: number, m: string } }?): VoteState
	return { members = MEMBERS, ballot = BALLOT, votes = votes or {}, result = nil }
end

local function countsOf(pairs: { [string]: number }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, mapId in BALLOT do
		counts[mapId] = pairs[mapId] or 0
	end
	return counts
end

-- Runs pickWinner `runs` times and returns how often each map won.
local function winFrequencies(counts: { [string]: number }, runs: number): { [string]: number }
	local rng = seededRng(12345)
	local wins: { [string]: number } = {}
	for _ = 1, runs do
		local picked = VoteLogic.pickWinner(BALLOT, counts, rng)
		assert(picked, "expected a winner")
		wins[picked.winner] = (wins[picked.winner] or 0) + 1
	end
	return wins
end

-- Every tied map should win about runs/#tied times. 4000 runs over at
-- most 4 maps puts one standard deviation near 27 wins, so ±10% of the
-- expected count is over three deviations: a fair draw passes, and a
-- biased one (always the first, or skipping the last) fails by far.
local function expectUniform(wins: { [string]: number }, tied: { string }, runs: number)
	local expected = runs / #tied
	for _, mapId in tied do
		local got = wins[mapId] or 0
		TestRunner.expect(math.abs(got - expected) <= expected * 0.1):toBeTruthy()
	end
	local total = 0
	for _, count in wins do
		total += count
	end
	TestRunner.expect(total):toBe(runs)
end

TestRunner.describe("VoteLogic.pickWinner (the tie rule)", function()
	TestRunner.it("a single top map wins outright, with no random draw", function()
		local counts = countsOf({ Docks = 1, Foundry = 3, Greenhouse = 2 })
		local wins = winFrequencies(counts, 200)
		TestRunner.expect(wins.Foundry):toBe(200)
		local picked = VoteLogic.pickWinner(BALLOT, counts, seededRng(1))
		assert(picked)
		TestRunner.expect(picked.randomTieBreak):toBe(false)
		TestRunner.expect(#picked.tied):toBe(1)
	end)

	TestRunner.it("two tied out of four: only those two can win, uniformly", function()
		local counts = countsOf({ Docks = 2, Foundry = 1, Greenhouse = 2, Observatory = 1 })
		local picked = VoteLogic.pickWinner(BALLOT, counts, seededRng(2))
		assert(picked)
		TestRunner.expect(picked.randomTieBreak):toBe(true)
		TestRunner.expect(#picked.tied):toBe(2)
		TestRunner.expect(picked.tied[1]):toBe("Docks")
		TestRunner.expect(picked.tied[2]):toBe("Greenhouse")

		local wins = winFrequencies(counts, 4000)
		TestRunner.expect(wins.Foundry):toBe(nil)
		TestRunner.expect(wins.Observatory):toBe(nil)
		expectUniform(wins, { "Docks", "Greenhouse" }, 4000)
	end)

	TestRunner.it("all four tied: each wins about a quarter of the time", function()
		local counts = countsOf({ Docks = 1, Foundry = 1, Greenhouse = 1, Observatory = 1 })
		expectUniform(winFrequencies(counts, 4000), BALLOT, 4000)
	end)

	TestRunner.it("no votes at all: every ballot map is tied on zero, drawn uniformly", function()
		local counts = countsOf({})
		local picked = VoteLogic.pickWinner(BALLOT, counts, seededRng(3))
		assert(picked)
		TestRunner.expect(picked.randomTieBreak):toBe(true)
		TestRunner.expect(#picked.tied):toBe(4)
		expectUniform(winFrequencies(counts, 4000), BALLOT, 4000)
	end)

	TestRunner.it("an empty ballot has no winner", function()
		TestRunner.expect(VoteLogic.pickWinner({}, {}, seededRng(4))):toBe(nil)
	end)
end)

TestRunner.describe("VoteLogic.castVote", function()
	TestRunner.it("records a first vote and replaces a changed one", function()
		local votes = VoteLogic.castVote(state(), 11, "Docks")
		assert(votes)
		TestRunner.expect(#votes):toBe(1)
		local changed = VoteLogic.castVote(state(votes), 11, "Foundry")
		assert(changed)
		TestRunner.expect(#changed):toBe(1)
		TestRunner.expect(changed[1].m):toBe("Foundry")
	end)

	TestRunner.it("keeps other players' votes when one player changes theirs", function()
		local votes = { { u = 22, m = "Docks" }, { u = 11, m = "Docks" } }
		local changed = VoteLogic.castVote(state(votes), 11, "Greenhouse")
		assert(changed)
		TestRunner.expect(#changed):toBe(2)
		TestRunner.expect(changed[1].u):toBe(22)
	end)

	TestRunner.it("refuses each invalid vote with its reason", function()
		local locked = state()
		locked.result = { winner = "Docks", tied = { "Docks" } }
		local cases: { { any } } = {
			{ nil, 11, "Docks", "NoRecord" },
			{ { members = MEMBERS, ballot = {}, votes = {}, result = nil }, 11, "Docks", "NoBallot" },
			{ locked, 11, "Foundry", "Locked" },
			{ state(), 99, "Docks", "NotMember" },
			{ state(), 11, "Atlantis", "NotOnBallot" },
			{ state({ { u = 11, m = "Docks" } }), 11, "Docks", "Unchanged" },
		}
		for _, case in cases do
			local votes, reason = VoteLogic.castVote(case[1], case[2], case[3])
			TestRunner.expect(votes):toBe(nil)
			TestRunner.expect(reason):toBe(case[4])
		end
	end)
end)

TestRunner.describe("VoteLogic.tally", function()
	TestRunner.it("counts each member's last vote, ignoring strangers and off-ballot maps", function()
		local tally = VoteLogic.tally(state({
			{ u = 11, m = "Docks" },
			{ u = 22, m = "Docks" },
			{ u = 11, m = "Foundry" }, -- 11 changed their mind
			{ u = 99, m = "Docks" }, -- not a member
			{ u = 33, m = "Atlantis" }, -- not on the ballot
		}))
		TestRunner.expect(tally.counts.Docks):toBe(1)
		TestRunner.expect(tally.counts.Foundry):toBe(1)
		TestRunner.expect(tally.counts.Greenhouse):toBe(0)
		TestRunner.expect(tally.voted):toBe(2)
		TestRunner.expect(tally.voters.Docks[1]):toBe(22)
	end)
end)

TestRunner.describe("VoteLogic.lock", function()
	TestRunner.it("locks on the most-voted map", function()
		local result = VoteLogic.lock(state({ { u = 11, m = "Greenhouse" } }), seededRng(5))
		assert(result)
		TestRunner.expect(result.winner):toBe("Greenhouse")
		TestRunner.expect(#result.tied):toBe(1)
	end)

	TestRunner.it("refuses once locked, so a second server can't re-roll a tie", function()
		local locked = state()
		locked.result = { winner = "Docks", tied = BALLOT }
		TestRunner.expect(VoteLogic.lock(locked, seededRng(6))):toBe(nil)
		TestRunner.expect(VoteLogic.lock(nil, seededRng(6))):toBe(nil)
	end)

	TestRunner.it("locks at the deadline, or early once every member has voted", function()
		local partial = state({ { u = 11, m = "Docks" } })
		TestRunner.expect(VoteLogic.shouldLock(partial, 100, 110)):toBe(false)
		TestRunner.expect(VoteLogic.shouldLock(partial, 110, 110)):toBe(true)
		local everyone: { { u: number, m: string } } = {}
		for _, userId in MEMBERS do
			table.insert(everyone, { u = userId, m = "Foundry" })
		end
		TestRunner.expect(VoteLogic.shouldLock(state(everyone), 100, 110)):toBe(true)
	end)

	TestRunner.it("never stretches the window when the former's clock runs ahead", function()
		TestRunner.expect(VoteLogic.deadline(1000, 15, 1000)):toBe(1015)
		TestRunner.expect(VoteLogic.deadline(1030, 15, 1000)):toBe(1015)
		TestRunner.expect(VoteLogic.deadline(990, 15, 1000)):toBe(1005)
	end)
end)

TestRunner.describe("VoteLogic.drawBallot", function()
	local ELEVEN = {
		"m01",
		"m02",
		"m03",
		"m04",
		"m05",
		"m06",
		"m07",
		"m08",
		"m09",
		"m10",
		"m11",
	}

	TestRunner.it("draws the requested number of distinct enabled maps, never all 11", function()
		local ballot = VoteLogic.drawBallot(ELEVEN, {}, 4, WEIGHTING, seededRng(7))
		TestRunner.expect(#ballot):toBe(4)
		local seen: { [string]: boolean } = {}
		for _, mapId in ballot do
			TestRunner.expect(seen[mapId]):toBe(nil)
			TestRunner.expect(table.find(ELEVEN, mapId) ~= nil):toBeTruthy()
			seen[mapId] = true
		end
	end)

	TestRunner.it("returns what exists on a small pool, and nothing to vote on below two", function()
		TestRunner.expect(#VoteLogic.drawBallot({ "a", "b" }, {}, 4, WEIGHTING, seededRng(8))):toBe(2)
		TestRunner.expect(#VoteLogic.drawBallot({ "a" }, {}, 4, WEIGHTING, seededRng(8))):toBe(0)
		TestRunner.expect(#VoteLogic.drawBallot({}, {}, 4, WEIGHTING, seededRng(8))):toBe(0)
	end)

	TestRunner.it("puts recently played maps on the ballot less often, but never bans them", function()
		-- Everyone played m01 last round and m02 the round before.
		local recent = { { "m01", "m02" }, { "m01", "m02" }, { "m01", "m02" } }
		local rng = seededRng(9)
		local appearances: { [string]: number } = {}
		local runs = 3000
		for _ = 1, runs do
			for _, mapId in VoteLogic.drawBallot(ELEVEN, recent, 4, WEIGHTING, rng) do
				appearances[mapId] = (appearances[mapId] or 0) + 1
			end
		end
		local fresh = appearances.m05 or 0
		local last = appearances.m01 or 0
		local before = appearances.m02 or 0
		TestRunner.expect(last > 0):toBeTruthy()
		TestRunner.expect(last < before):toBeTruthy()
		TestRunner.expect(before < fresh):toBeTruthy()
		-- Weight 0.2 vs 1: well under half as often as a fresh map.
		TestRunner.expect(last < fresh * 0.5):toBeTruthy()
	end)

	TestRunner.it("averages exposure over members, so one regular can't shut a map out", function()
		TestRunner.expect(VoteLogic.exposure("m01", { { "m01" }, {}, {}, {} }, 0.5)):toBe(0.25)
		TestRunner.expect(VoteLogic.exposure("m01", { { "m02", "m01" } }, 0.5)):toBe(0.5)
		TestRunner.expect(VoteLogic.exposure("m01", {}, 0.5)):toBe(0)
		TestRunner.expect(VoteLogic.mapWeight("m01", { { "m01" } }, WEIGHTING)):toBeCloseTo(0.2)
	end)

	TestRunner.it("is uniform when nobody has history", function()
		local rng = seededRng(10)
		local appearances: { [string]: number } = {}
		local runs = 4400
		for _ = 1, runs do
			for _, mapId in VoteLogic.drawBallot(ELEVEN, {}, 4, WEIGHTING, rng) do
				appearances[mapId] = (appearances[mapId] or 0) + 1
			end
		end
		local expected = runs * 4 / 11
		for _, mapId in ELEVEN do
			TestRunner.expect(math.abs((appearances[mapId] or 0) - expected) <= expected * 0.1):toBeTruthy()
		end
	end)
end)

TestRunner.describe("VoteLogic board and history", function()
	TestRunner.it("shows counts, voters and the viewer's own vote", function()
		local board = VoteLogic.boardState("g1", state({ { u = 11, m = "Docks" }, { u = 22, m = "Docks" } }), 22, 7.2)
		TestRunner.expect(board.cards[1].mapId):toBe("Docks")
		TestRunner.expect(board.cards[1].votes):toBe(2)
		TestRunner.expect(#board.cards[1].voters):toBe(2)
		TestRunner.expect(board.myVote):toBe("Docks")
		TestRunner.expect(board.secondsLeft):toBe(8)
		TestRunner.expect(board.locked):toBe(false)
		TestRunner.expect(board.randomTieBreak):toBe(false)
	end)

	TestRunner.it("marks a randomly broken tie so the client can show it", function()
		local locked = state()
		locked.result = { winner = "Foundry", tied = { "Docks", "Foundry" } }
		local board = VoteLogic.boardState("g1", locked, 11, 0)
		TestRunner.expect(board.locked):toBe(true)
		TestRunner.expect(board.winner):toBe("Foundry")
		TestRunner.expect(board.randomTieBreak):toBe(true)
	end)

	TestRunner.it("keeps recent maps newest first, unique and capped", function()
		local list = VoteLogic.pushRecent({ "b", "a", "c" }, "a", 3)
		TestRunner.expect(list[1]):toBe("a")
		TestRunner.expect(list[2]):toBe("b")
		TestRunner.expect(list[3]):toBe("c")
		TestRunner.expect(#VoteLogic.pushRecent({ "b", "c", "d" }, "a", 3)):toBe(3)
	end)
end)

TestRunner.describe("MatchmakingLogic group record with a vote", function()
	TestRunner.it("round-trips the ballot, votes and result, and drops malformed votes", function()
		local decoded = MatchmakingLogic.decodeGroup({
			v = MatchmakingLogic.SCHEMA_VERSION,
			groupId = "g1",
			members = { 11, 22 },
			npcSlots = 4,
			mapId = "Docks",
			ballot = { "Docks", "Foundry", 7 },
			votes = { { u = 11, m = "Docks" }, { u = "x", m = "Docks" }, { u = 22 } },
			result = { winner = "Docks", tied = { "Docks", "Foundry" } },
		})
		assert(decoded)
		TestRunner.expect(#decoded.ballot):toBe(2)
		TestRunner.expect(#decoded.votes):toBe(1)
		assert(decoded.result)
		TestRunner.expect(#decoded.result.tied):toBe(2)
	end)

	TestRunner.it("a record from before P5-3 decodes with an empty ballot, so the vote is skipped", function()
		local decoded = MatchmakingLogic.decodeGroup({
			v = MatchmakingLogic.SCHEMA_VERSION,
			groupId = "g1",
			members = { 11 },
			npcSlots = 5,
		})
		assert(decoded)
		TestRunner.expect(#decoded.ballot):toBe(0)
		TestRunner.expect(decoded.result):toBe(nil)
	end)
end)
