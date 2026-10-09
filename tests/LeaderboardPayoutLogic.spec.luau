--!strict
-- Covers LeaderboardPayoutLogic.luau: what a daily or weekly placement
-- pays (rewards-roadmap.md step 4), and the round trip of the profile
-- message that carries it to an offline winner.

local TestRunner = require("./TestRunner")
local LeaderboardPayoutLogic = require("../src/server/LeaderboardPayoutLogic")

local function payouts(): LeaderboardPayoutLogic.PayoutTable
	return {
		Daily = {
			{ maxRank = 1, currency = 500 },
			{ maxRank = 3, currency = 250 },
			{ maxRank = 10, currency = 100 },
		},
		Weekly = {
			{ maxRank = 1, currency = 2000, cosmeticId = "weekly-crown" },
			{ maxRank = 3, currency = 1000 },
			{ maxRank = 10, currency = 400 },
		},
	}
end

TestRunner.describe("LeaderboardPayoutLogic.bandFor", function()
	TestRunner.it("finds the band a rank falls in", function()
		local daily = payouts().Daily
		TestRunner.expect((LeaderboardPayoutLogic.bandFor(daily, 1) :: any).currency):toBe(500)
		TestRunner.expect((LeaderboardPayoutLogic.bandFor(daily, 2) :: any).currency):toBe(250)
		TestRunner.expect((LeaderboardPayoutLogic.bandFor(daily, 3) :: any).currency):toBe(250)
		TestRunner.expect((LeaderboardPayoutLogic.bandFor(daily, 4) :: any).currency):toBe(100)
		TestRunner.expect((LeaderboardPayoutLogic.bandFor(daily, 10) :: any).currency):toBe(100)
	end)

	TestRunner.it("pays nothing past the last band, below rank 1, or for an unlisted kind", function()
		TestRunner.expect(LeaderboardPayoutLogic.bandFor(payouts().Daily, 11)):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.bandFor(payouts().Daily, 0)):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.bandFor(payouts().AllTime, 1)):toBe(nil)
	end)
end)

TestRunner.describe("LeaderboardPayoutLogic.paidPlaces", function()
	TestRunner.it("is the last band's maxRank, or 0", function()
		TestRunner.expect(LeaderboardPayoutLogic.paidPlaces(payouts().Weekly)):toBe(10)
		TestRunner.expect(LeaderboardPayoutLogic.paidPlaces(nil)):toBe(0)
		TestRunner.expect(LeaderboardPayoutLogic.paidPlaces({})):toBe(0)
	end)
end)

TestRunner.describe("LeaderboardPayoutLogic.messageFor", function()
	TestRunner.it("carries the band's currency and cosmetic", function()
		local message = LeaderboardPayoutLogic.messageFor(payouts(), "Weekly", "2026-W40", 1) :: any
		TestRunner.expect(message.type):toBe(LeaderboardPayoutLogic.MESSAGE_TYPE)
		TestRunner.expect(message.kind):toBe("Weekly")
		TestRunner.expect(message.periodKey):toBe("2026-W40")
		TestRunner.expect(message.rank):toBe(1)
		TestRunner.expect(message.currency):toBe(2000)
		TestRunner.expect(message.cosmeticId):toBe("weekly-crown")
	end)

	TestRunner.it("is nil for an unpaid rank or an empty band", function()
		TestRunner.expect(LeaderboardPayoutLogic.messageFor(payouts(), "Daily", "2026-10-02", 11)):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.messageFor(payouts(), "AllTime", "x", 1)):toBe(nil)
		local empty = { Daily = { { maxRank = 1, currency = 0 } } }
		TestRunner.expect(LeaderboardPayoutLogic.messageFor(empty, "Daily", "2026-10-02", 1)):toBe(nil)
	end)
end)

TestRunner.describe("LeaderboardPayoutLogic.parseMessage", function()
	TestRunner.it("round-trips a built message", function()
		local built = LeaderboardPayoutLogic.messageFor(payouts(), "Daily", "2026-10-02", 2)
		local parsed = LeaderboardPayoutLogic.parseMessage(table.clone(built :: any)) :: any
		TestRunner.expect(parsed.rank):toBe(2)
		TestRunner.expect(parsed.currency):toBe(250)
		TestRunner.expect(parsed.cosmeticId):toBe(nil)
	end)

	TestRunner.it("rejects malformed messages", function()
		local good = {
			type = LeaderboardPayoutLogic.MESSAGE_TYPE,
			kind = "Daily",
			periodKey = "2026-10-02",
			rank = 1,
			currency = 500,
		}
		local function with(field: string, value: any): any
			local copy = table.clone(good) :: any
			copy[field] = value
			return copy
		end
		TestRunner.expect(LeaderboardPayoutLogic.parseMessage(good)):toBeTruthy()
		TestRunner.expect(LeaderboardPayoutLogic.parseMessage(nil)):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.parseMessage(with("type", "Gift"))):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.parseMessage(with("kind", ""))):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.parseMessage(with("periodKey", 7))):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.parseMessage(with("rank", 0))):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.parseMessage(with("rank", 1.5))):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.parseMessage(with("currency", -1))):toBe(nil)
		TestRunner.expect(LeaderboardPayoutLogic.parseMessage(with("cosmeticId", ""))):toBe(nil)
	end)
end)

TestRunner.describe("LeaderboardPayoutLogic.grantsFor", function()
	TestRunner.it("grants currency and the cosmetic when present", function()
		local message = LeaderboardPayoutLogic.messageFor(payouts(), "Weekly", "2026-W40", 1) :: any
		local grants = LeaderboardPayoutLogic.grantsFor(message)
		TestRunner.expect(#grants):toBe(2)
		TestRunner.expect(grants[1].kind):toBe("Currency")
		TestRunner.expect(grants[1].amount):toBe(2000)
		TestRunner.expect(grants[2].kind):toBe("Cosmetic")
		TestRunner.expect(grants[2].cosmeticId):toBe("weekly-crown")
	end)

	TestRunner.it("skips a zero currency grant", function()
		local message = {
			type = LeaderboardPayoutLogic.MESSAGE_TYPE,
			kind = "Daily",
			periodKey = "2026-10-02",
			rank = 1,
			currency = 0,
			cosmeticId = "daily-badge",
		}
		local grants = LeaderboardPayoutLogic.grantsFor(message)
		TestRunner.expect(#grants):toBe(1)
		TestRunner.expect(grants[1].kind):toBe("Cosmetic")
	end)
end)
