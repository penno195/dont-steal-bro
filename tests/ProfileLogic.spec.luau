--!strict
-- Covers ProfileLogic.luau (P1-5): the pure half of the player data
-- service. DataService.luau itself isn't required here - it touches
-- ProfileStore/Players at call time, so it's exercised manually in
-- Studio instead, same split as NetGuard.luau/Net.spec.luau (P1-3) and
-- ConfigValidator.luau/Config.spec.luau (P1-4). The four scenarios named
-- by the P1-5 task are all here: migration chain, mid-round leave,
-- failed load, and double-release.

local TestRunner = require("./TestRunner")
local ProfileLogic = require("../src/server/ProfileLogic")

TestRunner.describe("ProfileLogic.migrate (migration chain)", function()
	TestRunner.it("fills every v1 field with defaults for a completely empty old profile", function()
		local migrated = ProfileLogic.migrate({})
		TestRunner.expect(migrated.schemaVersion):toBe(3)
		TestRunner.expect(migrated.currentStreak):toBe(0)
		TestRunner.expect(migrated.bestStreak):toBe(0)
		TestRunner.expect(migrated.currency):toBe(0)
		TestRunner.expect(#migrated.ownedCosmetics):toBe(0)
		TestRunner.expect(migrated.stats.roundsPlayed):toBe(0)
	end)

	TestRunner.it("preserves real fields already present on a pre-versioning profile", function()
		local migrated = ProfileLogic.migrate({
			currentStreak = 7,
			bestStreak = 12,
			currency = 250,
		})
		TestRunner.expect(migrated.schemaVersion):toBe(3)
		TestRunner.expect(migrated.currentStreak):toBe(7)
		TestRunner.expect(migrated.bestStreak):toBe(12)
		TestRunner.expect(migrated.currency):toBe(250)
	end)

	TestRunner.it("is a no-op for a profile already at the current schema version", function()
		local template = ProfileLogic.newProfileTemplate()
		template.currentStreak = 4
		local migrated = ProfileLogic.migrate(template :: any)
		TestRunner.expect(migrated.currentStreak):toBe(4)
		TestRunner.expect(migrated.schemaVersion):toBe(3)
	end)

	TestRunner.it("gives a v2 profile an empty settings table and keeps its store fields", function()
		local migrated = ProfileLogic.migrate({
			schemaVersion = 2,
			currentStreak = 5,
			purchaseIdCache = { "a" },
			powerUpStock = { SprintBoost = 2 },
		})
		TestRunner.expect(migrated.schemaVersion):toBe(3)
		TestRunner.expect(next(migrated.settings)):toBe(nil)
		TestRunner.expect(migrated.currentStreak):toBe(5)
		TestRunner.expect(migrated.purchaseIdCache[1]):toBe("a")
		TestRunner.expect(migrated.powerUpStock.SprintBoost):toBe(2)
	end)

	TestRunner.it("never mutates the table passed in", function()
		local old: any = { currentStreak = 3 }
		ProfileLogic.migrate(old)
		TestRunner.expect(old.schemaVersion):toBe(nil)
	end)
end)

TestRunner.describe("ProfileLogic.classifyLoadOutcome (failed load)", function()
	TestRunner.it("classifies a successful load", function()
		TestRunner.expect(ProfileLogic.classifyLoadOutcome(false, false)):toBe("Loaded")
	end)

	TestRunner.it("classifies a nil profile caused by our own Cancel (player already left)", function()
		TestRunner.expect(ProfileLogic.classifyLoadOutcome(true, true)):toBe("CancelledByLeave")
	end)

	TestRunner.it("classifies a nil profile NOT caused by Cancel as a session-lock/outage diagnostic", function()
		TestRunner.expect(ProfileLogic.classifyLoadOutcome(true, false)):toBe("LikelyLockedOrOutage")
	end)
end)

TestRunner.describe("ProfileLogic.applyLeaveSequence (mid-round leave ordering)", function()
	TestRunner.it("applies the pending outcome before ending the session", function()
		local order: { string } = {}
		ProfileLogic.applyLeaveSequence(function()
			table.insert(order, "applyPendingOutcome")
		end, function()
			table.insert(order, "endSession")
		end)
		TestRunner.expect(order[1]):toBe("applyPendingOutcome")
		TestRunner.expect(order[2]):toBe("endSession")
	end)

	TestRunner.it("still ends the session when there is no pending outcome", function()
		local endedSession = false
		ProfileLogic.applyLeaveSequence(nil, function()
			endedSession = true
		end)
		TestRunner.expect(endedSession):toBe(true)
	end)
end)

TestRunner.describe("ProfileLogic.release (double-release)", function()
	TestRunner.it("runs the release sequence on the first call", function()
		local endedSession = false
		local ran = ProfileLogic.release(false, nil, function()
			endedSession = true
		end)
		TestRunner.expect(ran):toBe(true)
		TestRunner.expect(endedSession):toBe(true)
	end)

	TestRunner.it("is a safe no-op when already released - no second EndSession call", function()
		local endSessionCalls = 0
		local ran = ProfileLogic.release(true, nil, function()
			endSessionCalls += 1
		end)
		TestRunner.expect(ran):toBe(false)
		TestRunner.expect(endSessionCalls):toBe(0)
	end)

	TestRunner.it("preserves ordering on the call that actually runs", function()
		local order: { string } = {}
		ProfileLogic.release(false, function()
			table.insert(order, "outcome")
		end, function()
			table.insert(order, "end")
		end)
		TestRunner.expect(order[1]):toBe("outcome")
		TestRunner.expect(order[2]):toBe("end")
	end)
end)

TestRunner.describe("ProfileLogic.resolveBountyTier", function()
	local tiers: { ProfileLogic.BountyTier } = {
		{ tier = 1, minStreak = 1, soleStealerVU = 20, loneSharerVU = 10, allShareVU = 5 },
		{ tier = 2, minStreak = 3, soleStealerVU = 24, loneSharerVU = 12, allShareVU = 6 },
		{ tier = 5, minStreak = 15, soleStealerVU = 36, loneSharerVU = 18, allShareVU = 9 },
	}

	TestRunner.it("picks the lowest tier at its exact floor", function()
		TestRunner.expect(ProfileLogic.resolveBountyTier(tiers, 1).tier):toBe(1)
	end)

	TestRunner.it("picks the highest tier whose floor has been reached", function()
		TestRunner.expect(ProfileLogic.resolveBountyTier(tiers, 4).tier):toBe(2)
		TestRunner.expect(ProfileLogic.resolveBountyTier(tiers, 20).tier):toBe(5)
	end)

	TestRunner.it("errors when no tier covers the streak", function()
		local ok = pcall(function()
			ProfileLogic.resolveBountyTier(tiers, 0)
		end)
		TestRunner.expect(ok):toBe(false)
	end)
end)
