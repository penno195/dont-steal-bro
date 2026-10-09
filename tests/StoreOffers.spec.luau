--!strict
-- Covers src/shared/StoreOffers.luau: sale windows, launch offers that
-- replace a full-price item, plinth slots and the "was" price
-- (design-decisions.md Q1, 2026-10-09).

local TestRunner = require("./TestRunner")
local StoreOffers = require("../src/shared/StoreOffers")

local T = StoreOffers.parseUtcTime

local function item(key: string, extra: { [string]: any }?): { [string]: any }
	local def: { [string]: any } = { key = key, kind = "DeveloperProduct", enabled = true, robuxPrice = 199 }
	for k, v in extra or {} do
		def[k] = v
	end
	return def
end

local function catalogue(...: { [string]: any }): { { fileName: string, def: { [string]: any } } }
	local list = {}
	for _, def in { ... } do
		table.insert(list, { fileName = def.key .. ".luau", def = def })
	end
	return list
end

TestRunner.describe("StoreOffers.parseUtcTime", function()
	TestRunner.it("reads a UTC date and time", function()
		TestRunner.expect(T("1970-01-02 01:30")):toBe(86400 + 3600 + 1800)
		TestRunner.expect(T("2026-10-09 00:00")):toBe(1791504000)
	end)

	TestRunner.it("refuses anything else", function()
		TestRunner.expect(T("2026-10-09")):toBe(nil)
		TestRunner.expect(T(nil)):toBe(nil)
	end)
end)

TestRunner.describe("StoreOffers.isOnSale", function()
	local def = item("x", { onSaleFrom = "2026-10-10 12:00", onSaleUntil = "2026-11-01 00:00" })

	TestRunner.it("is on sale from the start, up to but not at the end", function()
		TestRunner.expect(StoreOffers.isOnSale(def, T("2026-10-10 11:59") :: number)):toBe(false)
		TestRunner.expect(StoreOffers.isOnSale(def, T("2026-10-10 12:00") :: number)):toBe(true)
		TestRunner.expect(StoreOffers.isOnSale(def, (T("2026-11-01 00:00") :: number) - 1)):toBe(true)
		TestRunner.expect(StoreOffers.isOnSale(def, T("2026-11-01 00:00") :: number)):toBe(false)
	end)

	TestRunner.it("never sells a disabled item, and a bad date counts as closed", function()
		TestRunner.expect(StoreOffers.isOnSale(item("x", { enabled = false }), 0)):toBe(false)
		TestRunner.expect(StoreOffers.isOnSale(item("x", { onSaleUntil = "soon" }), 0)):toBe(false)
		TestRunner.expect(StoreOffers.isOnSale(item("x"), 0)):toBe(true)
	end)
end)

TestRunner.describe("StoreOffers - a launch offer replacing the full price", function()
	local full = item("season-pass")
	local launch =
		item("season-pass-launch", { robuxPrice = 99, replaces = "season-pass", onSaleUntil = "2026-11-01 00:00" })
	local cat = catalogue(full, launch)
	local during = T("2026-10-20 00:00") :: number
	local after = T("2026-11-01 00:00") :: number

	TestRunner.it("sells only the launch offer while it runs", function()
		TestRunner.expect(StoreOffers.isOffered(cat, full, during)):toBe(false)
		TestRunner.expect(StoreOffers.isOffered(cat, launch, during)):toBe(true)
		TestRunner.expect(#StoreOffers.offered(cat, during)):toBe(1)
		TestRunner.expect((StoreOffers.resolve(cat, "season-pass", during) :: any).key):toBe("season-pass-launch")
	end)

	TestRunner.it("puts the full price back on its own when the offer ends", function()
		TestRunner.expect(StoreOffers.isOffered(cat, full, after)):toBe(true)
		TestRunner.expect(StoreOffers.isOffered(cat, launch, after)):toBe(false)
		TestRunner.expect((StoreOffers.resolve(cat, "season-pass", after) :: any).key):toBe("season-pass")
	end)

	TestRunner.it("ignores a disabled launch offer", function()
		local off = item("season-pass-launch", { enabled = false, replaces = "season-pass" })
		TestRunner.expect(StoreOffers.isOffered(catalogue(full, off), full, during)):toBe(true)
	end)

	TestRunner.it("resolves nothing for an item that isn't offered", function()
		TestRunner.expect(StoreOffers.resolve(cat, "nope", during)):toBe(nil)
	end)
end)

TestRunner.describe("StoreOffers.featured", function()
	TestRunner.it("puts each on-sale item on its plinth and leaves the rest empty", function()
		local a = item("a", { featuredSlot = 1, onSaleUntil = "2026-11-01 00:00" })
		local b = item("b", { featuredSlot = 1, onSaleFrom = "2026-11-01 00:00" })
		local c = item("c", { featuredSlot = 3 })
		local cat = catalogue(a, b, c)
		local before = StoreOffers.featured(cat, T("2026-10-20 00:00") :: number)
		TestRunner.expect(before[1].key):toBe("a")
		TestRunner.expect(before[2]):toBe(nil)
		TestRunner.expect(before[3].key):toBe("c")
		TestRunner.expect(StoreOffers.featured(cat, T("2026-11-02 00:00") :: number)[1].key):toBe("b")
	end)

	TestRunner.it("never shows a replaced item", function()
		local full = item("full", { featuredSlot = 2 })
		local launch = item("launch", { replaces = "full" })
		TestRunner.expect(StoreOffers.featured(catalogue(full, launch), 0)[2]):toBe(nil)
	end)
end)

TestRunner.describe("StoreOffers.wasPrice", function()
	TestRunner.it("always shows a coin sale's was price", function()
		TestRunner.expect(StoreOffers.wasPrice({ kind = "CoinOffer", coinPrice = 100, wasPrice = 150 }, nil)):toBe(150)
	end)

	TestRunner.it("shows a Robux was price only if Roblox's live price really is lower", function()
		local def = { kind = "DeveloperProduct", robuxPrice = 99, wasPrice = 199 }
		TestRunner.expect(StoreOffers.wasPrice(def, 99)):toBe(199)
		TestRunner.expect(StoreOffers.wasPrice(def, nil)):toBe(199)
		TestRunner.expect(StoreOffers.wasPrice(def, 199)):toBe(nil) -- dashboard still at full price
	end)

	TestRunner.it("shows nothing without a was price", function()
		TestRunner.expect(StoreOffers.wasPrice({ kind = "CoinOffer", coinPrice = 25 }, nil)):toBe(nil)
	end)
end)
