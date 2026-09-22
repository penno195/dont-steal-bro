--!strict
-- Covers StoreLogic.luau (P4-5): receipt classification, the PurchaseId
-- replay cache, grant application, the loadout cap and its consumption,
-- and the ownership cache's freshness rule. StoreService.luau itself
-- isn't required here - it touches MarketplaceService, Players and the
-- loader at call time, so it's exercised in Studio instead
-- (docs/store-receipts.md), the same split every other spec uses.
--
-- The cases P4-5 asks for by name are all here: a replayed PurchaseId
-- granting nothing a second time, a failed grant, the buyer leaving
-- mid-purchase, and the profile not being loaded yet. The last two
-- reach this module as `profileActive = false` and as a caller that
-- never gets a handle at all - so the second one is a service-level
-- case with a Studio test, and what IS testable here is that the
-- decision it produces never grants twice.

local TestRunner = require("./TestRunner")
local StoreLogic = require("../src/server/StoreLogic")

local function freshState(): StoreLogic.GrantState
	return { currency = 0, powerUpStock = {}, ownedCosmetics = {}, unlockedTitles = {} }
end

TestRunner.describe("StoreLogic.classifyReceipt", function()
	TestRunner.it("grants a new purchase for a known product on an active profile", function()
		TestRunner.expect(StoreLogic.classifyReceipt({}, "p1", true, true)):toBe("Grant")
	end)

	TestRunner.it("treats a nil cache the same as an empty one", function()
		TestRunner.expect(StoreLogic.classifyReceipt(nil, "p1", true, true)):toBe("Grant")
	end)

	TestRunner.it("confirms a replayed PurchaseId without granting", function()
		TestRunner.expect(StoreLogic.classifyReceipt({ "p1" }, "p1", true, true)):toBe("AlreadyGranted")
	end)

	TestRunner.it("confirms a replay even when the product has since been removed", function()
		-- Otherwise a product pulled from the catalogue after somebody
		-- bought it would loop forever on a receipt nothing can satisfy.
		TestRunner.expect(StoreLogic.classifyReceipt({ "p1" }, "p1", true, false)):toBe("AlreadyGranted")
	end)

	TestRunner.it("confirms a replay even after the session has ended", function()
		-- The id being in the SAVED cache is already proof the grant
		-- landed; confirming needs no further write.
		TestRunner.expect(StoreLogic.classifyReceipt({ "p1" }, "p1", false, true)):toBe("AlreadyGranted")
	end)

	TestRunner.it("declines when the buyer's session has ended mid-purchase", function()
		TestRunner.expect(StoreLogic.classifyReceipt({}, "p1", false, true)):toBe("Decline")
	end)

	TestRunner.it("declines an unknown product rather than consuming the purchase", function()
		-- The "robs players" half of P4-5's framing: confirming here
		-- would take the money and hand over nothing, permanently.
		TestRunner.expect(StoreLogic.classifyReceipt({}, "p1", true, false)):toBe("Decline")
	end)

	TestRunner.it("does not confuse two different purchases of the same product", function()
		TestRunner.expect(StoreLogic.classifyReceipt({ "p1" }, "p2", true, true)):toBe("Grant")
	end)
end)

