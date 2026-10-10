--!strict
-- Covers the pure halves of P6-6's four screens: SettingsLogic (shared
-- with the server), StoreScreenLogic, BoardLogic and ResultsLogic. The
-- screens themselves are reviewed on device (docs/menu-screens.md).

local BoardLogic = require("../src/client/UI/BoardLogic")
local CosmeticLogic = require("../src/server/CosmeticLogic")
local Net = require("../src/shared/Net")
local ProgressionLogic = require("../src/server/ProgressionLogic")
local ResultsLogic = require("../src/client/UI/ResultsLogic")
local SettingsLogic = require("../src/shared/SettingsLogic")
local SeasonTrackLogic = require("../src/client/UI/SeasonTrackLogic")
local StoreScreenLogic = require("../src/client/UI/StoreScreenLogic")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

-- ===== SettingsLogic ========================================================

describe("SettingsLogic.sanitize", function()
	it("returns the defaults for anything that isn't a table", function()
		local s = SettingsLogic.sanitize(nil)
		expect(SettingsLogic.equal(s, SettingsLogic.defaults())):toBe(true)
		expect(SettingsLogic.equal(SettingsLogic.sanitize("junk"), SettingsLogic.defaults())):toBe(true)
	end)

	it("clamps and snaps numbers, and rejects NaN", function()
		local s = SettingsLogic.sanitize({ musicVolume = 0.6180339, sfxVolume = 7, hudScale = 0 / 0 })
		expect(s.musicVolume):toBe(0.6)
		expect(s.sfxVolume):toBe(1)
		expect(s.hudScale):toBe(SettingsLogic.defaults().hudScale)
	end)

	it("never lets the HUD shrink below the audited touch-target size", function()
		expect(SettingsLogic.sanitize({ hudScale = 0.7 }).hudScale):toBe(SettingsLogic.HUD_SCALE_MIN)
		expect(SettingsLogic.sanitize({ hudScale = 5 }).hudScale):toBe(SettingsLogic.HUD_SCALE_MAX)
	end)

	it("lets Roblox's text size raise the HUD scale but never lower it", function()
		expect(SettingsLogic.effectiveHudScale(1, "Medium")):toBe(1)
		expect(SettingsLogic.effectiveHudScale(1, "Larger")):toBe(SettingsLogic.SYSTEM_TEXT_SCALE.Larger)
		-- The player's own larger choice wins over a smaller system one.
		expect(SettingsLogic.effectiveHudScale(1.25, "Large")):toBe(1.25)
		-- An enum item added after this was written counts as Medium.
		expect(SettingsLogic.effectiveHudScale(1, "Gigantic")):toBe(1)
	end)

	it("keeps every system text scale inside the audited HUD bounds", function()
		for name, scale in SettingsLogic.SYSTEM_TEXT_SCALE do
			expect(scale >= SettingsLogic.HUD_SCALE_MIN and scale <= SettingsLogic.HUD_SCALE_MAX):toBe(true)
			expect(SettingsLogic.effectiveHudScale(SettingsLogic.HUD_SCALE_MAX, name)):toBe(SettingsLogic.HUD_SCALE_MAX)
		end
	end)

	it("drops unknown keys and wrong types", function()
		local s: any = SettingsLogic.sanitize({ voiceEnabled = "yes", admin = true })
		expect(s.voiceEnabled):toBe(true)
		expect(s.admin):toBe(nil)
	end)
end)

describe("SettingsLogic.apply", function()
	it("changes only the fields in the patch", function()
		local current = SettingsLogic.sanitize({ musicVolume = 0.2 })
		local nextS = SettingsLogic.apply(current, { sfxVolume = 0.35 })
		expect(nextS.musicVolume):toBe(0.2)
		expect(nextS.sfxVolume):toBe(0.35)
	end)

	it("keeps the CURRENT value, not the default, for a malformed field", function()
		local current = SettingsLogic.sanitize({ musicVolume = 0.2, colorBlindMode = true })
		local nextS = SettingsLogic.apply(current, { musicVolume = 0 / 0, colorBlindMode = "on" })
		expect(nextS.musicVolume):toBe(0.2)
		expect(nextS.colorBlindMode):toBe(true)
	end)

	it("survives a non-table patch", function()
		local current = SettingsLogic.defaults()
		expect(SettingsLogic.equal(SettingsLogic.apply(current, 42), current)):toBe(true)
	end)
end)

