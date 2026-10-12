--!strict
-- Covers StaffGrantLogic.luau: who is staff, what a gift may be, who it
-- reaches and the audit log (staff-tools.md step 2). StaffService itself
-- touches remotes, profiles and a DataStore, so it's exercised in Studio.

local TestRunner = require("./TestRunner")
local StaffGrantLogic = require("../src/server/StaffGrantLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local COSMETICS = { GoldTrail = true }

describe("StaffGrantLogic.isStaff", function()
	it("is the admin list and nothing else", function()
		expect(StaffGrantLogic.isStaff(7, { 7, 9 })):toBe(true)
		expect(StaffGrantLogic.isStaff(8, { 7, 9 })):toBe(false)
		expect(StaffGrantLogic.isStaff(7, {})):toBe(false)
	end)
end)

describe("StaffGrantLogic.checkGift", function()
	it("accepts each kind in its own shape", function()
		expect((StaffGrantLogic.checkGift("Currency", 500, nil, COSMETICS) :: any).amount):toBe(500)
		expect((StaffGrantLogic.checkGift("Cosmetic", nil, "GoldTrail", COSMETICS) :: any).cosmeticId):toBe("GoldTrail")
		expect((StaffGrantLogic.checkGift("NavigationRound", 1, nil, COSMETICS) :: any).kind):toBe("NavigationRound")
		expect((StaffGrantLogic.checkGift("UnlimitedNavigation", nil, nil, COSMETICS) :: any).kind):toBe(
			"UnlimitedNavigation"
		)
		expect((StaffGrantLogic.checkGift("StreakSave", 3, nil, COSMETICS) :: any).amount):toBe(3)
	end)

	it("never gives a streak or anything off the list", function()
		for _, kind in { "StreakBuyBack", "Streak", "Title", "PowerUpStock", "SeasonPass", 42 } do
			local gift, reason = StaffGrantLogic.checkGift(kind, 1, nil, COSMETICS)
			expect(gift):toBe(nil)
			expect(reason ~= nil):toBe(true)
		end
	end)

	it("has no cap, but wants a whole positive amount", function()
		expect(StaffGrantLogic.checkGift("Currency", 1000000000, nil, COSMETICS) ~= nil):toBe(true)
		for _, amount in { 0, -5, 1.5, 0 / 0, math.huge, "10", nil } do
			expect(StaffGrantLogic.checkGift("Currency", amount, nil, COSMETICS)):toBe(nil)
		end
	end)

	it("refuses an unknown cosmetic", function()
		expect(StaffGrantLogic.checkGift("Cosmetic", nil, "NotARealHat", COSMETICS)):toBe(nil)
		expect(StaffGrantLogic.checkGift("Cosmetic", nil, nil, COSMETICS)):toBe(nil)
	end)

	it("refuses fields a kind doesn't take", function()
		expect(StaffGrantLogic.checkGift("Cosmetic", 2, "GoldTrail", COSMETICS)):toBe(nil)
		expect(StaffGrantLogic.checkGift("UnlimitedNavigation", 1, nil, COSMETICS)):toBe(nil)
		expect(StaffGrantLogic.checkGift("StreakSave", 1, "GoldTrail", COSMETICS)):toBe(nil)
	end)
end)

describe("StaffGrantLogic.toGrants", function()
	it("turns Unlimited Navigation into the profile flag, not a store grant", function()
		local gift = StaffGrantLogic.checkGift("UnlimitedNavigation", nil, nil, COSMETICS) :: StaffGrantLogic.Gift
		local grants, unlimited = StaffGrantLogic.toGrants(gift)
		expect(#grants):toBe(0)
		expect(unlimited):toBe(true)
	end)

	it("passes the rest through as one store grant", function()
		local gift = StaffGrantLogic.checkGift("StreakSave", 2, nil, COSMETICS) :: StaffGrantLogic.Gift
		local grants, unlimited = StaffGrantLogic.toGrants(gift)
		expect(#grants):toBe(1)
		expect(grants[1].kind):toBe("StreakSave")
		expect(grants[1].amount):toBe(2)
		expect(unlimited):toBe(false)
	end)
end)

describe("StaffGrantLogic.describe", function()
	it("reads naturally, singular and plural", function()
		expect(StaffGrantLogic.describe({ kind = "Currency", amount = 1 })):toBe("1 coin")
		expect(StaffGrantLogic.describe({ kind = "StreakSave", amount = 3 })):toBe("3 Streak Saves")
		expect(StaffGrantLogic.describe({ kind = "UnlimitedNavigation" })):toBe("Unlimited Navigation")
	end)
end)

describe("StaffGrantLogic.resolveRecipients", function()
	local SERVER = { 1, 2, 3 }

	it("gives one player in this server", function()
		local recipients = StaffGrantLogic.resolveRecipients("Player", 2, SERVER) :: { number }
		expect(#recipients):toBe(1)
		expect(recipients[1]):toBe(2)
	end)

	it("can't reach a player in another server", function()
		expect(StaffGrantLogic.resolveRecipients("Player", 99, SERVER)):toBe(nil)
		expect(StaffGrantLogic.resolveRecipients("Player", nil, SERVER)):toBe(nil)
	end)

	it("gives everyone in this server, as a copy", function()
		local recipients = StaffGrantLogic.resolveRecipients("Server", nil, SERVER) :: { number }
		expect(#recipients):toBe(3)
		table.insert(recipients, 4)
		expect(#SERVER):toBe(3)
	end)

	it("refuses a whole-server gift naming a player, or an unknown target", function()
		expect(StaffGrantLogic.resolveRecipients("Server", 2, SERVER)):toBe(nil)
		expect(StaffGrantLogic.resolveRecipients("Everyone", nil, SERVER)):toBe(nil)
	end)
end)

describe("StaffGrantLogic.appendAudit", function()
	local function entry(at: number): StaffGrantLogic.AuditEntry
		return {
			at = at,
			staffUserId = 7,
			target = "Server",
			gift = { kind = "Currency", amount = 100 },
			delivered = { 1, 2 },
			failed = {},
		}
	end

	it("appends newest last and caps from the front", function()
		local log = StaffGrantLogic.appendAudit(nil, entry(1), 2)
		log = StaffGrantLogic.appendAudit(log, entry(2), 2)
		log = StaffGrantLogic.appendAudit(log, entry(3), 2)
		expect(#log):toBe(2)
		expect(log[1].at):toBe(2)
		expect(log[2].at):toBe(3)
	end)

	it("drops unreadable stored entries rather than refusing to write", function()
		local log = StaffGrantLogic.appendAudit({ "junk", entry(1) } :: any, entry(2), 10)
		expect(#log):toBe(2)
		log = StaffGrantLogic.appendAudit("not a table", entry(3), 10)
		expect(#log):toBe(1)
	end)
end)