TestRunner.describe("StoreLogic.recordPurchaseId", function()
	TestRunner.it("appends to a copy, never mutating the input", function()
		local original = { "a" }
		local updated = StoreLogic.recordPurchaseId(original, "b", 10)
		TestRunner.expect(#original):toBe(1)
		TestRunner.expect(#updated):toBe(2)
		TestRunner.expect(updated[2]):toBe("b")
	end)

	TestRunner.it("handles a nil cache", function()
		local updated = StoreLogic.recordPurchaseId(nil, "a", 10)
		TestRunner.expect(#updated):toBe(1)
		TestRunner.expect(updated[1]):toBe("a")
	end)

	TestRunner.it("is idempotent for an id it already holds", function()
		local updated = StoreLogic.recordPurchaseId({ "a", "b" }, "b", 10)
		TestRunner.expect(#updated):toBe(2)
	end)

	TestRunner.it("trims oldest-first at the cap", function()
		local cache: { string } = {}
		for index = 1, 6 do
			cache = StoreLogic.recordPurchaseId(cache, string.format("p%d", index), 3)
		end
		TestRunner.expect(#cache):toBe(3)
		TestRunner.expect(cache[1]):toBe("p4")
		TestRunner.expect(cache[3]):toBe("p6")
	end)

	TestRunner.it("keeps at least one entry even at a nonsense cap", function()
		local cache = StoreLogic.recordPurchaseId({}, "p1", 0)
		TestRunner.expect(#cache):toBe(1)
	end)

	TestRunner.it("a trimmed-out id is no longer recognised - the design's one real limit", function()
		local cache: { string } = {}
		for index = 1, 4 do
			cache = StoreLogic.recordPurchaseId(cache, string.format("p%d", index), 2)
		end
		-- p1 has fallen out of the window, so a re-offer of it would be
		-- granted again. This is the behaviour GameConfig.store.
		-- purchaseIdCacheSize (100) and Validate.checkStoreConfig's
		-- minimum of 10 exist to keep out of reach.
		TestRunner.expect(StoreLogic.classifyReceipt(cache, "p1", true, true)):toBe("Grant")
		TestRunner.expect(StoreLogic.classifyReceipt(cache, "p4", true, true)):toBe("AlreadyGranted")
	end)
end)

TestRunner.describe("StoreLogic.isPurchaseSaved", function()
	TestRunner.it("is false for a profile with nothing saved yet", function()
		TestRunner.expect(StoreLogic.isPurchaseSaved(nil, "p1")):toBe(false)
	end)

	TestRunner.it("is false when the saved cache does not hold the id", function()
		TestRunner.expect(StoreLogic.isPurchaseSaved({ "other" }, "p1")):toBe(false)
	end)

	TestRunner.it("is true only once the id is in the saved snapshot", function()
		TestRunner.expect(StoreLogic.isPurchaseSaved({ "other", "p1" }, "p1")):toBe(true)
	end)
end)

TestRunner.describe("StoreLogic.applyGrants", function()
	TestRunner.it("adds currency", function()
		local after = StoreLogic.applyGrants(freshState(), { { kind = "Currency", amount = 500 } })
		TestRunner.expect(after.currency):toBe(500)
	end)

	TestRunner.it("accumulates power-up stock across repeat purchases", function()
		local state = freshState()
		for _ = 1, 3 do
			state = StoreLogic.applyGrants(state, { { kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 5 } })
		end
		TestRunner.expect(state.powerUpStock["sprint-boost"]):toBe(15)
	end)

	TestRunner.it("never mutates the state handed in", function()
		local before = freshState()
		StoreLogic.applyGrants(before, { { kind = "Currency", amount = 100 } })
		TestRunner.expect(before.currency):toBe(0)
	end)

	TestRunner.it("treats a cosmetic grant as a set insertion, so re-applying is a no-op", function()
		-- This is what makes a game pass's grants safe to re-apply on
		-- every join without a receipt of its own.
		local state = StoreLogic.applyGrants(freshState(), { { kind = "Cosmetic", cosmeticId = "skin-founder" } })
		local again = StoreLogic.applyGrants(state, { { kind = "Cosmetic", cosmeticId = "skin-founder" } })
		TestRunner.expect(#again.ownedCosmetics):toBe(1)
	end)

	TestRunner.it("reports an unchanged cosmetic rather than staying silent", function()
		local state = StoreLogic.applyGrants(freshState(), { { kind = "Cosmetic", cosmeticId = "skin-founder" } })
		local _, lines = StoreLogic.applyGrants(state, { { kind = "Cosmetic", cosmeticId = "skin-founder" } })
		TestRunner.expect(#lines):toBe(1)
		TestRunner.expect(string.find(lines[1], "already owned", 1, true) ~= nil):toBe(true)
	end)

	TestRunner.it("titles are append-only too", function()
		local state = StoreLogic.applyGrants(freshState(), { { kind = "Title", titleId = "got-one" } })
		local again = StoreLogic.applyGrants(state, { { kind = "Title", titleId = "got-one" } })
		TestRunner.expect(#again.unlockedTitles):toBe(1)
	end)

	TestRunner.it("applies a multi-grant bundle in full", function()
		local after, lines = StoreLogic.applyGrants(freshState(), {
			{ kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 5 },
			{ kind = "PowerUpStock", powerUpId = "slow-field", amount = 5 },
			{ kind = "Currency", amount = 100 },
		})
		TestRunner.expect(after.powerUpStock["sprint-boost"]):toBe(5)
		TestRunner.expect(after.powerUpStock["slow-field"]):toBe(5)
		TestRunner.expect(after.currency):toBe(100)
		TestRunner.expect(#lines):toBe(3)
	end)

	TestRunner.it("skips a malformed grant without dropping the good ones beside it", function()
		-- Never rob a player: one bad line in a config must not abort a
		-- purchase that also contained valid grants.
		local after, lines = StoreLogic.applyGrants(freshState(), {
			{ kind = "Currency" }, -- no amount
			{ kind = "Currency", amount = 250 },
		})
		TestRunner.expect(after.currency):toBe(250)
		TestRunner.expect(string.find(lines[1], "SKIPPED", 1, true) ~= nil):toBe(true)
	end)

	TestRunner.it("skips an unrecognised grant kind rather than erroring", function()
		local after, lines = StoreLogic.applyGrants(freshState(), { { kind = "Sorcery" :: any } })
		TestRunner.expect(after.currency):toBe(0)
		TestRunner.expect(string.find(lines[1], "unrecognised", 1, true) ~= nil):toBe(true)
	end)
end)

TestRunner.describe("StoreLogic.setLoadoutSlot - design-decisions.md Q8's 3-item cap", function()
	local ELIGIBLE: { [string]: boolean } = { ["sprint-boost"] = true, ["slow-field"] = true, ["freeze"] = false }
	local STOCK: { [string]: number } = { ["sprint-boost"] = 10, ["slow-field"] = 1, ["freeze"] = 5 }

	TestRunner.it("fills the three slots", function()
		local loadout: { string } = {}
		for slot = 1, 3 do
			local updated = StoreLogic.setLoadoutSlot(loadout, slot, "sprint-boost", STOCK, ELIGIBLE, 3)
			TestRunner.expect(updated ~= nil):toBe(true)
			loadout = updated :: { string }
		end
		TestRunner.expect(#loadout):toBe(3)
	end)

	TestRunner.it("refuses a fourth slot regardless of stock", function()
		local loadout = { "sprint-boost", "sprint-boost", "sprint-boost" }
		local updated, reason = StoreLogic.setLoadoutSlot(loadout, 4, "sprint-boost", STOCK, ELIGIBLE, 3)
		TestRunner.expect(updated):toBe(nil)
		TestRunner.expect(string.find(reason :: string, "outside 1..3", 1, true) ~= nil):toBe(true)
	end)

	TestRunner.it("refuses slot 0 and a fractional slot", function()
		TestRunner.expect((StoreLogic.setLoadoutSlot({}, 0, "sprint-boost", STOCK, ELIGIBLE, 3))):toBe(nil)
		TestRunner.expect((StoreLogic.setLoadoutSlot({}, 1.5, "sprint-boost", STOCK, ELIGIBLE, 3))):toBe(nil)
	end)

	TestRunner.it("refuses an item the player has no stock of", function()
		local updated, reason = StoreLogic.setLoadoutSlot({}, 1, "blind", STOCK, ELIGIBLE, 3)
		TestRunner.expect(updated):toBe(nil)
		TestRunner.expect(string.find(reason :: string, "not loadout-eligible", 1, true) ~= nil):toBe(true)
	end)

	TestRunner.it("refuses a field-pickup-only item even with stock", function()
		local updated, reason = StoreLogic.setLoadoutSlot({}, 1, "freeze", STOCK, ELIGIBLE, 3)
		TestRunner.expect(updated):toBe(nil)
		TestRunner.expect(string.find(reason :: string, "not loadout-eligible", 1, true) ~= nil):toBe(true)
	end)

	TestRunner.it("refuses to place more copies than the player owns", function()
		-- They own one Slow Field. Two slots of it would spend one they
		-- never had.
		local first = StoreLogic.setLoadoutSlot({}, 1, "slow-field", STOCK, ELIGIBLE, 3) :: { string }
		local second, reason = StoreLogic.setLoadoutSlot(first, 2, "slow-field", STOCK, ELIGIBLE, 3)
		TestRunner.expect(second):toBe(nil)
		TestRunner.expect(string.find(reason :: string, "only 1", 1, true) ~= nil):toBe(true)
	end)

	TestRunner.it("allows replacing an item in its own slot", function()
		local loadout = { "slow-field" }
		local updated = StoreLogic.setLoadoutSlot(loadout, 1, "slow-field", STOCK, ELIGIBLE, 3)
		TestRunner.expect(updated ~= nil):toBe(true)
		TestRunner.expect(#(updated :: { string })):toBe(1)
	end)

	TestRunner.it("clears a slot with a nil id", function()
		local loadout = { "sprint-boost", "slow-field" }
		local updated = StoreLogic.setLoadoutSlot(loadout, 1, nil, STOCK, ELIGIBLE, 3) :: { string }
		TestRunner.expect(#updated):toBe(1)
		TestRunner.expect(updated[1]):toBe("slow-field")
	end)

	TestRunner.it("appends rather than leaving a hole when a later slot is assigned first", function()
		local updated = StoreLogic.setLoadoutSlot({}, 3, "sprint-boost", STOCK, ELIGIBLE, 3) :: { string }
		TestRunner.expect(#updated):toBe(1)
	end)

	TestRunner.it("trims an over-cap stored loadout on read, not just on write", function()
		-- A profile written before the cap changed must not keep four.
		local oversized = { "sprint-boost", "sprint-boost", "sprint-boost", "sprint-boost" }
		local updated = StoreLogic.setLoadoutSlot(oversized, 1, nil, STOCK, ELIGIBLE, 3) :: { string }
		TestRunner.expect(#updated):toBe(2)
	end)

	TestRunner.it("never mutates the loadout handed in", function()
		local loadout = { "sprint-boost" }
		StoreLogic.setLoadoutSlot(loadout, 1, nil, STOCK, ELIGIBLE, 3)
		TestRunner.expect(#loadout):toBe(1)
	end)
end)

TestRunner.describe("StoreLogic.consumeLoadout", function()
	TestRunner.it("spends one of each item taken", function()
		local granted, remaining = StoreLogic.consumeLoadout(
			{ "sprint-boost", "slow-field" },
			{ ["sprint-boost"] = 3, ["slow-field"] = 2 },
			3
		)
		TestRunner.expect(#granted):toBe(2)
		TestRunner.expect(remaining["sprint-boost"]):toBe(2)
		TestRunner.expect(remaining["slow-field"]):toBe(1)
	end)

	TestRunner.it("spends three copies of one item from stock of three", function()
		local granted, remaining = StoreLogic.consumeLoadout(
			{ "sprint-boost", "sprint-boost", "sprint-boost" },
			{ ["sprint-boost"] = 3 },
			3
		)
		TestRunner.expect(#granted):toBe(3)
		TestRunner.expect(remaining["sprint-boost"]):toBe(nil) -- cleared, not left at 0
	end)

	TestRunner.it("drops an entry with no stock behind it rather than granting on credit", function()
		local granted = StoreLogic.consumeLoadout({ "sprint-boost", "blind" }, { ["sprint-boost"] = 1 }, 3)
		TestRunner.expect(#granted):toBe(1)
		TestRunner.expect(granted[1]):toBe("sprint-boost")
	end)

	TestRunner.it("honours the cap even if the stored loadout is longer", function()
		local granted = StoreLogic.consumeLoadout({ "sprint-boost", "sprint-boost", "sprint-boost", "sprint-boost" }, {
			["sprint-boost"] = 10,
		}, 3)
		TestRunner.expect(#granted):toBe(3)
	end)

	TestRunner.it("never mutates the stock handed in", function()
		local stock = { ["sprint-boost"] = 3 }
		StoreLogic.consumeLoadout({ "sprint-boost" }, stock, 3)
		TestRunner.expect(stock["sprint-boost"]):toBe(3)
	end)

	TestRunner.it("an empty loadout spends nothing", function()
		local granted, remaining = StoreLogic.consumeLoadout({}, { ["sprint-boost"] = 3 }, 3)
		TestRunner.expect(#granted):toBe(0)
		TestRunner.expect(remaining["sprint-boost"]):toBe(3)
	end)
end)

TestRunner.describe("StoreLogic.isOwnershipFresh", function()
	TestRunner.it("a cache miss is never fresh", function()
		TestRunner.expect(StoreLogic.isOwnershipFresh(nil, true, 100, 3600, 60)):toBe(false)
	end)

	TestRunner.it("holds a positive answer for the long TTL", function()
		TestRunner.expect(StoreLogic.isOwnershipFresh(0, true, 3000, 3600, 60)):toBe(true)
	end)

	TestRunner.it("expires a negative answer on the short TTL, while the positive one is still fresh", function()
		-- The asymmetry that matters: the player who JUST bought is the
		-- one waiting on this.
		TestRunner.expect(StoreLogic.isOwnershipFresh(0, false, 90, 3600, 60)):toBe(false)
		TestRunner.expect(StoreLogic.isOwnershipFresh(0, true, 90, 3600, 60)):toBe(true)
	end)

	TestRunner.it("is exclusive at the boundary", function()
		TestRunner.expect(StoreLogic.isOwnershipFresh(0, false, 60, 3600, 60)):toBe(false)
	end)
end)

TestRunner.describe("StoreLogic.canEquipCosmetic", function()
	TestRunner.it("allows an owned item", function()
		TestRunner.expect((StoreLogic.canEquipCosmetic({ "skin-founder" }, "skin", "skin-founder"))):toBe(true)
	end)

	TestRunner.it("refuses an item the profile does not own", function()
		local ok, reason = StoreLogic.canEquipCosmetic({}, "skin", "skin-founder")
		TestRunner.expect(ok):toBe(false)
		TestRunner.expect(string.find(reason :: string, "not owned", 1, true) ~= nil):toBe(true)
	end)

	TestRunner.it("always allows unequipping", function()
		TestRunner.expect((StoreLogic.canEquipCosmetic({}, "skin", nil))):toBe(true)
	end)

	TestRunner.it("refuses an empty slot name", function()
		TestRunner.expect((StoreLogic.canEquipCosmetic({ "skin-founder" }, "", "skin-founder"))):toBe(false)
	end)
end)

TestRunner.describe("StoreLogic.formatGrantAudit", function()
	TestRunner.it("carries everything a support ticket needs in one line", function()
		local line =
			StoreLogic.formatGrantAudit("Ada", 42, "currency-small", 123456, "abc-def", { "currency +500 (now 500)" })
		for _, needle in { "Ada", "42", "currency-small", "123456", "abc-def", "currency +500" } do
			TestRunner.expect(string.find(line, needle, 1, true) ~= nil):toBe(true)
		end
	end)

	TestRunner.it("says so plainly when a grant changed nothing", function()
		local line = StoreLogic.formatGrantAudit("Ada", 42, "founder-pass", 1, nil, {})
		TestRunner.expect(string.find(line, "nothing changed", 1, true) ~= nil):toBe(true)
		TestRunner.expect(string.find(line, "n/a", 1, true) ~= nil):toBe(true)
	end)
end)
