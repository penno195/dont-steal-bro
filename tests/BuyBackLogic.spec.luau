--!strict
-- Covers BuyBackLogic.luau: the streak buy-back offer's screen rules
-- (design-decisions.md Q7, "buying back a streak") - reading the offer,
-- when the card opens by itself, when the Hub button shows, the price
-- it quotes, and when a purchase has landed.

local TestRunner = require("./TestRunner")
local BuyBackLogic = require("../src/client/UI/BuyBackLogic")

local offer: BuyBackLogic.Offer = { key = "streak-buy-back-5", streak = 5, robuxPrice = 209 }

TestRunner.describe("BuyBackLogic.read", function()
	TestRunner.it("reads a well-formed offer", function()
		local read = BuyBackLogic.read({ buyBack = { key = "k", streak = 3, robuxPrice = 149 } })
		TestRunner.expect(read and read.streak):toBe(3)
	end)

	TestRunner.it("reads a missing or malformed offer as none", function()
		TestRunner.expect(BuyBackLogic.read(nil) == nil):toBe(true)
		TestRunner.expect(BuyBackLogic.read({}) == nil):toBe(true)
		TestRunner.expect(BuyBackLogic.read({ buyBack = { key = "k", streak = 0, robuxPrice = 99 } }) == nil):toBe(true)
		TestRunner.expect(BuyBackLogic.read({ buyBack = { key = 5, streak = 2, robuxPrice = 99 } }) == nil):toBe(true)
	end)
end)

TestRunner.describe("BuyBackLogic.shouldAutoOpen", function()
	TestRunner.it("opens over the end screen once the streak card has had time", function()
		TestRunner.expect(BuyBackLogic.shouldAutoOpen(offer, "Results", BuyBackLogic.REVEAL_WAIT, nil)):toBe(true)
		TestRunner.expect(BuyBackLogic.shouldAutoOpen(offer, "Results", BuyBackLogic.REVEAL_WAIT - 1, nil)):toBe(false)
	end)

	TestRunner.it("opens only once per offer", function()
		local id = BuyBackLogic.id(offer)
		TestRunner.expect(BuyBackLogic.shouldAutoOpen(offer, "Results", 10, id)):toBe(false)
	end)

	TestRunner.it("never opens by itself anywhere but the end screen", function()
		TestRunner.expect(BuyBackLogic.shouldAutoOpen(offer, nil, 10, nil)):toBe(false)
		TestRunner.expect(BuyBackLogic.shouldAutoOpen(offer, "Store", 10, nil)):toBe(false)
		TestRunner.expect(BuyBackLogic.shouldAutoOpen(nil, "Results", 10, nil)):toBe(false)
	end)
end)

TestRunner.describe("BuyBackLogic.buttonVisible", function()
	TestRunner.it("shows in the Hub with an offer and nothing else up", function()
		TestRunner.expect(BuyBackLogic.buttonVisible(offer, true, nil, "WaitingForPlayers")):toBe(true)
	end)

	TestRunner.it("hides off the Hub, under a menu, mid-round, or with no offer", function()
		TestRunner.expect(BuyBackLogic.buttonVisible(offer, false, nil, "WaitingForPlayers")):toBe(false)
		TestRunner.expect(BuyBackLogic.buttonVisible(offer, true, "Store", "WaitingForPlayers")):toBe(false)
		TestRunner.expect(BuyBackLogic.buttonVisible(offer, true, nil, "Race")):toBe(false)
		TestRunner.expect(BuyBackLogic.buttonVisible(nil, true, nil, "WaitingForPlayers")):toBe(false)
	end)
end)

TestRunner.describe("BuyBackLogic price and text", function()
	TestRunner.it("quotes Roblox's live price, else the config price", function()
		TestRunner.expect(BuyBackLogic.buyLabel(offer, 189)):toBe("Save it for 189 R$")
		TestRunner.expect(BuyBackLogic.buyLabel(offer, nil)):toBe("Save it for 209 R$")
		TestRunner.expect(BuyBackLogic.price(offer, 0)):toBe(209)
	end)

	TestRunner.it("names the streak being saved", function()
		TestRunner.expect(BuyBackLogic.title(offer)):toBe("Save your streak of 5?")
		TestRunner.expect(BuyBackLogic.buttonLabel(offer)):toBe("Save streak 5")
	end)
end)

TestRunner.describe("BuyBackLogic.landed", function()
	TestRunner.it("reports the save when the offer being bought disappears", function()
		TestRunner.expect(BuyBackLogic.landed(offer.key, offer, nil)):toBe("Streak saved: you're back on 5.")
	end)

	TestRunner.it("stays quiet otherwise", function()
		TestRunner.expect(BuyBackLogic.landed(nil, offer, nil) == nil):toBe(true)
		TestRunner.expect(BuyBackLogic.landed("other-key", offer, nil) == nil):toBe(true)
		TestRunner.expect(BuyBackLogic.landed(offer.key, offer, offer) == nil):toBe(true)
	end)
end)
