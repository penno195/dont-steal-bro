--!strict
-- Covers SeasonLogic.luau: season windows, the free and premium track
-- counts, and paying track items exactly once (rewards-roadmap.md step 5).

local TestRunner = require("./TestRunner")
local SeasonLogic = require("../src/server/SeasonLogic")

local DAY = 86400

local function season(): SeasonLogic.Season
	return {
		id = "s1",
		startsAt = 1000 * DAY,
		endsAt = 1090 * DAY,
		free = {
			{ wins = 2, grant = { kind = "Currency", amount = 100 } },
			{ wins = 4, grant = { kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 1 } },
		},
		premium = {
			{ wins = 0, grant = { kind = "Cosmetic", cosmeticId = "trail-founder" } },
			{ wins = 1, grant = { kind = "Currency", amount = 250 } },
			{ wins = 3, grant = { kind = "Cosmetic", cosmeticId = "skin-founder" } },
		},
	}
end

local DURING = 1010 * DAY

local function winTimes(
	progress: SeasonLogic.Progress?,
	n: number,
	now: number
): (SeasonLogic.Progress?, { SeasonLogic.Paid })
	local all: { SeasonLogic.Paid } = {}
	for _ = 1, n do
		local paid
		progress, paid = SeasonLogic.recordWin(progress, season(), now)
		for _, item in paid do
			table.insert(all, item)
		end
	end
	return progress, all
end

TestRunner.describe("SeasonLogic.parseUtcDate", function()
	TestRunner.it("reads a date as 00:00 UTC", function()
		TestRunner.expect(SeasonLogic.parseUtcDate("1970-01-01")):toBe(0)
		TestRunner.expect(SeasonLogic.parseUtcDate("1970-01-02")):toBe(DAY)
		TestRunner.expect(SeasonLogic.parseUtcDate("2000-03-01")):toBe(951868800)
		TestRunner.expect(SeasonLogic.parseUtcDate("2026-10-01")):toBe(1790812800)
	end)

	TestRunner.it("refuses what isn't a real calendar date", function()
		TestRunner.expect(SeasonLogic.parseUtcDate("2026-02-29")):toBe(nil)
		TestRunner.expect(SeasonLogic.parseUtcDate("2026-13-01")):toBe(nil)
		TestRunner.expect(SeasonLogic.parseUtcDate("2026-1-01")):toBe(nil)
		TestRunner.expect(SeasonLogic.parseUtcDate(20261001)):toBe(nil)
		TestRunner.expect(SeasonLogic.parseUtcDate("2024-02-29")):toBe(1709164800)
	end)
end)

TestRunner.describe("SeasonLogic.fromDef", function()
	local function def(): { [string]: any }
		return { id = "s1", enabled = true, startsOn = "2026-10-01", endsOn = "2027-01-01", free = {}, premium = {} }
	end

	TestRunner.it("resolves an enabled season's window", function()
		local s = SeasonLogic.fromDef(def()) :: SeasonLogic.Season
		TestRunner.expect(s.startsAt):toBe(1790812800)
		TestRunner.expect(SeasonLogic.isLive(s, s.startsAt)):toBe(true)
		TestRunner.expect(SeasonLogic.isLive(s, s.endsAt)):toBe(false)
	end)

	TestRunner.it("skips a disabled season", function()
		local d = def()
		d.enabled = false
		TestRunner.expect(SeasonLogic.fromDef(d)):toBe(nil)
	end)
end)

