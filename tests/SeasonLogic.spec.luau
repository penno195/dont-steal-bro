--!strict
-- Covers SeasonLogic.luau: season windows, the free and premium track
-- counts, claiming track items exactly once, and granting what's left
-- unclaimed when a season ends (rewards-roadmap.md step 5; claim
-- buttons, user decision 2026-10-09).

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
local AFTER = 1100 * DAY

local function winTimes(progress: SeasonLogic.Progress?, n: number, now: number): SeasonLogic.Progress?
	for _ = 1, n do
		progress = SeasonLogic.recordWin(progress, season(), now)
	end
	return progress
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
	TestRunner.it("counts wins on both tracks and pays nothing until claimed", function()
		local p = winTimes(nil, 4, DURING) :: SeasonLogic.Progress
		TestRunner.expect(p.freeWins):toBe(4)
		TestRunner.expect(p.premiumWins):toBe(4)
		TestRunner.expect(p.freePaid):toBe(0)
		TestRunner.expect(p.premiumPaid):toBe(0)
	end)

	TestRunner.it("ignores a win outside the window", function()
		TestRunner.expect(winTimes(nil, 1, 999 * DAY)):toBe(nil)
		local p = winTimes(nil, 1, DURING)
		local after = winTimes(p, 1, 1090 * DAY)
		TestRunner.expect((after :: SeasonLogic.Progress).freeWins):toBe(1)
	end)

	TestRunner.it("never mutates the progress passed in", function()
		local progress = SeasonLogic.newProgress()
		SeasonLogic.recordWin(progress, season(), DURING)
		TestRunner.expect(progress.freeWins):toBe(0)
	end)
end)

TestRunner.describe("SeasonLogic.buyPass", function()
	TestRunner.it("unlocks the premium track without paying anything", function()
		local progress = winTimes(nil, 3, DURING)
		local after, bought = SeasonLogic.buyPass(progress, season(), DURING + 10)
		local p = after :: SeasonLogic.Progress
		TestRunner.expect(bought):toBe(true)
		TestRunner.expect(p.passSeenAt):toBe(DURING + 10)
		TestRunner.expect(p.premiumPaid):toBe(0)
		TestRunner.expect(SeasonLogic.hasPass(p)):toBe(true)
	end)

	TestRunner.it("buys nothing twice in one season, or outside the window", function()
		local held = SeasonLogic.buyPass(nil, season(), DURING)
		local again, bought = SeasonLogic.buyPass(held, season(), DURING + 60)
		TestRunner.expect(bought):toBe(false)
		TestRunner.expect(again):toBe(held)

		local _, early = SeasonLogic.buyPass(nil, season(), 999 * DAY)
		TestRunner.expect(early):toBe(false)
		local _, late = SeasonLogic.buyPass(nil, season(), 1090 * DAY)
		TestRunner.expect(late):toBe(false)
	end)
end)

