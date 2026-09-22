--!strict
-- Covers CosmeticLogic.luau (P4-6): slot mapping and the category-aware
-- equip check. CosmeticService.luau itself isn't required here - it
-- touches Players, Instances and RoundService at call time, so it's
-- exercised in Studio, the same split every other spec in this suite
-- uses.

local TestRunner = require("./TestRunner")
local CosmeticLogic = require("../src/server/CosmeticLogic")

local CATALOGUE: { CosmeticLogic.CosmeticDef } = {
	{
		id = "skin-founder",
		category = "Skin",
		displayName = "Founder's Kit",
		description = "",
		rarity = "Rare",
		sortOrder = 1,
		enabled = true,
		shirtAssetId = 111,
		pantsAssetId = 112,
	},
	{
		id = "trail-founder",
		category = "Trail",
		displayName = "Founder's Trail",
		description = "",
		rarity = "Rare",
		sortOrder = 2,
		enabled = true,
		trailTextureAssetId = 113,
		trailColorHex = "#d4af37",
		trailLifetime = 0.6,
	},
	{
		id = "skin-unfinished",
		category = "Skin",
		displayName = "Not Built Yet",
		description = "",
		rarity = "Common",
		sortOrder = 3,
		enabled = false,
		shirtAssetId = 0,
		pantsAssetId = 0,
	},
}

TestRunner.describe("CosmeticLogic.slotFor", function()
	TestRunner.it("maps every category to its own slot", function()
		TestRunner.expect(CosmeticLogic.slotFor("Skin")):toBe("skin")
		TestRunner.expect(CosmeticLogic.slotFor("Trail")):toBe("trail")
		TestRunner.expect(CosmeticLogic.slotFor("Emote")):toBe("emote")
		TestRunner.expect(CosmeticLogic.slotFor("Podium")):toBe("podium")
	end)

	TestRunner.it("returns nil for an unrecognised category", function()
		TestRunner.expect(CosmeticLogic.slotFor("Nonsense")):toBe(nil)
	end)
end)

TestRunner.describe("CosmeticLogic.matchesSlot", function()
	TestRunner.it("matches a category to its own slot", function()
		TestRunner.expect(CosmeticLogic.matchesSlot("Trail", "trail")):toBeTruthy()
	end)

	TestRunner.it("refuses a category in the wrong slot", function()
		TestRunner.expect(CosmeticLogic.matchesSlot("Trail", "skin")):toBeFalsy()
	end)
end)

TestRunner.describe("CosmeticLogic.findById", function()
	TestRunner.it("finds a registered item", function()
		local def = CosmeticLogic.findById(CATALOGUE, "trail-founder")
		TestRunner.expect(def ~= nil):toBeTruthy()
		TestRunner.expect((def :: CosmeticLogic.CosmeticDef).category):toBe("Trail")
	end)

	TestRunner.it("returns nil for an unregistered id", function()
		TestRunner.expect(CosmeticLogic.findById(CATALOGUE, "no-such-item")):toBe(nil)
	end)

	TestRunner.it("returns nil for a nil id", function()
		TestRunner.expect(CosmeticLogic.findById(CATALOGUE, nil)):toBe(nil)
	end)
end)

TestRunner.describe("CosmeticLogic.canApply", function()
	TestRunner.it("always allows unequipping", function()
		local allowed = CosmeticLogic.canApply(CATALOGUE, "skin", nil)
		TestRunner.expect(allowed):toBeTruthy()
	end)

	TestRunner.it("allows a registered, enabled item in its own slot", function()
		local allowed = CosmeticLogic.canApply(CATALOGUE, "trail", "trail-founder")
		TestRunner.expect(allowed):toBeTruthy()
	end)

	TestRunner.it("refuses an item that doesn't exist", function()
		local allowed, reason = CosmeticLogic.canApply(CATALOGUE, "skin", "no-such-item")
		TestRunner.expect(allowed):toBeFalsy()
		TestRunner.expect(reason ~= nil):toBeTruthy()
	end)

	TestRunner.it("refuses an item with no Roblox asset yet", function()
		local allowed = CosmeticLogic.canApply(CATALOGUE, "skin", "skin-unfinished")
		TestRunner.expect(allowed):toBeFalsy()
	end)

	TestRunner.it("refuses a real item aimed at the wrong slot", function()
		-- The gap StoreLogic.canEquipCosmetic alone leaves open: a trail
		-- owned by the player, but the client asks to put it in "skin".
		local allowed, reason = CosmeticLogic.canApply(CATALOGUE, "skin", "trail-founder")
		TestRunner.expect(allowed):toBeFalsy()
		TestRunner.expect(reason ~= nil):toBeTruthy()
	end)
end)