describe("SettingsIntent schema", function()
	it("accepts every field of a full settings value", function()
		local ok = Net.Remotes.SettingsIntent.schema.validate(SettingsLogic.defaults())
		expect(ok):toBe(true)
	end)

	it("accepts the extremes SettingsLogic allows", function()
		local ok = Net.Remotes.SettingsIntent.schema.validate({
			musicVolume = 0,
			sfxVolume = 1,
			hudScale = SettingsLogic.HUD_SCALE_MAX,
		})
		expect(ok):toBe(true)
	end)

	it("rejects a wrong type", function()
		local ok = Net.Remotes.SettingsIntent.schema.validate({ reducedMotion = 1 })
		expect(ok):toBe(false)
	end)
end)

-- ===== StoreScreenLogic =====================================================

local function item(key: string, kind: string, grants: { any }, enabled: boolean?): StoreScreenLogic.Item
	return {
		key = key,
		kind = kind,
		enabled = if enabled == nil then true else enabled,
		displayName = key,
		robuxPrice = 10,
		sortOrder = 1,
		imageAssetId = 1,
		grants = grants,
	}
end

local function state(overrides: { [string]: any }?): StoreScreenLogic.StoreState
	local s: any = {
		currency = 0,
		powerUpStock = {},
		loadout = {},
		ownedCosmetics = {},
		equipped = {},
		ownedPasses = {},
		loadoutSlots = 3,
	}
	for k, v in overrides or {} do
		s[k] = v
	end
	return s
end

local pass = item("founder-pass", "GamePass", {
	{ kind = "Cosmetic", cosmeticId = "skin-founder" },
	{ kind = "Cosmetic", cosmeticId = "trail-founder" },
})
local coins = item("coins", "DeveloperProduct", { { kind = "Currency", amount = 100 } })
local bundle = item("bundle", "DeveloperProduct", {
	{ kind = "Currency", amount = 50 },
	{ kind = "PowerUpStock", powerUpId = "SprintBoost", amount = 2 },
})

describe("StoreScreenLogic catalogue", function()
	it("files items by what they grant", function()
		expect(StoreScreenLogic.categoryOf(pass)):toBe("Season")
		expect(StoreScreenLogic.categoryOf(coins)):toBe("Currency")
		expect(StoreScreenLogic.categoryOf(bundle)):toBe("Bundles")
	end)

	it("reads as the rarest thing inside, and currency has no rarity", function()
		local rarities: { [string]: string } = { ["skin-founder"] = "Uncommon", ["trail-founder"] = "Rare" }
		local lookup = function(g: StoreScreenLogic.Grant): string?
			return if g.cosmeticId then rarities[g.cosmeticId] else nil
		end
		expect(StoreScreenLogic.rarityOf(pass, lookup)):toBe("Rare")
		expect(StoreScreenLogic.rarityOf(coins, lookup)):toBe(nil)
	end)

	it("gives no state before StoreState arrives", function()
		expect(StoreScreenLogic.itemState(pass, nil)):toBe(nil)
	end)

	it("distinguishes unavailable, buyable, owned and equipped", function()
		local off = item("off", "GamePass", {}, false)
		expect(StoreScreenLogic.itemState(off, state())):toBe("Unavailable")
		expect(StoreScreenLogic.itemState(pass, state())):toBe("Buyable")
		expect(StoreScreenLogic.itemState(pass, state({ ownedPasses = { "founder-pass" } }))):toBe("Owned")
		local wearing = state({ ownedPasses = { "founder-pass" }, equipped = { trail = "trail-founder" } })
		expect(StoreScreenLogic.itemState(pass, wearing)):toBe("Equipped")
	end)

	it("never marks a consumable as owned", function()
		expect(StoreScreenLogic.itemState(coins, state({ ownedPasses = { "coins" } }))):toBe("Buyable")
	end)

	-- The client's slot map is a copy of the server's; an equip sent to
	-- a slot the server doesn't recognise would silently do nothing.
	it("uses the same equip slot as the server for every cosmetic category", function()
		for _, category in
			{
				"Skin",
				"Trail",
				"Emote",
				"Podium",
				"Reveal",
				"Projectile",
				"StreakFlair",
				"Nameplate",
				"CallingCard",
				"Hat",
				"BackItem",
				"NotACategory",
			}
		do
			expect(StoreScreenLogic.slotFor(category)):toBe(CosmeticLogic.slotFor(category))
		end
	end)
end)

