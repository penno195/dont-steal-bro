--!strict
-- Covers GiftLogic.luau: the staff gift pop-up's rules (staff-tools.md
-- step 3) - reading the payload, the card's caption and picture, and
-- the heading for one gift or several that waited out a race.

local TestRunner = require("./TestRunner")
local GiftLogic = require("../src/client/UI/GiftLogic")

local function named(id: string): string
	return "Name of " .. id
end

TestRunner.describe("GiftLogic.read", function()
	TestRunner.it("reads a well-formed gift", function()
		local gift = GiftLogic.read({ from = "Penno", kind = "Currency", amount = 500 })
		TestRunner.expect(gift and gift.amount):toBe(500)
		TestRunner.expect(gift and gift.from):toBe("Penno")
	end)

	TestRunner.it("refuses a missing sender or an unknown kind", function()
		TestRunner.expect(GiftLogic.read(nil) == nil):toBe(true)
		TestRunner.expect(GiftLogic.read({ kind = "Currency", amount = 1 }) == nil):toBe(true)
		TestRunner.expect(GiftLogic.read({ from = "Penno", kind = "Streak", amount = 1 }) == nil):toBe(true)
	end)

	TestRunner.it("drops wrongly typed optional fields", function()
		local gift = GiftLogic.read({ from = "Penno", kind = "Cosmetic", amount = "lots", cosmeticId = 7 })
		TestRunner.expect(gift ~= nil):toBe(true)
		TestRunner.expect(gift and gift.amount == nil):toBe(true)
		TestRunner.expect(gift and gift.cosmeticId == nil):toBe(true)
	end)
end)

TestRunner.describe("GiftLogic.text", function()
	TestRunner.it("captions every kind, singular and plural", function()
		local function text(kind: string, amount: number?, cosmeticId: string?): string
			return GiftLogic.text({ from = "P", kind = kind, amount = amount, cosmeticId = cosmeticId }, named)
		end
		TestRunner.expect(text("Currency", 1)):toBe("1 coin")
		TestRunner.expect(text("Currency", 250)):toBe("250 coins")
		TestRunner.expect(text("Cosmetic", nil, "hat")):toBe("Name of hat")
		TestRunner.expect(text("NavigationRound", 3)):toBe("3 Navigation rounds")
		TestRunner.expect(text("UnlimitedNavigation")):toBe("Unlimited Navigation")
		TestRunner.expect(text("StreakSave", 1)):toBe("1 Streak Save")
	end)
end)

TestRunner.describe("GiftLogic pictures", function()
	TestRunner.it("uses store art for Navigation and Streak Saves only", function()
		TestRunner.expect(GiftLogic.storeKey({ from = "P", kind = "StreakSave" })):toBe("streak-save")
		TestRunner.expect(GiftLogic.storeKey({ from = "P", kind = "UnlimitedNavigation" })):toBe("navigation-pass")
		TestRunner.expect(GiftLogic.storeKey({ from = "P", kind = "Currency" }) == nil):toBe(true)
		TestRunner.expect(GiftLogic.icon({ from = "P", kind = "Currency" })):toBe("coin")
	end)
end)

TestRunner.describe("GiftLogic.heading", function()
	local function gift(from: string): GiftLogic.Gift
		return { from = from, kind = "Currency", amount = 1 }
	end

	TestRunner.it("names the one sender", function()
		local title, body = GiftLogic.heading({ gift("Penno") })
		TestRunner.expect(title):toBe("GIFT RECEIVED!")
		TestRunner.expect(body):toBe("From Penno")
	end)

	TestRunner.it("counts gifts but names each sender once", function()
		local title, body = GiftLogic.heading({ gift("Penno"), gift("Penno"), gift("Corvus") })
		TestRunner.expect(title):toBe("3 GIFTS RECEIVED!")
		TestRunner.expect(body):toBe("From Penno and Corvus")
	end)

	TestRunner.it("shortens a long list of senders", function()
		local _, body = GiftLogic.heading({ gift("A"), gift("B"), gift("C"), gift("D") })
		TestRunner.expect(body):toBe("From A, B and 2 more")
	end)
end)
