--!strict
-- Covers StaffPanelLogic.luau: the staff panel's rules (staff-tools.md
-- step 4) - who sees it, the amount box, the payload it sends (which
-- must be one StaffGrantLogic.checkGift accepts), the summary line, the
-- list orders and reading the server's reply.

local TestRunner = require("./TestRunner")
local StaffPanelLogic = require("../src/client/UI/StaffPanelLogic")
local StaffGrantLogic = require("../src/server/StaffGrantLogic")

local IN_SERVER = { 1, 2, 3 }

local function selection(overrides: { [string]: any }): StaffPanelLogic.Selection
	local s: { [string]: any } = { target = "Player", userId = 2, kind = "Currency", amountText = "500" }
	for k, v in overrides do
		s[k] = v
	end
	return s :: any
end

TestRunner.describe("StaffPanelLogic.KINDS", function()
	TestRunner.it("matches StaffGrantLogic.GIFT_KINDS, in order", function()
		TestRunner.expect(#StaffPanelLogic.KINDS):toBe(#StaffGrantLogic.GIFT_KINDS)
		for i, def in StaffPanelLogic.KINDS do
			TestRunner.expect(def.kind):toBe(StaffGrantLogic.GIFT_KINDS[i])
		end
	end)

	TestRunner.it("has presets only for kinds that take an amount", function()
		for _, def in StaffPanelLogic.KINDS do
			TestRunner.expect(#def.presets > 0):toBe(def.takesAmount)
		end
	end)
end)

TestRunner.describe("StaffPanelLogic.isStaff", function()
	TestRunner.it("is true only for listed user ids", function()
		TestRunner.expect(StaffPanelLogic.isStaff(7, { 5, 7 })):toBe(true)
		TestRunner.expect(StaffPanelLogic.isStaff(8, { 5, 7 })):toBe(false)
		TestRunner.expect(StaffPanelLogic.isStaff(8, {})):toBe(false)
	end)
end)

TestRunner.describe("StaffPanelLogic.parseAmount", function()
	TestRunner.it("reads whole numbers, allowing commas and spaces", function()
		TestRunner.expect(StaffPanelLogic.parseAmount("500")):toBe(500)
		TestRunner.expect(StaffPanelLogic.parseAmount(" 10,000 ")):toBe(10000)
		TestRunner.expect(StaffPanelLogic.parseAmount("2147483647")):toBe(2147483647)
	end)

	TestRunner.it("refuses zero, negatives, decimals, words and too-big numbers", function()
		for _, text in { "", "0", "-5", "1.5", "abc", "5e3", "2147483648" } do
			TestRunner.expect(StaffPanelLogic.parseAmount(text)):toBe(nil)
		end
	end)
end)

TestRunner.describe("StaffPanelLogic.payload", function()
	local cosmeticIds = { HatOne = true }

	local function serverAccepts(payload: { [string]: any })
		local gift = StaffGrantLogic.checkGift(payload.kind, payload.amount, payload.cosmeticId, cosmeticIds)
		TestRunner.expect(gift ~= nil):toBe(true)
		local recipients = StaffGrantLogic.resolveRecipients(payload.target, payload.targetUserId, IN_SERVER)
		TestRunner.expect(recipients ~= nil):toBe(true)
	end

	TestRunner.it("builds a payload the server accepts, for every kind and target", function()
		for _, def in StaffPanelLogic.KINDS do
			for _, target in { "Player", "Server" } do
				local payload = StaffPanelLogic.payload(
					selection({
						target = target,
						userId = if target == "Player" then 2 else nil,
						kind = def.kind,
						amountText = "3",
						cosmeticId = if def.kind == "Cosmetic" then "HatOne" else nil,
					}),
					IN_SERVER
				)
				TestRunner.expect(payload ~= nil):toBe(true)
				serverAccepts(payload :: any)
			end
		end
	end)

	TestRunner.it("leaves out an amount and a cosmetic the kind doesn't take", function()
		local payload = StaffPanelLogic.payload(
			selection({ kind = "UnlimitedNavigation", amountText = "5", cosmeticId = "HatOne" }),
			IN_SERVER
		) :: any
		TestRunner.expect(payload.amount):toBe(nil)
		TestRunner.expect(payload.cosmeticId):toBe(nil)
	end)

	TestRunner.it("leaves out the player for a whole-server gift", function()
		local payload = StaffPanelLogic.payload(selection({ target = "Server", userId = 2 }), IN_SERVER) :: any
		TestRunner.expect(payload.targetUserId):toBe(nil)
	end)

	TestRunner.it("says what's missing", function()
		local unpicked = { target = "Player", kind = "Currency", amountText = "500" } :: any
		local _, noPlayer = StaffPanelLogic.payload(unpicked, IN_SERVER)
		TestRunner.expect(noPlayer):toBe("Pick a player")
		local _, left = StaffPanelLogic.payload(selection({ userId = 9 }), IN_SERVER)
		TestRunner.expect(left):toBe("Pick a player")
		local _, empty = StaffPanelLogic.payload(selection({ target = "Server" }), {})
		TestRunner.expect(empty):toBe("Nobody is in this server")
		local _, badAmount = StaffPanelLogic.payload(selection({ amountText = "0" }), IN_SERVER)
		TestRunner.expect(badAmount):toBe("Enter an amount of at least 1")
		local _, noCosmetic = StaffPanelLogic.payload(selection({ kind = "Cosmetic" }), IN_SERVER)
		TestRunner.expect(noCosmetic):toBe("Pick a cosmetic")
	end)
end)

TestRunner.describe("StaffPanelLogic.summary", function()
	local function name(userId: number): string
		return "Player" .. userId
	end
	local function cosmetic(id: string): string
		return "The " .. id
	end

	TestRunner.it("names the item and the player", function()
		local payload = { target = "Player", targetUserId = 2, kind = "Currency", amount = 500 }
		TestRunner.expect(StaffPanelLogic.summary(payload, name, cosmetic, 3)):toBe("500 coins to Player2")
		local one = { target = "Player", targetUserId = 2, kind = "StreakSave", amount = 1 }
		TestRunner.expect(StaffPanelLogic.summary(one, name, cosmetic, 3)):toBe("1 Streak Save to Player2")
		local hat = { target = "Player", targetUserId = 1, kind = "Cosmetic", cosmeticId = "Hat" }
		TestRunner.expect(StaffPanelLogic.summary(hat, name, cosmetic, 3)):toBe("The Hat to Player1")
	end)

	TestRunner.it("counts a whole-server gift's players", function()
		local payload = { target = "Server", kind = "UnlimitedNavigation" }
		TestRunner.expect(StaffPanelLogic.summary(payload, name, cosmetic, 6))
			:toBe("Unlimited Navigation to everyone here (6)")
	end)
end)

TestRunner.describe("StaffPanelLogic lists", function()
	TestRunner.it("labels a player by display name, adding the username when it differs", function()
		TestRunner.expect(StaffPanelLogic.playerLabel({ userId = 1, displayName = "Pen", name = "penno195" }))
			:toBe("Pen (@penno195)")
		TestRunner.expect(StaffPanelLogic.playerLabel({ userId = 1, displayName = "Pen", name = "Pen" })):toBe("Pen")
	end)

	TestRunner.it("sorts players by display name, ignoring case, without touching the input", function()
		local input = {
			{ userId = 1, displayName = "zed", name = "z" },
			{ userId = 2, displayName = "Amy", name = "b" },
			{ userId = 3, displayName = "amy", name = "a" },
		}
		local sorted = StaffPanelLogic.sortPlayers(input)
		TestRunner.expect(sorted[1].userId):toBe(3)
		TestRunner.expect(sorted[2].userId):toBe(2)
		TestRunner.expect(sorted[3].userId):toBe(1)
		TestRunner.expect(input[1].userId):toBe(1)
	end)

	TestRunner.it("sorts cosmetics by category, then name", function()
		local sorted = StaffPanelLogic.sortCosmetics({
			{ id = "c", name = "Beta", category = "Trail" },
			{ id = "b", name = "beta", category = "Hat" },
			{ id = "a", name = "Alpha", category = "Hat" },
		})
		TestRunner.expect(sorted[1].id):toBe("a")
		TestRunner.expect(sorted[2].id):toBe("b")
		TestRunner.expect(sorted[3].id):toBe("c")
	end)
end)

TestRunner.describe("StaffPanelLogic.readResult", function()
	TestRunner.it("reads a reply and capitalises its message", function()
		local result = StaffPanelLogic.readResult({ ok = true, message = "gave 5 coins to 1 player" }) :: any
		TestRunner.expect(result.ok):toBe(true)
		TestRunner.expect(result.message):toBe("Gave 5 coins to 1 player")
	end)

	TestRunner.it("drops a malformed reply", function()
		TestRunner.expect(StaffPanelLogic.readResult(nil)):toBe(nil)
		TestRunner.expect(StaffPanelLogic.readResult({ ok = "yes", message = "x" })):toBe(nil)
		TestRunner.expect(StaffPanelLogic.readResult({ ok = true })):toBe(nil)
	end)
end)
