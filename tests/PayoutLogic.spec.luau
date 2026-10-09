--!strict
-- PayoutLogic: how a win's payout is parsed and worded, for the Decision
-- Studio's reveal and the results screen alike (rewards-roadmap.md
-- step 3).

local PayoutLogic = require("../src/client/UI/PayoutLogic")
local TestRunner = require("./TestRunner")

local describe = TestRunner.describe
local it = TestRunner.it
local expect = TestRunner.expect

local NAMES: { [string]: string } = { ["freeze"] = "Freeze", ["projectile-rubber-duck"] = "Rubber Duck" }
local function nameOf(_kind: string, id: string): string?
	return NAMES[id]
end

local function payout(drop: { [string]: any }?, dropAmount: number?): PayoutLogic.Payout
	return PayoutLogic.parse({ currency = 110, rung = 2, drop = drop, dropAmount = dropAmount }) :: PayoutLogic.Payout
end

describe("PayoutLogic.parse", function()
	it("reads a whole payout", function()
		local p = payout({ kind = "PowerUp", id = "freeze", rarity = "Common", duplicate = false }, 2)
		expect(p.currency):toBe(110)
		expect(p.rung):toBe(2)
		expect((p.drop :: PayoutLogic.Drop).id):toBe("freeze")
		expect(p.dropAmount):toBe(2)
	end)

	it("rejects anything without coins and a rung", function()
		expect(PayoutLogic.parse(nil)):toBe(nil)
		expect(PayoutLogic.parse({ currency = "lots", rung = 1 })):toBe(nil)
		expect(PayoutLogic.parse({ currency = 10 })):toBe(nil)
	end)

	it("drops a malformed drop rather than half-showing it", function()
		local p = payout({ kind = "PowerUp", rarity = "Common" })
		expect(p.drop):toBe(nil)
		expect(p.currency):toBe(110)
	end)
end)

describe("PayoutLogic wording", function()
	it("words coins alone", function()
		local p = payout(nil)
		expect(PayoutLogic.coinsLine(p)):toBe("+110 coins")
		expect(PayoutLogic.dropLine(p, nameOf)):toBe(nil)
		expect(PayoutLogic.summary(p, nameOf)):toBe("+110 coins")
	end)

	it("names a power-up drop, with its count when more than one", function()
		local two = payout({ kind = "PowerUp", id = "freeze", rarity = "Common", duplicate = false }, 2)
		expect(PayoutLogic.dropLine(two, nameOf)):toBe("2x Freeze")
		local one = payout({ kind = "PowerUp", id = "freeze", rarity = "Common", duplicate = false }, 1)
		expect(PayoutLogic.dropLine(one, nameOf)):toBe("Freeze")
		expect(PayoutLogic.summary(two, nameOf)):toBe("+110 coins · Common drop: 2x Freeze")
	end)

	it("names a new cosmetic, and says what an owned one paid instead", function()
		local fresh = payout({ kind = "Cosmetic", id = "projectile-rubber-duck", rarity = "Rare", duplicate = false })
		expect(PayoutLogic.dropLine(fresh, nameOf)):toBe("Rubber Duck")
		local owned =
			payout({ kind = "Cosmetic", id = "projectile-rubber-duck", rarity = "Rare", duplicate = true }, 40)
		expect(PayoutLogic.dropLine(owned, nameOf)):toBe("Rubber Duck - already yours, +40 coins")
		local unknownAmount =
			payout({ kind = "Cosmetic", id = "projectile-rubber-duck", rarity = "Rare", duplicate = true })
		expect(PayoutLogic.dropLine(unknownAmount, nameOf)):toBe("Rubber Duck - already yours, paid in coins")
	end)

	it("falls back to the raw id for a name it doesn't know", function()
		local p = payout({ kind = "Cosmetic", id = "mystery", rarity = "Rare", duplicate = false })
		expect(PayoutLogic.dropLine(p, nameOf)):toBe("mystery")
		expect(PayoutLogic.dropLine(p, nil)):toBe("mystery")
	end)

	it("labels by rarity and picks the item's own icon", function()
		local powerUp = { kind = "PowerUp", id = "freeze", rarity = "Uncommon", duplicate = false }
		expect(PayoutLogic.dropLabel(powerUp)):toBe("Uncommon drop")
		expect(PayoutLogic.dropIcon(powerUp)):toBe("freeze")
		expect(PayoutLogic.dropIcon({ kind = "Cosmetic", id = "x", rarity = "Rare", duplicate = false })):toBe("gem")
	end)
end)

describe("PayoutLogic stakes", function()
	local raw = { soleStealer = 275, loneSharer = 55, allShare = 27, dropChance = 0.3 }

	it("reads a whole stakes packet", function()
		local s = PayoutLogic.parseStakes(raw) :: PayoutLogic.Stakes
		expect(s.soleStealer):toBe(275)
		expect(s.dropChance):toBeCloseTo(0.3)
	end)

	it("rejects a packet missing any number", function()
		expect(PayoutLogic.parseStakes(nil)):toBe(nil)
		expect(PayoutLogic.parseStakes({ soleStealer = 250, loneSharer = 50, allShare = 25 })):toBe(nil)
		expect(PayoutLogic.parseStakes({ soleStealer = "250", loneSharer = 50, allShare = 25, dropChance = 0.1 })):toBe(
			nil
		)
	end)

	it("clamps the drop chance into 0..1", function()
		local s =
			PayoutLogic.parseStakes({ soleStealer = 1, loneSharer = 1, allShare = 1, dropChance = 3 }) :: PayoutLogic.Stakes
		expect(s.dropChance):toBe(1)
	end)

	it("words Steal and Share", function()
		local s = PayoutLogic.parseStakes(raw) :: PayoutLogic.Stakes
		local steal = PayoutLogic.stakesCopy(s, "Steal")
		expect(steal.amount):toBe("275")
		expect(steal.caption):toBe("only if both share")
		local share = PayoutLogic.stakesCopy(s, "Share")
		expect(share.amount):toBe("27")
		expect(share.caption):toBe("55 if both steal")
	end)

	it("rounds the drop chance to a whole percent", function()
		local s = PayoutLogic.parseStakes(raw) :: PayoutLogic.Stakes
		expect(PayoutLogic.dropChanceLine(s)):toBe("30% item drop")
		local low =
			PayoutLogic.parseStakes({ soleStealer = 1, loneSharer = 1, allShare = 1, dropChance = 0.1 }) :: PayoutLogic.Stakes
		expect(PayoutLogic.dropChanceLine(low)):toBe("10% item drop")
	end)
end)