describe("StoreScreenLogic purchase flow", function()
	local step = StoreScreenLogic.step

	it("ignores a second tap while a purchase is in flight", function()
		local f = step(StoreScreenLogic.idle(), { type = "Tap", key = "coins", state = state() }, 0)
		f = step(f, { type = "Tap", key = "founder-pass", state = state() }, 0.1)
		expect(f.phase):toBe("Requesting")
		expect(f.key):toBe("coins")
	end)

	it("treats a closed-without-buying prompt as a quiet cancel", function()
		local f = step(StoreScreenLogic.idle(), { type = "Tap", key = "coins", state = state() }, 0)
		f = step(f, { type = "Result", key = "coins", status = "Prompted", message = "" }, 0.2)
		f = step(f, { type = "PromptClosed", key = "coins", purchased = false }, 5)
		expect(f.phase):toBe("Idle")
		expect(f.message):toBe(nil)
	end)

	it("waits on the prompt without a timeout, then succeeds when the grant lands", function()
		local f = step(StoreScreenLogic.idle(), { type = "Tap", key = "coins", state = state() }, 0)
		f = step(f, { type = "Result", key = "coins", status = "Prompted", message = "" }, 0.2)
		f = step(f, { type = "Tick" }, 120)
		expect(f.phase):toBe("Prompted")
		f = step(f, { type = "PromptClosed", key = "coins", purchased = true }, 121)
		expect(f.phase):toBe("Processing")
		f = step(f, { type = "State", state = state({ currency = 100 }) }, 122)
		expect(f.phase):toBe("Succeeded")
	end)

	it("says Delayed, not Failed, when a paid grant is slow - and still succeeds later", function()
		local f = step(StoreScreenLogic.idle(), { type = "Tap", key = "coins", state = state() }, 0)
		f = step(f, { type = "Result", key = "coins", status = "Prompted", message = "" }, 0)
		f = step(f, { type = "PromptClosed", key = "coins", purchased = true }, 1)
		f = step(f, { type = "Tick" }, 1 + StoreScreenLogic.GRANT_WAIT)
		expect(f.phase):toBe("Delayed")
		f = step(f, { type = "State", state = state({ currency = 100 }) }, 60)
		expect(f.phase):toBe("Succeeded")
	end)

	it("recognises a pass by ownership, not by a counter", function()
		local f = step(StoreScreenLogic.idle(), { type = "Tap", key = "founder-pass", state = state() }, 0)
		f = step(f, { type = "Result", key = "founder-pass", status = "Prompted", message = "" }, 0)
		f = step(f, { type = "State", state = state({ ownedPasses = { "founder-pass" } }) }, 3)
		expect(f.phase):toBe("Succeeded")
	end)

	it("shows the server's message on failure, with a fallback when it's empty", function()
		local f = step(StoreScreenLogic.idle(), { type = "Tap", key = "x", state = state() }, 0)
		local failed = step(f, { type = "Result", key = "x", status = "Unavailable", message = "Not today." }, 0)
		expect(failed.phase):toBe("Failed")
		expect(failed.message):toBe("Not today.")
		local fallback = step(f, { type = "Result", key = "x", status = "PromptFailed", message = "" }, 0)
		expect((fallback.message :: string):find("try again") ~= nil):toBe(true)
	end)

	it("times out a request the server never answered", function()
		local f = step(StoreScreenLogic.idle(), { type = "Tap", key = "x", state = state() }, 0)
		f = step(f, { type = "Tick" }, StoreScreenLogic.REQUEST_TIMEOUT - 0.1)
		expect(f.phase):toBe("Requesting")
		f = step(f, { type = "Tick" }, StoreScreenLogic.REQUEST_TIMEOUT)
		expect(f.phase):toBe("Failed")
	end)

	it("ignores a late answer for a purchase it has moved past", function()
		local f = step(StoreScreenLogic.idle(), { type = "Tap", key = "x", state = state() }, 0)
		f = step(f, { type = "Tick" }, 30) -- Failed by timeout
		f = step(f, { type = "Result", key = "x", status = "Prompted", message = "" }, 31)
		expect(f.phase):toBe("Failed")
	end)
end)

-- ===== BoardLogic ===========================================================

local function entries(n: number): { BoardLogic.Entry }
	local out = {}
	for i = 1, n do
		table.insert(out, { rank = i, userId = 1000 + i, bestStreak = 200 - i, displayName = "p" .. i })
	end
	return out
end

