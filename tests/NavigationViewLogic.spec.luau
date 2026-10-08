--!strict
-- Covers NavigationViewLogic.luau, Navigation's client half
-- (design-decisions.md Q8, "Navigation"): when the toggle shows, what
-- the buy sheet offers, and how a NavigationState payload reads. Plus
-- StoreScreenLogic keeping rounds out of the Hub grid.

local TestRunner = require("./TestRunner")
local NavigationViewLogic = require("../src/client/UI/NavigationViewLogic")
local StoreScreenLogic = require("../src/client/UI/StoreScreenLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function round(enabled: boolean): NavigationViewLogic.Item
	return {
		key = "navigation-round",
		kind = "DeveloperProduct",
		enabled = enabled,
		robuxPrice = 99,
		sortOrder = 200,
		grants = { { kind = "NavigationRound", amount = 1 } },
	}
end

local function coinRound(enabled: boolean): NavigationViewLogic.Item
	return {
		key = "navigation-round-coins",
		kind = "CoinOffer",
		enabled = enabled,
		robuxPrice = 0,
		coinPrice = 100,
		sortOrder = 201,
		grants = { { kind = "NavigationRound", amount = 1 } },
	}
end

local function pass(enabled: boolean): NavigationViewLogic.Item
	return {
		key = "navigation-pass",
		kind = "GamePass",
		enabled = enabled,
		robuxPrice = 899,
		sortOrder = 20,
		grants = {},
		perk = "UnlimitedNavigation",
	}
end

describe("NavigationViewLogic.offered", function()
	it("hides the toggle while nothing is on sale", function()
		expect(NavigationViewLogic.offered({ round(false), coinRound(false), pass(false) })):toBe(false)
	end)

	it("shows it once any round or the pass is", function()
		expect(NavigationViewLogic.offered({ round(false), coinRound(true) })):toBe(true)
		expect(NavigationViewLogic.offered({ pass(true) })):toBe(true)
	end)
end)

describe("NavigationViewLogic.offers", function()
	it("lists Robux first, then coins, and never the pass", function()
		local offers = NavigationViewLogic.offers({ coinRound(true), pass(true), round(true) }, 500)
		expect(#offers):toBe(2)
		expect(offers[1].key):toBe("navigation-round")
		expect(offers[1].label):toBe("99 R$")
		expect(offers[2].key):toBe("navigation-round-coins")
		expect(offers[2].label):toBe("100 coins")
		expect(offers[2].affordable):toBe(true)
	end)

	it("greys out coins the player hasn't got, but still lists them", function()
		local offers = NavigationViewLogic.offers({ round(true), coinRound(true) }, 99)
		expect(offers[1].affordable):toBe(true)
		expect(offers[2].affordable):toBe(false)
	end)

	it("treats an unloaded balance as unaffordable", function()
		local offers = NavigationViewLogic.offers({ coinRound(true) }, nil)
		expect(offers[1].affordable):toBe(false)
	end)

	it("leaves out disabled rounds", function()
		local offers = NavigationViewLogic.offers({ round(false), coinRound(true) }, 500)
		expect(#offers):toBe(1)
		expect(offers[1].coins):toBe(true)
	end)
end)

describe("NavigationViewLogic.read", function()
	it("reads a well-formed payload", function()
		local state = NavigationViewLogic.read({ status = "On", on = true, unlimited = false, roundsHeld = 2 })
		expect(state ~= nil):toBe(true)
		local s = state :: NavigationViewLogic.State
		expect(s.status):toBe("On")
		expect(s.on):toBe(true)
		expect(s.roundsHeld):toBe(2)
	end)

	it("refuses an unknown status or a non-table", function()
		expect(NavigationViewLogic.read({ status = "Maybe" })):toBe(nil)
		expect(NavigationViewLogic.read("On")):toBe(nil)
	end)

	it("defaults missing fields to off", function()
		local s = NavigationViewLogic.read({ status = "NeedsPurchase" }) :: NavigationViewLogic.State
		expect(s.on):toBe(false)
		expect(s.unlimited):toBe(false)
		expect(s.roundsHeld):toBe(0)
	end)
end)

describe("StoreScreenLogic and Navigation", function()
	local function asItem(item: NavigationViewLogic.Item): StoreScreenLogic.Item
		local out = table.clone(item) :: any
		out.displayName = item.key
		out.imageAssetId = 0
		return out
	end

	it("keeps rounds out of every Hub tab", function()
		local items = { asItem(round(true)), asItem(coinRound(true)) }
		for _, category in StoreScreenLogic.CATEGORIES do
			expect(#StoreScreenLogic.itemsIn(items, category, nil)):toBe(0)
		end
	end)

	it("files the perk pass under Bundles, not Season", function()
		local item = asItem(pass(true))
		expect(StoreScreenLogic.categoryOf(item)):toBe("Bundles")
		expect(#StoreScreenLogic.itemsIn({ item }, "Bundles", nil)):toBe(1)
	end)
end)
