--!strict
-- Covers PeriodKeys.luau (P4-4): UTC day keys, ISO week keys, period
-- bounds, TTL and rollover detection. LeaderboardService isn't required
-- here - it touches MemoryStoreService and a real clock, so it's
-- exercised in Studio, the same split every other spec in this suite
-- uses.
--
-- The ISO week cases are the point of this file. ISO week 1 is the week
-- containing the first Thursday of January, so the last days of
-- December can belong to week 1 of the NEXT year and the first days of
-- January to week 52 or 53 of the PREVIOUS one. That is exactly the
-- kind of rule that is "obviously fine" until a New Year's Eve
-- leaderboard silently merges two years, and it is only checkable by
-- naming real dates - which is what the fixtures below are.
--
-- Every timestamp here is a real UTC instant, computed once with
-- os.time on a UTC table so the expectations are readable.

local TestRunner = require("./TestRunner")
local PeriodKeys = require("../src/server/PeriodKeys")

local SECONDS_PER_DAY = 86400

-- os.time interprets a table as LOCAL time, so a UTC fixture has to be
-- corrected by the machine's own offset - otherwise this spec would
-- pass in London and fail in Sydney, which is the exact class of bug it
-- exists to catch.
local function utc(year: number, month: number, day: number, hour: number?, minute: number?): number
	local naive = os.time({ year = year, month = month, day = day, hour = hour or 0, min = minute or 0, sec = 0 })
	local offset = os.difftime(naive, os.time(os.date("!*t", naive) :: any))
	return naive + offset
end

TestRunner.describe("PeriodKeys.isoWeekday", function()
	TestRunner.it("puts the epoch on a Thursday", function()
		-- 1970-01-01 was a Thursday, and the whole weekday calculation
		-- is derived from that one fact.
		TestRunner.expect(PeriodKeys.isoWeekday(0)):toBe(4)
	end)

	TestRunner.it("numbers Monday through Sunday as 1 to 7", function()
		-- 2026-09-21 is a Monday.
		TestRunner.expect(PeriodKeys.isoWeekday(utc(2026, 9, 21))):toBe(1)
		TestRunner.expect(PeriodKeys.isoWeekday(utc(2026, 9, 24))):toBe(4)
		TestRunner.expect(PeriodKeys.isoWeekday(utc(2026, 9, 27))):toBe(7)
	end)

	TestRunner.it("is stable across a whole day", function()
		local monday = utc(2026, 9, 21)
		TestRunner.expect(PeriodKeys.isoWeekday(monday + 23 * 3600 + 3599)):toBe(1)
	end)
end)

TestRunner.describe("PeriodKeys.dayKey", function()
	TestRunner.it("formats the UTC date", function()
		TestRunner.expect(PeriodKeys.dayKey(utc(2026, 9, 22, 13, 30))):toBe("2026-09-22")
	end)

	TestRunner.it("is the same key for the first and last second of a UTC day", function()
		local start = utc(2026, 9, 22)
		TestRunner.expect(PeriodKeys.dayKey(start)):toBe("2026-09-22")
		TestRunner.expect(PeriodKeys.dayKey(start + SECONDS_PER_DAY - 1)):toBe("2026-09-22")
	end)

	TestRunner.it("rolls at UTC midnight, not a second before or after", function()
		local midnight = utc(2026, 9, 23)
		TestRunner.expect(PeriodKeys.dayKey(midnight - 1)):toBe("2026-09-22")
		TestRunner.expect(PeriodKeys.dayKey(midnight)):toBe("2026-09-23")
	end)

	TestRunner.it("crosses a month boundary", function()
		TestRunner.expect(PeriodKeys.dayKey(utc(2026, 9, 30, 23, 59))):toBe("2026-09-30")
		TestRunner.expect(PeriodKeys.dayKey(utc(2026, 10, 1, 0, 1))):toBe("2026-10-01")
	end)

	TestRunner.it("crosses a leap day", function()
		TestRunner.expect(PeriodKeys.dayKey(utc(2028, 2, 29, 12))):toBe("2028-02-29")
	end)
end)