TestRunner.describe("SeasonLogic.recordWin", function()
	TestRunner.it("counts free wins for everyone and pays items in order", function()
		local progress, paid = winTimes(nil, 4, DURING)
		local p = progress :: SeasonLogic.Progress
		TestRunner.expect(p.freeWins):toBe(4)
		TestRunner.expect(p.premiumWins):toBe(0)
		TestRunner.expect(p.freePaid):toBe(2)
		TestRunner.expect(p.premiumPaid):toBe(0)
		TestRunner.expect(#paid):toBe(2)
		TestRunner.expect(paid[1].grant.amount):toBe(100)
		TestRunner.expect(paid[2].grant.powerUpId):toBe("sprint-boost")
	end)

	TestRunner.it("ignores a win outside the window", function()
		local before, _ = winTimes(nil, 1, 999 * DAY)
		TestRunner.expect(before):toBe(nil)
		local p = winTimes(nil, 1, DURING)
		local after = winTimes(p, 1, 1090 * DAY)
		TestRunner.expect((after :: SeasonLogic.Progress).freeWins):toBe(1)
	end)

	TestRunner.it("counts premium wins only after the pass was seen", function()
		local progress = winTimes(nil, 2, DURING)
		progress = SeasonLogic.sync(progress, season(), DURING + 10, true)
		local after, paid = winTimes(progress, 1, DURING + 20)
		local p = after :: SeasonLogic.Progress
		TestRunner.expect(p.freeWins):toBe(3)
		TestRunner.expect(p.premiumWins):toBe(1)
		TestRunner.expect(p.premiumPaid):toBe(2)
		TestRunner.expect(#paid):toBe(1)
		TestRunner.expect(paid[1].track):toBe("Premium")
		TestRunner.expect(paid[1].grant.amount):toBe(250)
	end)

	TestRunner.it("never mutates the progress passed in", function()
		local progress = SeasonLogic.newProgress()
		SeasonLogic.recordWin(progress, season(), DURING)
		TestRunner.expect(progress.freeWins):toBe(0)
	end)
end)

TestRunner.describe("SeasonLogic.sync", function()
	TestRunner.it("records the pass sighting and pays the 0-win item once", function()
		local progress, paid = SeasonLogic.sync(nil, season(), DURING, true)
		local p = progress :: SeasonLogic.Progress
		TestRunner.expect(p.passSeenAt):toBe(DURING)
		TestRunner.expect(#paid):toBe(1)
		TestRunner.expect(paid[1].grant.cosmeticId):toBe("trail-founder")

		local again, paidAgain = SeasonLogic.sync(p, season(), DURING + 60, true)
		TestRunner.expect((again :: SeasonLogic.Progress).passSeenAt):toBe(DURING)
		TestRunner.expect(#paidAgain):toBe(0)
	end)

	TestRunner.it("starts tracking a live season without a pass, paying nothing premium", function()
		local progress, paid = SeasonLogic.sync(nil, season(), DURING, false)
		TestRunner.expect((progress :: SeasonLogic.Progress).passSeenAt):toBe(nil)
		TestRunner.expect(#paid):toBe(0)
	end)

	TestRunner.it("does nothing before the season starts", function()
		local progress, paid = SeasonLogic.sync(nil, season(), 999 * DAY, true)
		TestRunner.expect(progress):toBe(nil)
		TestRunner.expect(#paid):toBe(0)
	end)

	TestRunner.it("after the end: no new sighting, and no entry for a player who never took part", function()
		local fresh = SeasonLogic.sync(nil, season(), 1100 * DAY, true)
		TestRunner.expect(fresh):toBe(nil)

		local played = winTimes(nil, 1, DURING)
		local after, paid = SeasonLogic.sync(played, season(), 1100 * DAY, true)
		TestRunner.expect((after :: SeasonLogic.Progress).passSeenAt):toBe(nil)
		TestRunner.expect(#paid):toBe(0)
	end)

	TestRunner.it("pays an item a config edit moved below the player's count", function()
		local progress = winTimes(nil, 1, DURING)
		local edited = season()
		edited.free[1] = { wins = 1, grant = { kind = "Currency", amount = 100 } }
		local after, paid = SeasonLogic.sync(progress, edited, DURING + 5, false)
		TestRunner.expect((after :: SeasonLogic.Progress).freePaid):toBe(1)
		TestRunner.expect(#paid):toBe(1)
	end)
end)

TestRunner.describe("SeasonLogic.describePaid", function()
	TestRunner.it("names the season, track, count and grant", function()
		local line =
			SeasonLogic.describePaid("s1", { track = "Free", wins = 3, grant = { kind = "Currency", amount = 100 } })
		TestRunner.expect(line):toBe("Season s1 Free @3 wins: Currency 100")
	end)
end)
