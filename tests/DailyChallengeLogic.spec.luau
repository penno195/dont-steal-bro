--!strict
-- Covers DailyChallengeLogic.luau: daily challenges (payoff-loop step 8;
-- design-decisions.md Q1's "a payoff for every round" case). The per-
-- player daily draw and its win cap, the lazy day reset, the free
-- reroll, what a round counts, and what finishing pays.

local TestRunner = require("./TestRunner")
local DailyChallengeLogic = require("../src/server/DailyChallengeLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

type Def = DailyChallengeLogic.Def

local CONFIG: DailyChallengeLogic.Config =
	{ picksPerDay = 3, maxWinPicks = 1, rerollsPerDay = 1, allDoneCoins = 50, allDoneXp = 100 }

local function def(id: string, metric: DailyChallengeLogic.Metric, target: number, powerUpId: string?): Def
	return {
		id = id,
		enabled = true,
		displayName = "Do it %d times",
		metric = metric,
		target = target,
		powerUpId = powerUpId,
		coins = 25,
		xp = 50,
	}
end

local function defs(): { Def }
	return {
		def("play", "RoundsPlayed", 3),
		def("tasks", "TasksDone", 15),
		def("studio", "StudioVisits", 2),
		def("first", "FirstPlaces", 1),
		def("hits", "Hits", 5),
		def("freeze", "Hits", 5, "freeze"),
		def("win", "Wins", 1),
		def("share", "SharedAndWon", 1),
		def("steal", "StoleAndWon", 1),
	}
end

local function tally(overrides: { [string]: any }?): DailyChallengeLogic.RoundTally
	local t: DailyChallengeLogic.RoundTally = {
		tasksDone = 0,
		place = nil,
		reachedStudio = false,
		won = false,
		choice = nil,
		hitsByPowerUp = {},
	}
	for k, v in overrides or {} do
		(t :: any)[k] = v
	end
	return t
end

local function ids(state: DailyChallengeLogic.State): { string }
	local out = {}
	for _, slot in state.slots do
		table.insert(out, slot.id)
	end
	return out
end

local function winsOn(state: DailyChallengeLogic.State, all: { Def }): number
	local metricOf = {}
	for _, d in all do
		metricOf[d.id] = d.metric
	end
	local n = 0
	for _, slot in state.slots do
		if DailyChallengeLogic.needsWin(metricOf[slot.id]) then
			n += 1
		end
	end
	return n
end

describe("DailyChallengeLogic.forDay", function()
	it("draws picksPerDay distinct challenges, the same every time for that player and day", function()
		local a = DailyChallengeLogic.forDay(nil, defs(), CONFIG, 101, "2026-10-18")
		local b = DailyChallengeLogic.forDay(nil, defs(), CONFIG, 101, "2026-10-18")
		expect(#a.slots):toBe(3)
		expect(table.concat(ids(a), ",")):toBe(table.concat(ids(b), ","))
		expect(a.slots[1].id ~= a.slots[2].id and a.slots[2].id ~= a.slots[3].id and a.slots[1].id ~= a.slots[3].id):toBeTruthy()
		expect(#a.drawn):toBe(3)
		expect(a.rerollsUsed):toBe(0)
	end)

	it("never puts more than maxWinPicks win-only challenges on a list", function()
		-- Almost all win-only: the cap must skip past them.
		local all = {
			def("win", "Wins", 1),
			def("share", "SharedAndWon", 1),
			def("steal", "StoleAndWon", 1),
			def("play", "RoundsPlayed", 3),
			def("tasks", "TasksDone", 15),
			def("studio", "StudioVisits", 2),
		}
		for userId = 1, 200 do
			local state = DailyChallengeLogic.forDay(nil, all, CONFIG, userId, "2026-10-18")
			expect(#state.slots):toBe(3)
			expect(winsOn(state, all) <= 1):toBeTruthy()
		end
	end)

	it("gives different players and different days different lists", function()
		local seen: { [string]: boolean } = {}
		local distinct = 0
		for userId = 1, 50 do
			local key = table.concat(ids(DailyChallengeLogic.forDay(nil, defs(), CONFIG, userId, "2026-10-18")), ",")
			if not seen[key] then
				seen[key] = true
				distinct += 1
			end
		end
		expect(distinct > 5):toBeTruthy()
		local today = DailyChallengeLogic.forDay(nil, defs(), CONFIG, 7, "2026-10-18")
		local differs = false
		for day = 19, 25 do
			local other = DailyChallengeLogic.forDay(nil, defs(), CONFIG, 7, "2026-10-" .. day)
			if table.concat(ids(other), ",") ~= table.concat(ids(today), ",") then
				differs = true
			end
		end
		expect(differs):toBeTruthy()
	end)

	it("keeps today's state and resets lazily on a new day", function()
		local state = DailyChallengeLogic.forDay(nil, defs(), CONFIG, 7, "2026-10-18")
		state = (DailyChallengeLogic.applyRound(state, defs(), CONFIG, tally()))
		expect(DailyChallengeLogic.forDay(state, defs(), CONFIG, 7, "2026-10-18")):toBe(state)
		local tomorrow = DailyChallengeLogic.forDay(state, defs(), CONFIG, 7, "2026-10-19")
		expect(tomorrow.day):toBe("2026-10-19")
		for _, slot in tomorrow.slots do
			expect(slot.progress):toBe(0)
			expect(slot.done):toBe(false)
		end
		expect(tomorrow.allDonePaid):toBe(false)
	end)

	it("never draws a disabled challenge", function()
		local all = defs()
		for _, d in all do
			if d.id ~= "play" and d.id ~= "tasks" and d.id ~= "studio" then
				d.enabled = false
			end
		end
		local state = DailyChallengeLogic.forDay(nil, all, CONFIG, 3, "2026-10-18")
		table.sort(state.drawn)
		expect(table.concat(state.drawn, ",")):toBe("play,studio,tasks")
	end)
end)

describe("DailyChallengeLogic.reroll", function()
	it("swaps an unfinished slot for an undrawn challenge, once a day", function()
		local state = DailyChallengeLogic.forDay(nil, defs(), CONFIG, 9, "2026-10-18")
		local before = state.slots[2].id
		local after, refusal = DailyChallengeLogic.reroll(state, 2, defs(), CONFIG, 9)
		expect(refusal):toBe(nil)
		assert(after)
		expect(after.slots[2].id ~= before):toBeTruthy()
		expect(after.slots[2].progress):toBe(0)
		expect(after.slots[1].id):toBe(state.slots[1].id)
		expect(#after.drawn):toBe(4)
		expect(after.rerollsUsed):toBe(1)
		-- The original is untouched (pure).
		expect(state.slots[2].id):toBe(before)
		local again, why = DailyChallengeLogic.reroll(after, 1, defs(), CONFIG, 9)
		expect(again):toBe(nil)
		expect(why):toBe("NoRerolls")
	end)

	it("refuses a finished slot or a slot that isn't there", function()
		local state = DailyChallengeLogic.forDay(nil, defs(), CONFIG, 9, "2026-10-18")
		state.slots[1].done = true
		local _, why = DailyChallengeLogic.reroll(state, 1, defs(), CONFIG, 9)
		expect(why):toBe("AlreadyDone")
		_, why = DailyChallengeLogic.reroll(state, 4, defs(), CONFIG, 9)
		expect(why):toBe("BadSlot")
	end)

	it("never brings back a challenge drawn earlier today, and keeps the win cap", function()
		local config = table.clone(CONFIG)
		config.rerollsPerDay = 3
		for userId = 1, 100 do
			local state = DailyChallengeLogic.forDay(nil, defs(), config, userId, "2026-10-18")
			for _ = 1, 3 do
				local after = DailyChallengeLogic.reroll(state, 1, defs(), config, userId)
				assert(after)
				local seen: { [string]: boolean } = {}
				for _, id in after.drawn do
					expect(seen[id]):toBe(nil)
					seen[id] = true
				end
				expect(winsOn(after, defs()) <= 1):toBeTruthy()
				state = after
			end
		end
	end)

	it("says NoCandidate when the pool has run dry", function()
		local all = { def("a", "RoundsPlayed", 1), def("b", "TasksDone", 1), def("c", "StudioVisits", 1) }
		local state = DailyChallengeLogic.forDay(nil, all, CONFIG, 1, "2026-10-18")
		local _, why = DailyChallengeLogic.reroll(state, 1, all, CONFIG, 1)
		expect(why):toBe("NoCandidate")
	end)
end)

describe("DailyChallengeLogic.countFor", function()
	it("counts each metric from the round's own record", function()
		local t = tally({
			tasksDone = 6,
			place = 1,
			reachedStudio = true,
			won = true,
			choice = "Share",
			hitsByPowerUp = { freeze = 2, blind = 1 },
		})
		local all = defs()
		local expected =
			{ play = 1, tasks = 6, studio = 1, first = 1, hits = 3, freeze = 2, win = 1, share = 1, steal = 0 }
		for _, d in all do
			expect(DailyChallengeLogic.countFor(d, t)):toBe(expected[d.id])
		end
	end)

	it("counts a Steal win only for StoleAndWon, and nothing for a lost share", function()
		local all = defs()
		local stole = tally({ won = true, choice = "Steal", reachedStudio = true })
		local lostShare = tally({ won = false, choice = "Share", reachedStudio = true })
		for _, d in all do
			if d.id == "steal" then
				expect(DailyChallengeLogic.countFor(d, stole)):toBe(1)
			elseif d.id == "share" then
				expect(DailyChallengeLogic.countFor(d, stole)):toBe(0)
				expect(DailyChallengeLogic.countFor(d, lostShare)):toBe(0)
			end
		end
	end)
end)

describe("DailyChallengeLogic.applyRound", function()
	local function fixed(): DailyChallengeLogic.State
		return {
			day = "2026-10-18",
			slots = {
				{ id = "play", progress = 0, done = false },
				{ id = "tasks", progress = 0, done = false },
				{ id = "first", progress = 0, done = false },
			},
			drawn = { "play", "tasks", "first" },
			rerollsUsed = 0,
			allDonePaid = false,
		}
	end

	it("adds progress, caps it at the target, and pays each challenge once", function()
		local state, payout = DailyChallengeLogic.applyRound(fixed(), defs(), CONFIG, tally({ tasksDone = 20 }))
		expect(state.slots[1].progress):toBe(1)
		expect(state.slots[2].progress):toBe(15)
		expect(state.slots[2].done):toBe(true)
		expect(table.concat(payout.completed, ",")):toBe("tasks")
		expect(payout.coins):toBe(25)
		expect(payout.xp):toBe(50)
		local _, again = DailyChallengeLogic.applyRound(state, defs(), CONFIG, tally({ tasksDone = 6 }))
		expect(#again.completed):toBe(0)
		expect(again.coins):toBe(0)
	end)

	it("pays the all-done bonus the round the last one finishes, and only then", function()
		local state = fixed()
		state.slots[1].progress = 2
		state.slots[2].progress = 15
		state.slots[2].done = true
		local after, payout = DailyChallengeLogic.applyRound(state, defs(), CONFIG, tally({ place = 1 }))
		expect(table.concat(payout.completed, ",")):toBe("play,first")
		expect(payout.allDone):toBe(true)
		expect(payout.coins):toBe(25 + 25 + 50)
		expect(payout.xp):toBe(50 + 50 + 100)
		expect(after.allDonePaid):toBe(true)
		local _, later = DailyChallengeLogic.applyRound(after, defs(), CONFIG, tally({ place = 1 }))
		expect(later.allDone):toBe(false)
		expect(later.coins):toBe(0)
	end)

	it("counts nothing for a challenge removed or disabled mid-day", function()
		local all = defs()
		for _, d in all do
			if d.id == "play" then
				d.enabled = false
			end
		end
		local state, payout = DailyChallengeLogic.applyRound(fixed(), all, CONFIG, tally())
		expect(state.slots[1].progress):toBe(0)
		expect(#payout.completed):toBe(0)
		local gone = fixed()
		gone.slots[1].id = "deleted-file"
		state = DailyChallengeLogic.applyRound(gone, defs(), CONFIG, tally())
		expect(state.slots[1].progress):toBe(0)
	end)
end)

describe("DailyChallengeLogic.label", function()
	it("fills the target into a %d and leaves a plain line alone", function()
		expect(DailyChallengeLogic.label(def("x", "Hits", 5))):toBe("Do it 5 times")
		local plain = def("y", "SharedAndWon", 1)
		plain.displayName = "Share and survive"
		expect(DailyChallengeLogic.label(plain)):toBe("Share and survive")
	end)
end)
