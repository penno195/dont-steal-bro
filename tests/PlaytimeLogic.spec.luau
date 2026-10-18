--!strict
-- Covers PlaytimeLogic.luau: the free season pass for 6 active hours in
-- one week (payoff-loop step 5; design-decisions.md Q1's "a payoff for
-- every round" case). What counts as active, the week and season resets,
-- the per-credit cap, and when the pass falls due.

local TestRunner = require("./TestRunner")
local PlaytimeLogic = require("../src/server/PlaytimeLogic")
local PeriodKeys = require("../src/server/PeriodKeys")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local DAY = 86400
local HOUR = 3600
local CONFIG: PlaytimeLogic.Config = { activeHoursPerWeek = 6, idleWindowSeconds = 120, maxCreditSeconds = 120 }

-- Epoch day 20003 is a Monday ((20003 + 3) % 7 == 0).
local MONDAY = 20003 * DAY
local SEASON: PlaytimeLogic.SeasonRef = { id = "s1", startsAt = MONDAY - 30 * DAY }
local NEXT_SEASON: PlaytimeLogic.SeasonRef = { id = "s2", startsAt = MONDAY + 2 * DAY } -- a Wednesday

-- Credits `minutes` one-minute ticks from `from`, returning the state and
-- whether the last tick found the pass due.
local function play(
	state: PlaytimeLogic.State?,
	season: PlaytimeLogic.SeasonRef,
	from: number,
	minutes: number
): (PlaytimeLogic.State?, boolean)
	local due = false
	for i = 1, minutes do
		state, due = PlaytimeLogic.credit(CONFIG, state, season, false, from + i * 60, 60)
	end
	return state, due
end

describe("PlaytimeLogic.weekStart", function()
	it("is Monday 00:00 UTC, the same as PeriodKeys.weekStart", function()
		expect(PlaytimeLogic.weekStart(MONDAY)):toBe(MONDAY)
		expect(PlaytimeLogic.weekStart(MONDAY + 6 * DAY + 23 * HOUR)):toBe(MONDAY)
		expect(PlaytimeLogic.weekStart(MONDAY - 1)):toBe(MONDAY - 7 * DAY)
		for _, t in { MONDAY + 3 * DAY + 17, MONDAY - 3 * DAY, 0, 1234567890 } do
			expect(PlaytimeLogic.weekStart(t)):toBe(PeriodKeys.weekStart(t))
		end
	end)
end)

describe("PlaytimeLogic.isActive", function()
	it("always counts a ranked match, even with no input", function()
		expect(PlaytimeLogic.isActive(CONFIG, "Match", MONDAY, nil)):toBe(true)
		expect(PlaytimeLogic.isActive(CONFIG, "Match", MONDAY, MONDAY - HOUR)):toBe(true)
	end)

	it("counts the Hub and practice only with input in the last 2 minutes", function()
		for _, context: PlaytimeLogic.Context in { "Hub", "Practice" } do
			expect(PlaytimeLogic.isActive(CONFIG, context, MONDAY, MONDAY - 30)):toBe(true)
			expect(PlaytimeLogic.isActive(CONFIG, context, MONDAY, MONDAY - 120)):toBe(true)
			expect(PlaytimeLogic.isActive(CONFIG, context, MONDAY, MONDAY - 121)):toBe(false)
			expect(PlaytimeLogic.isActive(CONFIG, context, MONDAY, nil)):toBe(false)
		end
	end)
end)

describe("PlaytimeLogic.credit", function()
	it("falls due at exactly 6 hours, not before", function()
		local state, due = play(nil, SEASON, MONDAY + HOUR, 6 * 60 - 1)
		expect(due):toBe(false)
		expect((state :: PlaytimeLogic.State).activeSeconds):toBe(6 * HOUR - 60)
		local _, now = PlaytimeLogic.credit(CONFIG, state, SEASON, false, MONDAY + 8 * HOUR, 60)
		expect(now):toBe(true)
	end)

	it("adds up across sessions on different days of the week", function()
		local state = play(nil, SEASON, MONDAY + HOUR, 3 * 60)
		local after, due = play(state, SEASON, MONDAY + 5 * DAY, 3 * 60)
		expect(due):toBe(true)
		expect((after :: PlaytimeLogic.State).weekStart):toBe(MONDAY)
	end)

	it("restarts the count each Monday", function()
		local state = play(nil, SEASON, MONDAY + HOUR, 5 * 60)
		local after, due = play(state, SEASON, MONDAY + 7 * DAY + HOUR, 60)
		local s = after :: PlaytimeLogic.State
		expect(due):toBe(false)
		expect(s.weekStart):toBe(MONDAY + 7 * DAY)
		expect(s.activeSeconds):toBe(HOUR)
	end)

	it("restarts the count at a season change, even mid-week", function()
		-- Five hours Monday in the old season, then two on Wednesday in the
		-- new one: the old season's hours don't carry (owner, 2026-10-18).
		local state = play(nil, SEASON, MONDAY + HOUR, 5 * 60)
		local after, due = play(state, NEXT_SEASON, MONDAY + 2 * DAY + HOUR, 2 * 60)
		local s = after :: PlaytimeLogic.State
		expect(due):toBe(false)
		expect(s.seasonId):toBe("s2")
		expect(s.activeSeconds):toBe(2 * HOUR)
	end)

	it("caps one credit, and credits nothing from before the week or season began", function()
		local state = PlaytimeLogic.credit(CONFIG, nil, SEASON, false, MONDAY + HOUR, 10 * HOUR)
		expect((state :: PlaytimeLogic.State).activeSeconds):toBe(120)
		-- 30s into Monday, a 60s tick only counts the 30s inside this week.
		local monday = PlaytimeLogic.credit(CONFIG, nil, SEASON, false, MONDAY + 30, 60)
		expect((monday :: PlaytimeLogic.State).activeSeconds):toBe(30)
		local first = PlaytimeLogic.credit(CONFIG, nil, NEXT_SEASON, false, NEXT_SEASON.startsAt + 10, 60)
		expect((first :: PlaytimeLogic.State).activeSeconds):toBe(10)
	end)

	it("ignores a negative or NaN credit", function()
		local state = PlaytimeLogic.credit(CONFIG, nil, SEASON, false, MONDAY + HOUR, -500)
		expect((state :: PlaytimeLogic.State).activeSeconds):toBe(0)
		local nan = PlaytimeLogic.credit(CONFIG, nil, SEASON, false, MONDAY + HOUR, 0 / 0)
		expect((nan :: PlaytimeLogic.State).activeSeconds):toBe(0)
	end)

	it("counts nothing with no live season, before it starts, or once the pass is held", function()
		local state = play(nil, SEASON, MONDAY + HOUR, 10)
		local none, noneDue = PlaytimeLogic.credit(CONFIG, state, nil, false, MONDAY + 2 * HOUR, 60)
		expect(none):toBe(state)
		expect(noneDue):toBe(false)
		local early, earlyDue = PlaytimeLogic.credit(CONFIG, nil, NEXT_SEASON, false, MONDAY + DAY, 60)
		expect(early):toBe(nil)
		expect(earlyDue):toBe(false)
		local held, heldDue = PlaytimeLogic.credit(CONFIG, state, SEASON, true, MONDAY + 2 * HOUR, 60)
		expect(held):toBe(state)
		expect(heldDue):toBe(false)
	end)

	it("stays due past the target until the pass is held, so a failed grant retries", function()
		local state = play(nil, SEASON, MONDAY + HOUR, 6 * 60)
		local _, again = PlaytimeLogic.credit(CONFIG, state, SEASON, false, MONDAY + 9 * HOUR, 60)
		expect(again):toBe(true)
	end)

	it("doesn't change the state it was given", function()
		local state = play(nil, SEASON, MONDAY + HOUR, 10) :: PlaytimeLogic.State
		PlaytimeLogic.credit(CONFIG, state, SEASON, false, MONDAY + 2 * HOUR, 60)
		expect(state.activeSeconds):toBe(600)
	end)
end)

describe("PlaytimeLogic.progress", function()
	it("shows this week's count, the target and when the week resets", function()
		local state = play(nil, SEASON, MONDAY + HOUR, 90)
		local p = PlaytimeLogic.progress(CONFIG, state, SEASON, MONDAY + 3 * DAY)
		expect(p.activeSeconds):toBe(90 * 60)
		expect(p.targetSeconds):toBe(6 * HOUR)
		expect(p.weekEndsAt):toBe(MONDAY + 7 * DAY)
	end)

	it("reads a stale week or season as 0, and never shows past the target", function()
		local state = play(nil, SEASON, MONDAY + HOUR, 90)
		expect(PlaytimeLogic.progress(CONFIG, state, SEASON, MONDAY + 8 * DAY).activeSeconds):toBe(0)
		expect(PlaytimeLogic.progress(CONFIG, state, NEXT_SEASON, MONDAY + 3 * DAY).activeSeconds):toBe(0)
		local long = play(nil, SEASON, MONDAY + HOUR, 7 * 60)
		expect(PlaytimeLogic.progress(CONFIG, long, SEASON, MONDAY + DAY).activeSeconds):toBe(6 * HOUR)
	end)
end)

describe("PlaytimeLogic.creditStarter", function()
	it("counts up to 30 minutes for life and falls due there", function()
		local counted, due = 0, false
		for _ = 1, 59 do
			counted, due = PlaytimeLogic.creditStarter(CONFIG, 30, counted, false, 30)
		end
		expect(counted):toBe(59 * 30)
		expect(due):toBe(false)
		counted, due = PlaytimeLogic.creditStarter(CONFIG, 30, counted, false, 30)
		expect(counted):toBe(30 * 60)
		expect(due):toBe(true)
	end)

	it("caps one credit, stops at the target and stays due until claimed", function()
		expect((PlaytimeLogic.creditStarter(CONFIG, 30, 0, false, 5000))):toBe(120)
		local counted, due = PlaytimeLogic.creditStarter(CONFIG, 30, 1790, false, 60)
		expect(counted):toBe(1800)
		expect(due):toBe(true)
		local _, again = PlaytimeLogic.creditStarter(CONFIG, 30, 1800, false, 30)
		expect(again):toBe(true)
	end)

	it("counts nothing once claimed, and ignores NaN or negative time", function()
		local counted, due = PlaytimeLogic.creditStarter(CONFIG, 30, 1800, true, 60)
		expect(counted):toBe(1800)
		expect(due):toBe(false)
		expect((PlaytimeLogic.creditStarter(CONFIG, 30, 100, false, -50))):toBe(100)
		expect((PlaytimeLogic.creditStarter(CONFIG, 30, 100, false, 0 / 0))):toBe(100)
	end)
end)

describe("PlaytimeLogic.starterGrants", function()
	it("pays each power-up as stock, sorted by id", function()
		local grants = PlaytimeLogic.starterGrants({ ["sprint-boost"] = 2, ["push-trip"] = 2, ["slow-field"] = 2 })
		expect(#grants):toBe(3)
		expect(grants[1].powerUpId):toBe("push-trip")
		expect(grants[2].powerUpId):toBe("slow-field")
		expect(grants[3].powerUpId):toBe("sprint-boost")
		expect(grants[1].amount):toBe(2)
		expect(grants[1].kind):toBe("PowerUpStock")
	end)
end)
