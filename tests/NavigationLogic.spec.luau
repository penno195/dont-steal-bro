--!strict
-- Covers NavigationLogic.luau (design-decisions.md Q8, "Navigation"):
-- when a switch-on spends a round, which station the path leads to, and
-- when a route counts as changed. Plus StoreLogic's NavigationRound
-- grant, since that is what fills the rounds a switch-on spends.

local TestRunner = require("./TestRunner")
local NavigationLogic = require("../src/server/NavigationLogic")
local StoreLogic = require("../src/server/StoreLogic")

local function facts(overrides: { [string]: any }?): NavigationLogic.SwitchOnFacts
	local f: NavigationLogic.SwitchOnFacts = {
		isRacing = true,
		ownsPass = false,
		chargedThisRound = false,
		roundsHeld = 0,
	}
	for key, value in overrides or {} do
		(f :: any)[key] = value
	end
	return f
end

TestRunner.describe("NavigationLogic.switchOn", function()
	TestRunner.it("asks for a purchase when nothing is held", function()
		local answer, spend = NavigationLogic.switchOn(facts())
		TestRunner.expect(answer):toBe("NeedsPurchase")
		TestRunner.expect(spend):toBe(false)
	end)

	TestRunner.it("spends a held round on the first switch-on", function()
		local answer, spend = NavigationLogic.switchOn(facts({ roundsHeld = 1 }))
		TestRunner.expect(answer):toBe("On")
		TestRunner.expect(spend):toBe(true)
	end)

	TestRunner.it("is free to switch on again in a race already paid for", function()
		local answer, spend = NavigationLogic.switchOn(facts({ chargedThisRound = true, roundsHeld = 2 }))
		TestRunner.expect(answer):toBe("On")
		TestRunner.expect(spend):toBe(false)
	end)

	TestRunner.it("never spends a held round for a pass owner", function()
		local answer, spend = NavigationLogic.switchOn(facts({ ownsPass = true, roundsHeld = 3 }))
		TestRunner.expect(answer):toBe("On")
		TestRunner.expect(spend):toBe(false)
	end)

	TestRunner.it("refuses outside a race, even for a pass owner", function()
		local answer, spend = NavigationLogic.switchOn(facts({ isRacing = false, ownsPass = true }))
		TestRunner.expect(answer):toBe("Unavailable")
		TestRunner.expect(spend):toBe(false)
	end)
end)

TestRunner.describe("NavigationLogic.nearestStation", function()
	local origin = { x = 0, y = 0, z = 0 }

	TestRunner.it("picks the nearest unfinished station", function()
		local id = NavigationLogic.nearestStation(origin, {
			{ stationId = "far", position = { x = 50, y = 0, z = 0 } },
			{ stationId = "near", position = { x = 0, y = 0, z = 10 } },
		})
		TestRunner.expect(id):toBe("near")
	end)

	TestRunner.it("counts height as further than distance across", function()
		-- 12 studs up is 36 weighted, so the one 30 studs across wins.
		local id = NavigationLogic.nearestStation(origin, {
			{ stationId = "upstairs", position = { x = 0, y = 12, z = 0 } },
			{ stationId = "across", position = { x = 30, y = 0, z = 0 } },
		})
		TestRunner.expect(id):toBe("across")
	end)

	TestRunner.it("keeps the earlier of two equally near stations", function()
		local id = NavigationLogic.nearestStation(origin, {
			{ stationId = "a", position = { x = 10, y = 0, z = 0 } },
			{ stationId = "b", position = { x = -10, y = 0, z = 0 } },
		})
		TestRunner.expect(id):toBe("a")
	end)

	TestRunner.it("answers nil when every station is finished", function()
		TestRunner.expect(NavigationLogic.nearestStation(origin, {})):toBe(nil)
	end)
end)

TestRunner.describe("NavigationLogic.routeKey", function()
	TestRunner.it("ignores float noise in the same waypoints", function()
		local a = NavigationLogic.routeKey("s1", { { x = 1.01, y = 2, z = 3 } })
		local b = NavigationLogic.routeKey("s1", { { x = 0.99, y = 2.2, z = 3.1 } })
		TestRunner.expect(a):toBe(b)
	end)

	TestRunner.it("changes with the target or the waypoints", function()
		local base = NavigationLogic.routeKey("s1", { { x = 0, y = 0, z = 0 } })
		TestRunner.expect(NavigationLogic.routeKey("s2", { { x = 0, y = 0, z = 0 } }) ~= base):toBeTruthy()
		TestRunner.expect(NavigationLogic.routeKey("s1", { { x = 9, y = 0, z = 0 } }) ~= base):toBeTruthy()
	end)
end)

TestRunner.describe("StoreLogic and Navigation rounds", function()
	local function state(): StoreLogic.GrantState
		return { currency = 150, powerUpStock = {}, ownedCosmetics = {}, unlockedTitles = {} }
	end

	TestRunner.it("adds a NavigationRound grant to the rounds held, nil read as 0", function()
		local after = StoreLogic.applyGrants(state(), { { kind = "NavigationRound", amount = 1 } })
		TestRunner.expect(after.navigationRounds):toBe(1)
	end)

	TestRunner.it("buys a round for 100 coins in one step", function()
		local s = state()
		s.navigationRounds = 2
		local after = StoreLogic.buyWithCoins(s, 100, { { kind = "NavigationRound", amount = 1 } })
		TestRunner.expect(after and after.currency):toBe(50)
		TestRunner.expect(after and after.navigationRounds):toBe(3)
	end)

	TestRunner.it("knows which products sell a round", function()
		TestRunner.expect(StoreLogic.grantsNavigationRound({ { kind = "NavigationRound", amount = 1 } })):toBe(true)
		TestRunner.expect(StoreLogic.grantsNavigationRound({ { kind = "Currency", amount = 1 } })):toBe(false)
	end)
end)

TestRunner.describe("NavigationLogic.shortlist", function()
	local function at(id: string, x: number, y: number): { stationId: string, position: NavigationLogic.Point }
		return { stationId = id, position = { x = x, y = y, z = 0 } }
	end

	TestRunner.it("ranks by weighted distance and caps the count", function()
		local list = NavigationLogic.shortlist({ x = 0, y = 0, z = 0 }, {
			at("far", 50, 0),
			at("upstairs", 0, 10), -- 30 weighted
			at("near", 5, 0),
			at("mid", 20, 0),
		}, 3)
		TestRunner.expect(#list):toBe(3)
		TestRunner.expect(list[1]):toBe("near")
		TestRunner.expect(list[2]):toBe("mid")
		TestRunner.expect(list[3]):toBe("upstairs")
	end)
end)