TestRunner.describe("PeriodKeys.isoWeekKey - ordinary weeks", function()
	TestRunner.it("gives one key for a whole Monday-to-Sunday week", function()
		-- 2026-09-21 (Mon) through 2026-09-27 (Sun).
		local expected = PeriodKeys.isoWeekKey(utc(2026, 9, 21))
		for dayOffset = 0, 6 do
			TestRunner.expect(PeriodKeys.isoWeekKey(utc(2026, 9, 21) + dayOffset * SECONDS_PER_DAY)):toBe(expected)
		end
	end)

	TestRunner.it("changes on the Monday, not the Sunday", function()
		local sunday = utc(2026, 9, 27, 23, 59)
		local monday = utc(2026, 9, 28, 0, 1)
		assert(PeriodKeys.isoWeekKey(sunday) ~= PeriodKeys.isoWeekKey(monday), "the week must roll on Monday")
	end)

	TestRunner.it("zero-pads the week number so keys sort", function()
		local key = PeriodKeys.isoWeekKey(utc(2026, 1, 8))
		assert(string.match(key, "^%d+%-W%d%d$") ~= nil, string.format("%q is not YYYY-Www", key))
	end)
end)

TestRunner.describe("PeriodKeys.isoWeekKey - the year boundary", function()
	TestRunner.it("puts 2026-01-01 (a Thursday) in week 1 of 2026", function()
		-- Its own week contains the first Thursday of January - itself.
		TestRunner.expect(PeriodKeys.isoWeekKey(utc(2026, 1, 1))):toBe("2026-W01")
	end)

	TestRunner.it("puts late December 2025 in the SAME week as early January 2026", function()
		-- 2025-12-29 is a Monday; the week runs into 2026-01-04. Keying
		-- on the calendar year would split one week across two years and
		-- give a Tuesday and a Thursday different boards.
		TestRunner.expect(PeriodKeys.isoWeekKey(utc(2025, 12, 29))):toBe("2026-W01")
		TestRunner.expect(PeriodKeys.isoWeekKey(utc(2025, 12, 31))):toBe("2026-W01")
		TestRunner.expect(PeriodKeys.isoWeekKey(utc(2026, 1, 4))):toBe("2026-W01")
	end)

	TestRunner.it("puts 2027-01-01 (a Friday) in the LAST week of 2026", function()
		-- The ISO year runs ahead of and behind the calendar year in
		-- different years, and this is the other direction.
		TestRunner.expect(PeriodKeys.isoWeekKey(utc(2027, 1, 1))):toBe("2026-W53")
	end)

	TestRunner.it("starts 2027's week 1 on its own Monday", function()
		TestRunner.expect(PeriodKeys.isoWeekKey(utc(2027, 1, 4))):toBe("2027-W01")
	end)

	TestRunner.it("never emits week 0", function()
		-- The failure mode of a naive (ordinalDay / 7) calculation.
		for dayOffset = 0, 400 do
			local key = PeriodKeys.isoWeekKey(utc(2025, 12, 1) + dayOffset * SECONDS_PER_DAY)
			assert(string.match(key, "%-W00$") == nil, string.format("%q is week zero", key))
		end
	end)
end)

TestRunner.describe("PeriodKeys.boundsFor", function()
	TestRunner.it("bounds a day from midnight to midnight", function()
		local bounds = PeriodKeys.boundsFor("Daily", utc(2026, 9, 22, 15))
		TestRunner.expect(bounds.startsAt):toBe(utc(2026, 9, 22))
		TestRunner.expect(bounds.endsAt):toBe(utc(2026, 9, 23))
	end)

	TestRunner.it("bounds a week from Monday to the next Monday", function()
		local bounds = PeriodKeys.boundsFor("Weekly", utc(2026, 9, 24, 9))
		TestRunner.expect(bounds.startsAt):toBe(utc(2026, 9, 21))
		TestRunner.expect(bounds.endsAt):toBe(utc(2026, 9, 28))
	end)

	TestRunner.it("treats the end as exclusive - it is the next period's start", function()
		local bounds = PeriodKeys.boundsFor("Daily", utc(2026, 9, 22))
		TestRunner.expect(PeriodKeys.dayKey(bounds.endsAt)):toBe("2026-09-23")
	end)
end)

