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
		TestRunner.expect(migrated.schemaVersion):toBe(7)
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
		TestRunner.expect(migrated.schemaVersion):toBe(7)
		TestRunner.expect(migrated.currentStreak):toBe(7)
		TestRunner.expect(migrated.bestStreak):toBe(12)
		TestRunner.expect(migrated.currency):toBe(250)
	end)

	TestRunner.it("is a no-op for a profile already at the current schema version", function()
		local template = ProfileLogic.newProfileTemplate()
		template.currentStreak = 4
		local migrated = ProfileLogic.migrate(template :: any)
		TestRunner.expect(migrated.currentStreak):toBe(4)
		TestRunner.expect(migrated.schemaVersion):toBe(7)
	end)

	TestRunner.it("gives a v2 profile an empty settings table and keeps its store fields", function()
		local migrated = ProfileLogic.migrate({
			schemaVersion = 2,
			currentStreak = 5,
			purchaseIdCache = { "a" },
			powerUpStock = { SprintBoost = 2 },
		})
		TestRunner.expect(migrated.schemaVersion):toBe(7)
		TestRunner.expect(next(migrated.settings)):toBe(nil)
		TestRunner.expect(migrated.currentStreak):toBe(5)
		TestRunner.expect(migrated.purchaseIdCache[1]):toBe("a")
		TestRunner.expect(migrated.powerUpStock.SprintBoost):toBe(2)
	end)

	TestRunner.it("drops a v3 profile's pendingBounty and starts it with no win reward", function()
		-- A PendingBounty never paid anything (its reward table was never
		-- built), so there is nothing to carry into lastWinReward.
		local migrated: any = ProfileLogic.migrate({
			schemaVersion = 3,
			currentStreak = 2,
			currency = 40,
			pendingBounty = { streakTier = 1, outcomeTag = "AllShare", grantedAt = 1000 },
		})
		TestRunner.expect(migrated.schemaVersion):toBe(7)
		TestRunner.expect(migrated.pendingBounty):toBe(nil)
		TestRunner.expect(migrated.lastWinReward):toBe(nil)
		TestRunner.expect(migrated.currentStreak):toBe(2)
		TestRunner.expect(migrated.currency):toBe(40)
	end)

	TestRunner.it("gives a v4 profile no season progress and keeps its win reward", function()
		local reward = { roundId = "r1", outcomeTag = "AllShare", rung = 1, currency = 50, grantedAt = 1000 }
		local migrated = ProfileLogic.migrate({ schemaVersion = 4, currentStreak = 1, lastWinReward = reward })
		TestRunner.expect(migrated.schemaVersion):toBe(7)
		TestRunner.expect(next(migrated.seasonProgress)):toBe(nil)
		TestRunner.expect((migrated.lastWinReward :: any).currency):toBe(50)
	end)

	TestRunner.it("gives a v5 profile an empty last loadout and keeps its selection", function()
		local migrated = ProfileLogic.migrate({ schemaVersion = 5, starterPowerUps = { "freeze" } })
		TestRunner.expect(migrated.schemaVersion):toBe(7)
		TestRunner.expect(#migrated.lastLoadout):toBe(0)
		TestRunner.expect(migrated.starterPowerUps[1]):toBe("freeze")
	end)

	TestRunner.it("gives a v6 profile no paid Navigation rounds", function()
		local migrated = ProfileLogic.migrate({ schemaVersion = 6, currency = 40 })
		TestRunner.expect(migrated.schemaVersion):toBe(7)
		TestRunner.expect(migrated.navigationRounds):toBe(0)
		TestRunner.expect(migrated.currency):toBe(40)
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