describe("BoardLogic.view", function()
	it("is Loading before any broadcast", function()
		expect(BoardLogic.view(nil, 1).phase):toBe("Loading")
	end)

	it("is Empty for the server's Empty status and for a zero-length Fresh list", function()
		expect(BoardLogic.view({ entries = {}, status = "Empty" }, 1).phase):toBe("Empty")
		expect(BoardLogic.view({ entries = {}, status = "Fresh" }, 1).phase):toBe("Empty")
	end)

	it("flags a stale board but still shows it", function()
		local v = BoardLogic.view({ entries = entries(3), status = "Stale" }, 1)
		expect(v.phase):toBe("Ready")
		expect(v.stale):toBe(true)
		expect(#v.rows):toBe(3)
	end)

	it("finds the viewer on the list, and says so when they're off it", function()
		local on = BoardLogic.view({ entries = entries(10), status = "Fresh" }, 1004)
		expect(on.viewer.onList):toBe(true)
		expect(on.viewer.rank):toBe(4)
		local off = BoardLogic.view({ entries = entries(10), status = "Fresh" }, 99)
		expect(off.viewer.onList):toBe(false)
		expect(off.viewer.rank):toBe(nil)
	end)

	it("caps what it lays out at MAX_ROWS", function()
		local v = BoardLogic.view({ entries = entries(250), status = "Fresh" }, 1)
		expect(#v.rows):toBe(BoardLogic.MAX_ROWS)
	end)
end)

describe("BoardLogic.visibleRange", function()
	it("builds only the rows in view plus overscan", function()
		-- 40px rows, 4px gap = 44px pitch; a 440px window from the top
		local first, last = BoardLogic.visibleRange(0, 440, 40, 4, 100, 2)
		expect(first):toBe(1)
		expect(last):toBe(12)
	end)

	it("tracks the scroll position and clamps at the end", function()
		local first, last = BoardLogic.visibleRange(44 * 95, 440, 40, 4, 100, 2)
		expect(first):toBe(94)
		expect(last):toBe(100)
	end)

	it("returns an empty range for an empty list", function()
		local first, last = BoardLogic.visibleRange(0, 440, 40, 4, 0, 2)
		expect(last < first):toBe(true)
	end)

	it("sizes the canvas for every row", function()
		expect(BoardLogic.contentHeight(100, 40, 4)):toBe(100 * 40 + 99 * 4)
		expect(BoardLogic.contentHeight(0, 40, 4)):toBe(0)
	end)
end)

-- ===== ResultsLogic =========================================================

local function recap(reason: string, before: number, after: number, overrides: { [string]: any }?): ResultsLogic.Recap
	local r: any = {
		roundId = "r1",
		reason = reason,
		streakBefore = before,
		streakAfter = after,
		bestStreakBefore = before,
		bestStreakAfter = math.max(before, after),
		reward = nil,
	}
	for k, v in overrides or {} do
		r[k] = v
	end
	return r
end

describe("ResultsLogic.streakChange", function()
	it("agrees with ProgressionLogic on what counts as a win", function()
		for _, reason in
			{
				"QualifiedWin",
				"StudioWinSoleStealer",
				"StudioWinLoneSharer",
				"StudioWinAllShare",
				"StudioLoss",
				"FailedToQualify",
				"ForfeitDisconnect",
			}
		do
			expect(ResultsLogic.isWin(reason)):toBe(ProgressionLogic.isWin(reason :: any))
		end
	end)

	it("classifies up, died, none and new best", function()
		local up = ResultsLogic.streakChange(recap("StudioWinAllShare", 4, 5))
		expect(up.kind):toBe("Up")
		expect(up.newBest):toBe(true)
		expect(ResultsLogic.streakChange(recap("StudioLoss", 7, 0)).kind):toBe("Died")
		expect(ResultsLogic.streakChange(recap("FailedToQualify", 0, 0)).kind):toBe("None")
	end)

	it("names the number of a streak that died", function()
		local change = ResultsLogic.streakChange(recap("StudioLoss", 12, 0))
		expect(ResultsLogic.streakHeadline(change)):toBe("Your 12-win streak ends here")
	end)
end)

describe("ResultsLogic.beats", function()
	local function ids(beats: { ResultsLogic.Beat }): string
		local out = {}
		for _, b in beats do
			table.insert(out, b.id)
		end
		return table.concat(out, ",")
	end

	it("always lands the streak last, with a longer pause before it", function()
		local beats = ResultsLogic.beats(recap("StudioWinSoleStealer", 1, 2, {
			reward = { currency = 110, rung = 1 },
		}))
		expect(ids(beats)):toBe("Placement,Tasks,PowerUps,Finale,Rewards,Streak")
		local n = #beats
		expect(beats[n].at - beats[n - 1].at):toBeCloseTo(ResultsLogic.BEAT_GAP + ResultsLogic.STREAK_PAUSE)
	end)

	it("leaves out the finale and rewards for a non-qualifier", function()
		expect(ids(ResultsLogic.beats(recap("FailedToQualify", 3, 0)))):toBe("Placement,Tasks,PowerUps,Streak")
	end)

	it("shows no rewards for a loss even if a reward is present", function()
		local r = recap("StudioLoss", 3, 0, { reward = { currency = 25, rung = 0 } })
		expect(ids(ResultsLogic.beats(r))):toBe("Placement,Tasks,PowerUps,Finale,Streak")
	end)

	it("gives a win's drop its own beat, after the coins", function()
		local r = recap("StudioWinAllShare", 1, 2, {
			reward = {
				currency = 50,
				rung = 2,
				drop = { kind = "PowerUp", id = "freeze", rarity = "Common", duplicate = false },
				dropAmount = 1,
			},
		})
		expect(ids(ResultsLogic.beats(r))):toBe("Placement,Tasks,PowerUps,Finale,Rewards,Drop,Streak")
	end)

	it("has no streak beat for a spectator with no recap", function()
		expect(ids(ResultsLogic.beats(nil))):toBe("Placement,Tasks,PowerUps")
	end)

	it("reveals by time, and everything at once when skipped", function()
		local beats = ResultsLogic.beats(recap("FailedToQualify", 3, 0))
		expect(ResultsLogic.revealedCount(beats, 0, false)):toBe(1)
		expect(ResultsLogic.revealedCount(beats, ResultsLogic.BEAT_GAP, false)):toBe(2)
		expect(ResultsLogic.revealedCount(beats, 0, true)):toBe(#beats)
	end)
end)

describe("ResultsLogic.placementText", function()
	it("gets the ordinals right", function()
		expect(ResultsLogic.placementText(1, 6)):toBe("1st of 6")
		expect(ResultsLogic.placementText(2, 6)):toBe("2nd of 6")
		expect(ResultsLogic.placementText(3, 6)):toBe("3rd of 6")
		expect(ResultsLogic.placementText(11, 20)):toBe("11th of 20")
		expect(ResultsLogic.placementText(13, 20)):toBe("13th of 20")
		expect(ResultsLogic.placementText(21, 30)):toBe("21st of 30")
		expect(ResultsLogic.placementText(nil, 6)):toBe("Unplaced")
	end)
end)

-- ===== the store's Season tab (rewards step 5b) =============================

describe("StoreScreenLogic.itemsIn (Season tab)", function()
	local s1 = item("s1-pass", "DeveloperProduct", { { kind = "SeasonPass" } })
	local s2 = item("s2-pass", "DeveloperProduct", { { kind = "SeasonPass" } })

	it("offers only the live season's pass", function()
		local here = StoreScreenLogic.itemsIn({ s1, s2 }, "Season", "s2-pass")
		expect(#here):toBe(1)
		expect(here[1].key):toBe("s2-pass")
	end)

	it("offers no pass when no season is running", function()
		expect(#StoreScreenLogic.itemsIn({ s1, s2 }, "Season", nil)):toBe(0)
	end)

	it("shows the pass owned only for the season it was bought in", function()
		expect(StoreScreenLogic.itemState(s1, state({ season = { passSeen = false } }))):toBe("Buyable")
		expect(StoreScreenLogic.itemState(s1, state({ season = { passSeen = true } }))):toBe("Owned")
		expect(StoreScreenLogic.itemState(s1, state({ season = nil }))):toBe("Buyable")
	end)
end)

-- ===== sales and launch offers (Q1, "the featured plinths") ================

describe("StoreScreenLogic sales", function()
	local pass = item("s1-pass", "DeveloperProduct", { { kind = "SeasonPass" } })
	local launch = item("s1-launch", "DeveloperProduct", { { kind = "SeasonPass" } })
	launch.replaces = "s1-pass"
	launch.onSaleUntil = "2026-12-01 00:00"

	it("shows the launch offer in the pass's place while it's on", function()
		local onNow = function(i: StoreScreenLogic.Item)
			return i ~= pass
		end
		local here = StoreScreenLogic.itemsIn({ pass, launch }, "Season", "s1-pass", onNow)
		expect(#here):toBe(1)
		expect(here[1].key):toBe("s1-launch")
	end)

	it("hides the launch offer once it's over, and the pass comes back", function()
		local onNow = function(i: StoreScreenLogic.Item)
			return i == pass
		end
		local here = StoreScreenLogic.itemsIn({ pass, launch }, "Season", "s1-pass", onNow)
		expect(#here):toBe(1)
		expect(here[1].key):toBe("s1-pass")
	end)

	it("keeps a plain disabled item as Coming soon, hides timed ones that are off", function()
		local soon = item("soon", "DeveloperProduct", { { kind = "Currency", amount = 5 } }, false)
		expect(StoreScreenLogic.isListed(soon, false)):toBe(true)
		local limited = item("limited", "DeveloperProduct", { { kind = "Cosmetic", cosmeticId = "x" } }, false)
		limited.onSaleUntil = "2026-11-01 00:00"
		expect(StoreScreenLogic.isListed(limited, false)):toBe(false)
		expect(StoreScreenLogic.isListed(pass, false)):toBe(false) -- enabled, but stood down
		expect(StoreScreenLogic.isListed(pass, true)):toBe(true)
	end)

	it("strikes through the was price only when there is one", function()
		expect(StoreScreenLogic.priceRich(pass, { now = 99, was = 199 })):toBe("R$ 99  <s>R$ 199</s>")
		expect(StoreScreenLogic.priceRich(pass, { now = 199 })):toBe("R$ 199")
		local coins = item("c", "CoinOffer", { { kind = "PowerUpStock", powerUpId = "x" } })
		expect(StoreScreenLogic.priceText(coins, { now = 20, was = 25 })):toBe("20 coins")
	end)
end)

describe("SeasonTrackLogic", function()
	local def: SeasonTrackLogic.SeasonDef = {
		id = "s1",
		displayName = "Season 1",
		passKey = "s1-pass",
		free = {
			{ wins = 3, grant = { kind = "Currency", amount = 100 } },
			{ wins = 10, grant = { kind = "Currency", amount = 250 } },
		},
		premium = {
			{ wins = 0, grant = { kind = "Cosmetic", cosmeticId = "trail" } },
			{ wins = 5, grant = { kind = "Currency", amount = 250 } },
		},
	}
	local function text(grant: SeasonTrackLogic.Grant): string
		return if grant.kind == "Currency" then string.format("%d coins", grant.amount or 0) else grant.cosmeticId or ""
	end
	local function state(overrides: { [string]: any }): SeasonTrackLogic.SeasonState
		local s: { [string]: any } = {
			id = "s1",
			secondsLeft = 10 * 86400,
			passSeen = false,
			freeWins = 4,
			premiumWins = 0,
			freePaid = 1,
			premiumPaid = 0,
		}
		for k, v in overrides do
			s[k] = v
		end
		return s :: any
	end

	it("marks claimed rows, then the next one, then locked", function()
		local view = SeasonTrackLogic.view(def, state({}), text)
		expect(view.free.rows[1].status):toBe("Claimed")
		expect(view.free.rows[2].status):toBe("Next")
		expect(view.free.nextAt):toBe(10)
		expect(view.free.rows[1].text):toBe("100 coins")
	end)

	it("pictures an item by its own art, else its icon", function()
		local view = SeasonTrackLogic.view(def, state({}), text, function(grant)
			return if grant.cosmeticId == "trail" then 42 else nil
		end)
		expect(view.premium.rows[1].image):toBe(42)
		expect(view.premium.rows[2].image):toBe(nil)
		expect(view.premium.rows[2].icon):toBe("coin")
		expect(SeasonTrackLogic.view(def, state({}), text).premium.rows[1].image):toBe(nil)
	end)

	it("shows a power-up reward with that power-up's own icon", function()
		expect(SeasonTrackLogic.iconFor({ kind = "PowerUpStock", powerUpId = "overclock", amount = 2 })):toBe(
			"overclock"
		)
		expect(SeasonTrackLogic.iconFor({ kind = "Cosmetic", cosmeticId = "x" })):toBe("gem")
	end)

	it("locks the whole premium track without the pass", function()
		local view = SeasonTrackLogic.view(def, state({}), text)
		expect(view.premium.locked):toBe(true)
		expect(view.premium.rows[1].status):toBe("Locked")
		expect(view.premium.title):toBe("Premium track · needs the pass")
	end)

	it("opens the premium track once the pass is seen", function()
		local view = SeasonTrackLogic.view(def, state({ passSeen = true, premiumPaid = 1, premiumWins = 2 }), text)
		expect(view.premium.locked):toBe(false)
		expect(view.premium.rows[1].status):toBe("Claimed")
		expect(view.premium.rows[2].status):toBe("Next")
	end)

	it("offers reached, unclaimed items to claim", function()
		local view = SeasonTrackLogic.view(def, state({ freeWins = 12, freePaid = 0 }), text)
		expect(view.free.rows[1].status):toBe("Claimable")
		expect(view.free.rows[2].status):toBe("Claimable")
		expect(view.free.rows[2].index):toBe(2)
		expect(view.free.claimable):toBe(2)
	end)

	it("offers nothing to claim on the pass row until it's bought", function()
		local view = SeasonTrackLogic.view(def, state({ premiumWins = 6 }), text)
		expect(view.premium.rows[1].status):toBe("Locked")
		expect(view.premium.claimable):toBe(0)
		local bought = SeasonTrackLogic.view(def, state({ passSeen = true, premiumWins = 6 }), text)
		expect(bought.premium.rows[1].status):toBe("Claimable")
		expect(bought.premium.claimable):toBe(2)
	end)

	it("names what a claim just paid, pass items first", function()
		local before = state({ passSeen = true, premiumWins = 6, freeWins = 6, freePaid = 0, premiumPaid = 0 })
		local after = state({ passSeen = true, premiumWins = 6, freeWins = 6, freePaid = 1, premiumPaid = 2 })
		local rewards = SeasonTrackLogic.claimedBetween(def, before, after)
		expect(#rewards):toBe(3)
		expect(rewards[1].premium):toBe(true)
		expect(rewards[1].grant.cosmeticId):toBe("trail")
		expect(rewards[3].premium):toBe(false)
		expect(rewards[3].grant.amount):toBe(100)
	end)

	it("pops nothing across seasons, on first load, or with no change", function()
		local s = state({ freePaid = 1 })
		local other = state({ freePaid = 2 })
		other.id = "s2"
		expect(#SeasonTrackLogic.claimedBetween(def, s, other)):toBe(0)
		expect(#SeasonTrackLogic.claimedBetween(def, nil, s)):toBe(0)
		expect(#SeasonTrackLogic.claimedBetween(def, s, s)):toBe(0)
	end)

	it("has no next item once a track is fully claimed", function()
		local view = SeasonTrackLogic.view(def, state({ freeWins = 12, freePaid = 2 }), text)
		expect(view.free.nextAt):toBe(nil)
		expect(view.free.rows[2].status):toBe("Claimed")
	end)

	it("lines the tracks up as tiers, fewest wins first", function()
		local columns = SeasonTrackLogic.columns(SeasonTrackLogic.view(def, state({}), text))
		expect(#columns):toBe(4)
		local wins = {}
		for _, c in columns do
			table.insert(wins, c.wins)
		end
		expect(table.concat(wins, ",")):toBe("0,3,5,10")
		expect(columns[1].free):toBe(nil)
		expect((columns[1].premium :: any).icon):toBe("gem")
		expect(columns[2].premium):toBe(nil)
		expect((columns[2].free :: any).text):toBe("100 coins")
	end)

	it("shares a column when both tracks pay at the same count", function()
		local same: SeasonTrackLogic.SeasonDef = {
			id = "s1",
			displayName = "Season 1",
			passKey = "s1-pass",
			free = { { wins = 5, grant = { kind = "Currency", amount = 1 } } },
			premium = {
				{ wins = 5, grant = { kind = "Currency", amount = 2 } },
				{ wins = 5, grant = { kind = "Currency", amount = 3 } },
			},
		}
		local columns = SeasonTrackLogic.columns(SeasonTrackLogic.view(same, state({}), text))
		expect(#columns):toBe(2)
		expect((columns[1].premium :: any).text):toBe("2 coins")
		expect((columns[1].free :: any).text):toBe("1 coins")
		expect((columns[2].premium :: any).text):toBe("3 coins")
		expect(columns[2].free):toBe(nil)
	end)

	it("marks pass items reached before the pass is bought", function()
		local view = SeasonTrackLogic.view(def, state({ premiumWins = 6 }), text)
		expect(view.premium.rows[2].reached):toBe(true)
		expect(view.premium.rows[2].status):toBe("Locked")
	end)

	it("opens on the first tier with something unclaimed", function()
		local columns = SeasonTrackLogic.columns(SeasonTrackLogic.view(def, state({}), text))
		expect(SeasonTrackLogic.focusColumn(columns)):toBe(1) -- the locked pass item at 0
		local bought = SeasonTrackLogic.view(def, state({ passSeen = true, premiumPaid = 2, freePaid = 1 }), text)
		expect(SeasonTrackLogic.focusColumn(SeasonTrackLogic.columns(bought))):toBe(4)
		local done = SeasonTrackLogic.view(def, state({ passSeen = true, premiumPaid = 2, freePaid = 2 }), text)
		expect(SeasonTrackLogic.focusColumn(SeasonTrackLogic.columns(done))):toBe(4)
	end)

	it("words the time left", function()
		expect(SeasonTrackLogic.timeLeftText(10 * 86400)):toBe("10 days left")
		expect(SeasonTrackLogic.timeLeftText(86400 + 5)):toBe("1 day left")
		expect(SeasonTrackLogic.timeLeftText(5 * 3600)):toBe("5h left")
		expect(SeasonTrackLogic.timeLeftText(120)):toBe("Ends soon")
	end)
end)

describe("StoreScreenLogic coin offers (rewards step 6)", function()
	local offer: StoreScreenLogic.Item = {
		key = "sprint-boost-coins",
		kind = "CoinOffer",
		enabled = true,
		displayName = "Sprint Boost",
		robuxPrice = 0,
		coinPrice = 150,
		sortOrder = 1,
		imageAssetId = 1,
		grants = { { kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 1 } },
	}

	it("is buyable only when the player has the coins", function()
		expect(StoreScreenLogic.itemState(offer, state({ currency = 150 }))):toBe("Buyable")
		expect(StoreScreenLogic.itemState(offer, state({ currency = 149 }))):toBe("TooFewCoins")
	end)

	it("files under the power-ups tab", function()
		expect(StoreScreenLogic.categoryOf(offer)):toBe("PowerUps")
	end)

	it("goes straight to Succeeded on Granted, with no prompt", function()
		local f = StoreScreenLogic.step(StoreScreenLogic.idle(), { type = "Tap", key = offer.key, state = state() }, 0)
		f = StoreScreenLogic.step(f, { type = "Result", key = offer.key, status = "Granted", message = "" }, 0.2)
		expect(f.phase):toBe("Succeeded")
	end)

	it("explains a refusal for too few coins", function()
		local f = StoreScreenLogic.step(StoreScreenLogic.idle(), { type = "Tap", key = offer.key, state = state() }, 0)
		f = StoreScreenLogic.step(f, { type = "Result", key = offer.key, status = "NotEnoughCoins", message = "" }, 0.2)
		expect(f.phase):toBe("Failed")
		expect(f.message):toBe("You don't have enough coins for that yet.")
	end)
end)

describe("BoardLogic.prizes", function()
	local daily = {
		{ maxRank = 1, currency = 75 },
		{ maxRank = 3, currency = 50 },
		{ maxRank = 10, currency = 25, cosmeticId = "crown" },
	}

	it("turns bands into place ranges with their coins", function()
		local p = BoardLogic.prizes("Daily", daily)
		expect(#p.chips):toBe(3)
		expect(p.chips[1].places):toBe("#1")
		expect(p.chips[1].coins):toBe("75")
		expect(p.chips[2].places):toBe("#2-3")
		expect(p.chips[3].places):toBe("#4-10")
		expect(p.chips[3].item):toBe(true)
		expect(p.chips[1].item):toBe(false)
	end)

	it("says how many places pay, and when", function()
		expect(BoardLogic.prizes("Daily", daily).note):toBe("Paid to the top 10 when the day ends.")
		expect(BoardLogic.prizes("Weekly", daily).note):toBe("Paid to the top 10 when the week ends.")
	end)

	it("never pays the all-time board, even if handed bands", function()
		local p = BoardLogic.prizes("AllTime", daily)
		expect(#p.chips):toBe(0)
		expect(p.note):toBe("No prizes here. Being on it is the prize.")
	end)

	it("treats a period with no bands as unpaid", function()
		expect(#BoardLogic.prizes("Weekly", nil).chips):toBe(0)
		expect(#BoardLogic.prizes("Weekly", {}).chips):toBe(0)
	end)
end)

describe("BoardLogic.wall", function()
	local function payload(count: number, status: string?): BoardLogic.Payload
		local entries = {}
		for i = 1, count do
			table.insert(entries, { rank = i, userId = i, bestStreak = 100 - i, displayName = "P" .. i })
		end
		return { entries = entries, status = status or "Fresh" }
	end

	it("skips a part whose Period isn't a tab", function()
		expect(BoardLogic.wall("Monthly", payload(3), 1)):toBe(nil)
	end)

	it("says Loading before any broadcast", function()
		local wall = BoardLogic.wall("Daily", nil, 1) :: BoardLogic.Wall
		expect(wall.message):toBe("Loading…")
		expect(#wall.rows):toBe(0)
	end)

	it("uses the tab's empty copy for an empty board", function()
		local wall = BoardLogic.wall("Weekly", payload(0, "Empty"), 1) :: BoardLogic.Wall
		expect(wall.message):toBe("A new week, an empty board")
	end)

	it("caps at the top WALL_ROWS and marks the viewer", function()
		local wall = BoardLogic.wall("AllTime", payload(40), 3) :: BoardLogic.Wall
		expect(#wall.rows):toBe(BoardLogic.WALL_ROWS)
		expect(wall.rows[1].rank):toBe("#1")
		expect(wall.rows[1].streak):toBe("99")
		expect(wall.rows[3].isViewer):toBe(true)
		expect(wall.rows[2].isViewer):toBe(false)
		expect(wall.message):toBe(nil)
	end)

	it("carries the stale flag", function()
		expect((BoardLogic.wall("Daily", payload(2, "Stale"), 1) :: BoardLogic.Wall).stale):toBe(true)
	end)
end)

describe("ResultsLogic practice recaps", function()
	local function practiceRecap(reason: string, streak: number): ResultsLogic.Recap
		return {
			roundId = "r",
			reason = reason,
			streakBefore = streak,
			streakAfter = streak,
			bestStreakBefore = streak,
			bestStreakAfter = streak,
			reward = nil,
			practice = true,
		}
	end

	it("calls a practice loss safe rather than dead", function()
		local change = ResultsLogic.streakChange(practiceRecap("StudioLoss", 4))
		expect(change.kind):toBe("Practice")
		expect(ResultsLogic.streakHeadline(change)):toBe("Practice match - your 4-win streak is safe")
	end)

	it("says nothing was at stake from a zero streak", function()
		local change = ResultsLogic.streakChange(practiceRecap("QualifiedWin", 0))
		expect(ResultsLogic.streakHeadline(change)):toBe("Practice match - nothing at stake")
	end)
end)