TestRunner.describe("PeriodKeys.liveExpirySeconds", function()
	TestRunner.it("covers the rest of the period plus the grace margin", function()
		local noon = utc(2026, 9, 22, 12)
		TestRunner.expect(PeriodKeys.liveExpirySeconds("Daily", noon, 3600)):toBe(12 * 3600 + 3600)
	end)

	TestRunner.it("shrinks as the period runs down, so entries expire together", function()
		-- Measured from NOW, because a MemoryStore TTL counts from the
		-- write. A fixed "one day" for a 23:58 write would keep it alive
		-- almost a full day into the next period.
		local early = PeriodKeys.liveExpirySeconds("Daily", utc(2026, 9, 22, 1), 600)
		local late = PeriodKeys.liveExpirySeconds("Daily", utc(2026, 9, 22, 23), 600)
		assert(late < early, "a later write must get a shorter TTL")
	end)

	TestRunner.it("never returns a TTL at or below zero on the boundary", function()
		local midnight = utc(2026, 9, 23)
		assert(PeriodKeys.liveExpirySeconds("Daily", midnight, 600) >= 600, "TTL collapsed on the boundary")
	end)

	TestRunner.it("gives a week a longer life than a day", function()
		local monday = utc(2026, 9, 21, 12)
		assert(
			PeriodKeys.liveExpirySeconds("Weekly", monday, 600) > PeriodKeys.liveExpirySeconds("Daily", monday, 600),
			"a weekly period should outlive a daily one"
		)
	end)
end)

TestRunner.describe("PeriodKeys.hasRolledOver", function()
	TestRunner.it("is false when the period has not changed", function()
		TestRunner.expect(PeriodKeys.hasRolledOver("2026-09-22", "2026-09-22")):toBe(false)
	end)

	TestRunner.it("is true when it has", function()
		TestRunner.expect(PeriodKeys.hasRolledOver("2026-09-22", "2026-09-23")):toBe(true)
	end)

	TestRunner.it("is FALSE on a server's first ever check", function()
		-- A server booting at 3am has not just witnessed midnight.
		-- Treating nil as a rollover would have every new server
		-- re-processing a period that ended hours ago.
		TestRunner.expect(PeriodKeys.hasRolledOver(nil, "2026-09-23")):toBe(false)
	end)

	TestRunner.it("detects a gap of several periods, not just adjacent ones", function()
		-- A server asleep for three days, or a clock that jumped.
		TestRunner.expect(PeriodKeys.hasRolledOver("2026-09-19", "2026-09-23")):toBe(true)
	end)
end)

TestRunner.describe("PeriodKeys - key shapes", function()
	TestRunner.it("scopes the live map name by period", function()
		TestRunner.expect(PeriodKeys.liveMapName("Daily", "2026-09-22")):toBe("streak_daily_2026-09-22")
		TestRunner.expect(PeriodKeys.liveMapName("Weekly", "2026-W39")):toBe("streak_weekly_2026-W39")
	end)

	TestRunner.it("keeps snapshot and rollover-lock keys distinct from the live map", function()
		-- Three different stores; a collision between them would mean a
		-- rollover lock landing in the standings.
		local live = PeriodKeys.liveMapName("Daily", "2026-09-22")
		local snapshot = PeriodKeys.snapshotKey("Daily", "2026-09-22")
		local lock = PeriodKeys.rolloverLockKey("Daily", "2026-09-22")
		assert(live ~= snapshot and snapshot ~= lock and live ~= lock, "key shapes collide")
	end)

	TestRunner.it("gives the same period the same key from any instant inside it", function()
		local morning = PeriodKeys.keyFor("Daily", utc(2026, 9, 22, 6))
		local evening = PeriodKeys.keyFor("Daily", utc(2026, 9, 22, 22))
		TestRunner.expect(morning):toBe(evening)
	end)
end)
