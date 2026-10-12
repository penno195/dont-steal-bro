--!strict
-- Covers GiftLogic.luau: the staff gift pop-up's rules (staff-tools.md
-- step 3) - reading the Hub's list of unseen gifts, skipping ones
-- already shown, the card's caption and picture, and the heading.

local TestRunner = require("./TestRunner")
local GiftLogic = require("../src/client/UI/GiftLogic")

local function named(id: string): string
	return "Name of " .. id
end

local function gift(id: string, from: string?): GiftLogic.Gift
	return { id = id, from = from or "Penno", kind = "Currency", amount = 1 }
end

TestRunner.describe("GiftLogic.read", function()
	TestRunner.it("reads a well-formed list in order", function()
		local gifts = GiftLogic.read({
			gifts = {
				{ id = "a", from = "Penno", kind = "Currency", amount = 500 },
				{ id = "b", from = "Corvus", kind = "StreakSave", amount = 1 },
			},
		})
		TestRunner.expect(#gifts):toBe(2)
		TestRunner.expect(gifts[1].amount):toBe(500)
		TestRunner.expect(gifts[2].from):toBe("Corvus")
	end)

	TestRunner.it("skips entries with no id, no sender or an unknown kind", function()
		local gifts = GiftLogic.read({
			gifts = {
				{ from = "Penno", kind = "Currency", amount = 1 },
				{ id = "b", kind = "Currency", amount = 1 },
				{ id = "c", from = "Penno", kind = "Streak", amount = 1 },
				{ id = "d", from = "Penno", kind = "Currency", amount = 1 },
			},
		})
		TestRunner.expect(#gifts):toBe(1)
		TestRunner.expect(gifts[1].id):toBe("d")
		TestRunner.expect(#GiftLogic.read(nil)):toBe(0)
		TestRunner.expect(#GiftLogic.read({ gifts = "x" })):toBe(0)
	end)

	TestRunner.it("drops wrongly typed optional fields", function()
		local gifts =
			GiftLogic.read({ gifts = { { id = "a", from = "P", kind = "Cosmetic", amount = "lots", cosmeticId = 7 } } })
		TestRunner.expect(#gifts):toBe(1)
		TestRunner.expect(gifts[1].amount == nil):toBe(true)
		TestRunner.expect(gifts[1].cosmeticId == nil):toBe(true)
	end)
end)

TestRunner.describe("GiftLogic.fresh", function()
	TestRunner.it("drops gifts already shown or waiting", function()
		local left = GiftLogic.fresh({ gift("a"), gift("b"), gift("c") }, { a = true, c = true })
		TestRunner.expect(#left):toBe(1)
		TestRunner.expect(left[1].id):toBe("b")
	end)
end)

TestRunner.describe("GiftLogic.text", function()
	TestRunner.it("captions every kind, singular and plural", function()
		local function text(kind: string, amount: number?, cosmeticId: string?): string
			return GiftLogic.text(
				{ id = "x", from = "P", kind = kind, amount = amount, cosmeticId = cosmeticId },
				named
			)
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
		TestRunner.expect(GiftLogic.storeKey({ id = "x", from = "P", kind = "StreakSave" })):toBe("streak-save")
		TestRunner.expect(GiftLogic.storeKey({ id = "x", from = "P", kind = "UnlimitedNavigation" }))
			:toBe("navigation-pass")
		TestRunner.expect(GiftLogic.storeKey(gift("x")) == nil):toBe(true)
		TestRunner.expect(GiftLogic.icon(gift("x"))):toBe("coin")
	end)
end)

TestRunner.describe("GiftLogic.heading", function()
	TestRunner.it("names the one sender", function()
		local title, body = GiftLogic.heading({ gift("a") })
		TestRunner.expect(title):toBe("GIFT RECEIVED!")
		TestRunner.expect(body):toBe("From Penno")
	end)

	TestRunner.it("counts gifts but names each sender once", function()
		local title, body = GiftLogic.heading({ gift("a"), gift("b"), gift("c", "Corvus") })
		TestRunner.expect(title):toBe("3 GIFTS RECEIVED!")
		TestRunner.expect(body):toBe("From Penno and Corvus")
	end)

	TestRunner.it("shortens a long list of senders", function()
		local _, body = GiftLogic.heading({ gift("1", "A"), gift("2", "B"), gift("3", "C"), gift("4", "D") })
		TestRunner.expect(body):toBe("From A, B and 2 more")
	end)
end)