TestRunner.describe("SeasonLogic.claim", function()
	TestRunner.it("claims one track up to a tile, earlier tiles included", function()
		local progress = winTimes(nil, 4, DURING)
		local after, paid = SeasonLogic.claim(progress, season(), DURING + 5, "Free", 2)
		local p = after :: SeasonLogic.Progress
		TestRunner.expect(p.freePaid):toBe(2)
		TestRunner.expect(#paid):toBe(2)
		TestRunner.expect(paid[1].grant.amount):toBe(100)
		TestRunner.expect(paid[2].grant.powerUpId):toBe("sprint-boost")
	end)

	TestRunner.it("claims only what the wins have reached", function()
		local progress = winTimes(nil, 2, DURING)
		local after, paid = SeasonLogic.claim(progress, season(), DURING + 5, "Free", 2)
		TestRunner.expect((after :: SeasonLogic.Progress).freePaid):toBe(1)
		TestRunner.expect(#paid):toBe(1)
	end)

	TestRunner.it("pays an item exactly once", function()
		local progress = winTimes(nil, 2, DURING)
		local once = SeasonLogic.claim(progress, season(), DURING + 5, "Free", 1)
		local again, paid = SeasonLogic.claim(once, season(), DURING + 6, "Free", 1)
		TestRunner.expect(again):toBe(once)
		TestRunner.expect(#paid):toBe(0)
	end)

	TestRunner.it("refuses premium items without the pass", function()
		local progress = winTimes(nil, 3, DURING)
		local after, paid = SeasonLogic.claim(progress, season(), DURING + 5, "Premium", 3)
		TestRunner.expect(after):toBe(progress)
		TestRunner.expect(#paid):toBe(0)
	end)

	TestRunner.it("claims premium items the pass unlocked", function()
		local progress = SeasonLogic.buyPass(winTimes(nil, 1, DURING), season(), DURING + 10)
		local after, paid = SeasonLogic.claim(progress, season(), DURING + 20, "Premium", 3)
		TestRunner.expect((after :: SeasonLogic.Progress).premiumPaid):toBe(2)
		TestRunner.expect(paid[1].grant.cosmeticId):toBe("trail-founder")
		TestRunner.expect(paid[2].grant.amount):toBe(250)
	end)

	TestRunner.it("claims everything reached on both tracks at once", function()
		local progress = SeasonLogic.buyPass(winTimes(nil, 3, DURING), season(), DURING + 10)
		local after, paid = SeasonLogic.claim(progress, season(), DURING + 20, nil, nil)
		local p = after :: SeasonLogic.Progress
		TestRunner.expect(p.freePaid):toBe(1)
		TestRunner.expect(p.premiumPaid):toBe(3)
		TestRunner.expect(#paid):toBe(4)
	end)

	TestRunner.it("claims nothing outside the window, or without progress", function()
		local progress = winTimes(nil, 4, DURING)
		local after, paid = SeasonLogic.claim(progress, season(), AFTER, nil, nil)
		TestRunner.expect(after):toBe(progress)
		TestRunner.expect(#paid):toBe(0)
		local none, nothing = SeasonLogic.claim(nil, season(), DURING, nil, nil)
		TestRunner.expect(none):toBe(nil)
		TestRunner.expect(#nothing):toBe(0)
	end)

	TestRunner.it("ignores a track with no list position", function()
		local progress = winTimes(nil, 4, DURING)
		local _, paid = SeasonLogic.claim(progress, season(), DURING, "Free", nil)
		TestRunner.expect(#paid):toBe(0)
	end)
end)

TestRunner.describe("SeasonLogic.sync", function()
	TestRunner.it("starts tracking a live season, paying nothing", function()
		local progress, paid = SeasonLogic.sync(nil, season(), DURING)
		TestRunner.expect((progress :: SeasonLogic.Progress).passSeenAt):toBe(nil)
		TestRunner.expect(SeasonLogic.hasPass(progress)):toBe(false)
		TestRunner.expect(#paid):toBe(0)
	end)

	TestRunner.it("leaves reached items waiting while the season is live", function()
		local progress = winTimes(nil, 4, DURING)
		local after, paid = SeasonLogic.sync(progress, season(), DURING + 5)
		TestRunner.expect((after :: SeasonLogic.Progress).freePaid):toBe(0)
		TestRunner.expect(#paid):toBe(0)
	end)

	TestRunner.it("does nothing before the season starts", function()
		local progress, paid = SeasonLogic.sync(nil, season(), 999 * DAY)
		TestRunner.expect(progress):toBe(nil)
		TestRunner.expect(#paid):toBe(0)
	end)

	TestRunner.it("after the end: no entry for a player who never took part", function()
		TestRunner.expect(SeasonLogic.sync(nil, season(), AFTER)):toBe(nil)
	end)

	TestRunner.it("after the end: grants everything reached but unclaimed", function()
		local progress = SeasonLogic.buyPass(winTimes(nil, 2, DURING), season(), DURING + 10)
		local claimed = SeasonLogic.claim(progress, season(), DURING + 20, "Premium", 1)
		local after, paid = SeasonLogic.sync(claimed, season(), AFTER)
		local p = after :: SeasonLogic.Progress
		TestRunner.expect(p.freePaid):toBe(1)
		TestRunner.expect(p.premiumPaid):toBe(2)
		TestRunner.expect(#paid):toBe(2)
		-- Settled: a later join grants nothing more.
		local _, again = SeasonLogic.sync(after, season(), AFTER + DAY)
		TestRunner.expect(#again):toBe(0)
	end)

	TestRunner.it("catches up a profile from before premium counted every win", function()
		local old: SeasonLogic.Progress =
			{ passSeenAt = DURING, freeWins = 3, premiumWins = 1, freePaid = 1, premiumPaid = 2 }
		local after = SeasonLogic.sync(old, season(), DURING + 5)
		TestRunner.expect((after :: SeasonLogic.Progress).premiumWins):toBe(3)
	end)
end)

TestRunner.describe("SeasonLogic.describePaid", function()
	TestRunner.it("names the season, track, count and grant", function()
		local line =
			SeasonLogic.describePaid("s1", { track = "Free", wins = 3, grant = { kind = "Currency", amount = 100 } })
		TestRunner.expect(line):toBe("Season s1 Free @3 wins: Currency 100")
	end)
end)
