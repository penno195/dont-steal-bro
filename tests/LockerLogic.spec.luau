--!strict
-- Covers the Locker and the queue strip's pure half (LockerLogic): the
-- loadout slots, the stock list, when a tile can be added, what "Same as
-- last round" offers, and how owned cosmetics are listed. The screens
-- themselves are reviewed in Studio (Screens/Locker, QueueController).

local LockerLogic = require("../src/client/UI/LockerLogic")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function state(overrides: { [string]: any }?): LockerLogic.State
	local s: { [string]: any } = {
		powerUpStock = {},
		loadout = {},
		lastLoadout = {},
		ownedCosmetics = {},
		equipped = {},
		loadoutSlots = 3,
	}
	for k, v in overrides or {} do
		s[k] = v
	end
	return s :: any
end

local RARITY = { freeze = "Rare", ["slow-field"] = "Uncommon", ["sprint-boost"] = "Common", blind = "Common" }
local function rarityOf(id: string): string?
	return (RARITY :: any)[id]
end
local function nameOf(id: string): string
	return id
end

describe("LockerLogic.slots", function()
	it("lists every slot, empty ones included, with the stock behind each", function()
		local slots = LockerLogic.slots(state({
			loadout = { "freeze" },
			powerUpStock = { freeze = 4 },
		}))
		expect(#slots):toBe(3)
		expect(slots[1].powerUpId):toBe("freeze")
		expect(slots[1].stock):toBe(4)
		expect(slots[2].powerUpId):toBe(nil)
		expect(slots[3].index):toBe(3)
	end)
end)

describe("LockerLogic.stock", function()
	it("lists owned items rarest first, then by name, and skips zero counts", function()
		local rows = LockerLogic.stock(
			state({ powerUpStock = { ["sprint-boost"] = 2, freeze = 1, blind = 3, ["slow-field"] = 0 } }),
			rarityOf,
			nameOf
		)
		expect(#rows):toBe(3)
		expect(rows[1].powerUpId):toBe("freeze")
		expect(rows[2].powerUpId):toBe("blind")
		expect(rows[3].powerUpId):toBe("sprint-boost")
	end)

	it("counts copies already in the loadout against what is free", function()
		local rows = LockerLogic.stock(
			state({ powerUpStock = { ["sprint-boost"] = 2 }, loadout = { "sprint-boost", "sprint-boost" } }),
			rarityOf,
			nameOf
		)
		expect(rows[1].count):toBe(2)
		expect(rows[1].free):toBe(0)
	end)
end)

describe("LockerLogic.addBlock", function()
	it("allows an add while a slot is open and a copy is free", function()
		local s = state({ powerUpStock = { freeze = 1 } })
		expect(LockerLogic.addBlock(s, LockerLogic.stock(s, rarityOf, nameOf)[1])):toBe(nil)
		expect(LockerLogic.nextSlot(s)):toBe(1)
	end)

	it("says the loadout is full before anything else", function()
		local s = state({
			powerUpStock = { freeze = 1, blind = 5 },
			loadout = { "blind", "blind", "blind" },
		})
		local rows = LockerLogic.stock(s, rarityOf, nameOf)
		expect(LockerLogic.addBlock(s, rows[1])):toBe("LoadoutFull")
	end)

	it("says every copy is placed when the stock is used up", function()
		local s = state({ powerUpStock = { freeze = 1 }, loadout = { "freeze" } })
		expect(LockerLogic.addBlock(s, LockerLogic.stock(s, rarityOf, nameOf)[1])):toBe("AllPlaced")
	end)
end)

describe("LockerLogic.repeatOffer", function()
	it("offers last round's picks with their stock while nothing is picked", function()
		local offer = LockerLogic.repeatOffer(state({
			lastLoadout = { "freeze", "blind" },
			powerUpStock = { blind = 2 },
		}))
		expect(offer ~= nil):toBe(true)
		local entries = offer :: { LockerLogic.RepeatEntry }
		expect(#entries):toBe(2)
		expect(entries[1].stock):toBe(0) -- shown with a red 0, not hidden
		expect(entries[2].stock):toBe(2)
	end)

	it("isn't offered once a loadout is picked", function()
		local offer = LockerLogic.repeatOffer(state({
			lastLoadout = { "blind" },
			loadout = { "blind" },
			powerUpStock = { blind = 2 },
		}))
		expect(offer):toBe(nil)
	end)

	it("isn't offered when nothing from last round is left", function()
		expect(LockerLogic.repeatOffer(state({ lastLoadout = { "freeze" } }))):toBe(nil)
	end)

	it("isn't offered to a player who never used a loadout", function()
		expect(LockerLogic.repeatOffer(state({ powerUpStock = { blind = 2 } }))):toBe(nil)
		expect(LockerLogic.repeatOffer(state({ lastLoadout = nil :: any }))):toBe(nil)
	end)
end)

describe("LockerLogic.cosmetics", function()
	local CATEGORY = { trailA = "Trail", skinB = "Skin", skinA = "Skin", oddOne = "Hologram" }
	local function categoryOf(id: string): string?
		return (CATEGORY :: any)[id]
	end
	local function slotFor(category: string): string?
		return ({ Skin = "skin", Trail = "trail" } :: any)[category]
	end

	it("groups by category order, then name, and marks what's worn", function()
		local rows = LockerLogic.cosmetics(
			state({ ownedCosmetics = { "trailA", "skinB", "skinA" }, equipped = { skin = "skinB" } }),
			categoryOf,
			slotFor,
			nameOf,
			{ "Skin", "Trail" }
		)
		expect(rows[1].cosmeticId):toBe("skinA")
		expect(rows[2].cosmeticId):toBe("skinB")
		expect(rows[2].equipped):toBe(true)
		expect(rows[3].slot):toBe("trail")
		expect(rows[3].equipped):toBe(false)
	end)

	it("drops an id no longer in config, and keeps one with no known slot", function()
		local rows = LockerLogic.cosmetics(
			state({ ownedCosmetics = { "gone", "oddOne" } }),
			categoryOf,
			slotFor,
			nameOf,
			{ "Skin" }
		)
		expect(#rows):toBe(1)
		expect(rows[1].slot):toBe(nil)
		expect(rows[1].equipped):toBe(false)
	end)
end)

describe("LockerLogic.strip", function()
	it("shows the loadout going in, padded to every slot", function()
		local strip = LockerLogic.strip(state({ loadout = { "freeze" }, powerUpStock = { freeze = 2 } }))
		expect(strip.mode):toBe("Set")
		expect(#strip.tiles):toBe(3)
		expect(strip.tiles[1].powerUpId):toBe("freeze")
		expect(strip.tiles[1].stock):toBe(2)
		expect(strip.tiles[2].powerUpId):toBe(nil)
	end)

	it("offers last round's picks, with a 0 where the stock ran out", function()
		local strip = LockerLogic.strip(state({
			lastLoadout = { "freeze", "blind" },
			powerUpStock = { blind = 1 },
		}))
		expect(strip.mode):toBe("Offer")
		expect(strip.tiles[1].stock):toBe(0)
		expect(strip.tiles[2].powerUpId):toBe("blind")
	end)

	it("shows empty slots when there's nothing to take or offer", function()
		local strip = LockerLogic.strip(state())
		expect(strip.mode):toBe("None")
		expect(strip.tiles[3].powerUpId):toBe(nil)
	end)
end)

describe("LockerLogic.titles", function()
	local ladder = {
		{ id = "hot-streak", minStreak = 5 },
		{ id = "got-one", minStreak = 1 },
		{ id = "final-boss", minStreak = 50 },
	}

	it("lists the whole ladder lowest first, marking unlocked, worn and picked", function()
		local rows = LockerLogic.titles(
			state({
				unlockedTitles = { "got-one", "hot-streak" },
				equippedTitle = "got-one",
				wornTitle = "got-one",
			}),
			ladder
		)
		expect(#rows):toBe(3)
		expect(rows[1].titleId):toBe("got-one")
		expect(rows[1].worn):toBe(true)
		expect(rows[1].picked):toBe(true)
		expect(rows[2].unlocked):toBe(true)
		expect(rows[2].worn):toBe(false)
		expect(rows[3].unlocked):toBe(false)
	end)

	it("shows the highest rung as worn when nothing is picked", function()
		local rows = LockerLogic.titles(
			state({ unlockedTitles = { "got-one", "hot-streak" }, wornTitle = "hot-streak" }),
			ladder
		)
		expect(rows[2].worn):toBe(true)
		expect(rows[2].picked):toBe(false)
	end)

	it("treats a missing title list as nothing unlocked", function()
		local rows = LockerLogic.titles(state(), ladder)
		expect(rows[1].unlocked):toBe(false)
	end)
end)

describe("LockerLogic.titleTap", function()
	local function row(overrides: { [string]: any }): LockerLogic.TitleRow
		local r: { [string]: any } =
			{ titleId = "got-one", minStreak = 1, unlocked = true, worn = false, picked = false }
		for k, v in overrides do
			r[k] = v
		end
		return r :: any
	end

	it("wears an unlocked title", function()
		local tap = LockerLogic.titleTap(row({})) :: LockerLogic.TitleTap
		expect(tap.titleId):toBe("got-one")
	end)

	it("un-picks your own pick, back to the highest rung", function()
		local tap = LockerLogic.titleTap(row({ picked = true, worn = true })) :: LockerLogic.TitleTap
		expect(tap ~= nil):toBe(true)
		expect(tap.titleId):toBe(nil)
	end)

	it("picks the auto-worn title explicitly when tapped", function()
		local tap = LockerLogic.titleTap(row({ worn = true })) :: LockerLogic.TitleTap
		expect(tap.titleId):toBe("got-one")
	end)

	it("does nothing for a locked title", function()
		expect(LockerLogic.titleTap(row({ unlocked = false }))):toBe(nil)
	end)
end)
