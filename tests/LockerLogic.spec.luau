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

	it("lists the unowned catalog after what's owned, locked and never worn", function()
		local rows = LockerLogic.cosmetics(
			state({ ownedCosmetics = { "trailA" }, equipped = { skin = "skinB" } }),
			categoryOf,
			slotFor,
			nameOf,
			{ "Skin", "Trail" },
			{ "skinB", "trailA", "skinA", "gone" }
		)
		expect(#rows):toBe(3)
		expect(rows[1].cosmeticId):toBe("trailA")
		expect(rows[1].locked):toBe(false)
		expect(rows[2].cosmeticId):toBe("skinA")
		expect(rows[2].locked):toBe(true)
		expect(rows[3].cosmeticId):toBe("skinB")
		expect(rows[3].equipped):toBe(false)
	end)
end)

describe("LockerLogic.howToGet", function()
	it("names the most direct route, or nothing", function()
		expect(LockerLogic.howToGet({ level = 5, store = true, pass = false, drop = false })):toBe(
			"Reach level 5 to unlock it."
		)
		expect(LockerLogic.howToGet({ store = true, pass = true, drop = true })):toBe("Get it in the Store.")
		expect(LockerLogic.howToGet({ store = false, pass = true, drop = true })):toBe("Win it on the season pass.")
		expect(LockerLogic.howToGet({ store = false, pass = false, drop = true })):toBe(
			"Can drop when you win a round."
		)
		expect(LockerLogic.howToGet({ store = false, pass = false, drop = false })):toBe(nil)
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

	-- A 3-rung streak ladder, then Wins (2 rungs) and StealWins (1 rung).
	local lifetime: { LockerLogic.LifetimeDef } = {
		{ id = "veteran", stat = "Wins", threshold = 50 },
		{ id = "sticky", stat = "StealWins", threshold = 1 },
		{ id = "seen-it", stat = "Wins", threshold = 10 },
	}

	it("lists the lifetime ladders under the streak ladder, each on a fresh row", function()
		local rows = LockerLogic.titles(state({ unlockedTitles = { "seen-it" } }), ladder, lifetime)
		expect(#rows):toBe(6)
		-- Streak fills cells 1-3; cell 4 pads, Wins' header is 5.
		expect(rows[3].order):toBe(3)
		expect(rows[4].titleId):toBe("seen-it")
		expect(rows[4].ladder):toBe("Wins")
		expect(rows[4].order):toBe(6)
		expect(rows[4].unlocked):toBe(true)
		expect(rows[5].titleId):toBe("veteran")
		expect(rows[5].order):toBe(7)
		-- Wins ends at 7; 8 pads, StealWins' header is 9.
		expect(rows[6].titleId):toBe("sticky")
		expect(rows[6].order):toBe(10)
		expect(LockerLogic.titleSpacers(ladder, lifetime)[1]):toBe(4)
		expect(LockerLogic.titleSpacers(ladder, lifetime)[2]):toBe(8)
	end)

	it("heads each lifetime ladder with its count toward the next rung", function()
		local headers = LockerLogic.ladderHeaders(
			state({
				unlockedTitles = { "seen-it", "sticky" },
				lifetimeCounts = { wins = 12, studioVisits = 3, stealWins = 4 },
			}),
			ladder,
			lifetime
		)
		expect(#headers):toBe(2) -- no StudioVisits rungs, no header
		expect(headers[1].stat):toBe("Wins")
		expect(headers[1].order):toBe(5)
		expect(LockerLogic.headerDetail(headers[1])):toBe("12 / 50 wins")
		expect(headers[2].stat):toBe("StealWins")
		expect(LockerLogic.headerDetail(headers[2])):toBe("All 1 earned")
	end)

	it("counts earned rungs when there are no counts (off the Hub)", function()
		local headers = LockerLogic.ladderHeaders(state({ unlockedTitles = { "seen-it" } }), ladder, lifetime)
		expect(headers[1].count):toBe(nil)
		expect(LockerLogic.headerDetail(headers[1])):toBe("1 / 2 earned")
	end)
end)

describe("LockerLogic.titleDetail", function()
	local function row(overrides: { [string]: any }): LockerLogic.TitleRow
		local r: { [string]: any } = {
			titleId = "x",
			ladder = "Streak",
			threshold = 5,
			unlocked = true,
			worn = false,
			picked = false,
			order = 1,
		}
		for k, v in overrides do
			r[k] = v
		end
		return r :: any
	end

	it("words a streak rung", function()
		expect(LockerLogic.titleDetail(row({ unlocked = false }))):toBe("Locked · best streak 5")
		expect(LockerLogic.titleDetail(row({}))):toBe("Streak 5")
	end)

	it("words a lifetime rung, singular at 1", function()
		expect(LockerLogic.titleDetail(row({ ladder = "Wins", threshold = 50, unlocked = false }))):toBe(
			"Locked · 50 wins"
		)
		expect(LockerLogic.titleDetail(row({ ladder = "StealWins", threshold = 1 }))):toBe("1 steal won")
		expect(LockerLogic.titleDetail(row({ ladder = "StudioVisits", threshold = 10 }))):toBe("10 Studio visits")
	end)

	it("says what you're wearing", function()
		expect(LockerLogic.titleDetail(row({ worn = true }))):toBe("✓ Wearing (your highest)")
		expect(LockerLogic.titleDetail(row({ ladder = "Wins", worn = true, picked = true }))):toBe("✓ Wearing")
	end)
end)

describe("LockerLogic.unlockToast", function()
	it("names one title and what earned it", function()
		expect(LockerLogic.unlockToast({ { name = "Veteran", lifetime = { stat = "Wins", threshold = 50 } } })):toBe(
			"New title: Veteran (50 wins). Wear it from the Locker."
		)
		expect(LockerLogic.unlockToast({ { name = "Hot", minStreak = 5 } })):toBe(
			"New title: Hot (best streak 5). Wear it from the Locker."
		)
	end)

	it("counts several, and says nothing for none", function()
		expect(LockerLogic.unlockToast({ { name = "A", minStreak = 1 }, { name = "B", minStreak = 3 } })):toBe(
			"2 new titles! Wear one from the Locker."
		)
		expect(LockerLogic.unlockToast({})):toBe(nil)
	end)

	it("holds through the Studio and its reveal", function()
		expect(LockerLogic.holdsUnlockToast("DecisionStudio", false)):toBe(true)
		expect(LockerLogic.holdsUnlockToast("Qualified", false)):toBe(true)
		expect(LockerLogic.holdsUnlockToast("Results", true)):toBe(true)
		expect(LockerLogic.holdsUnlockToast("Results", false)):toBe(false)
		expect(LockerLogic.holdsUnlockToast(nil, false)):toBe(false)
	end)
end)

describe("LockerLogic.titleTap", function()
	local function row(overrides: { [string]: any }): LockerLogic.TitleRow
		local r: { [string]: any } = {
			titleId = "got-one",
			ladder = "Streak",
			threshold = 1,
			unlocked = true,
			worn = false,
			picked = false,
			order = 1,
		}
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
