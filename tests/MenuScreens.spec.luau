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
		expect(StoreScreenLogic.categoryOf(pass)):toBe("Passes")
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
		for _, category in { "Skin", "Trail", "Emote", "Podium", "NotACategory" } do
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
		bounty = nil,
		streakCredited = true,
		npcSeatCount = 0,
		npcSeatThreshold = 3,
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

	it("explains an uncredited win specifically, never as a silent no-change", function()
		local held =
			ResultsLogic.streakChange(recap("QualifiedWin", 2, 2, { streakCredited = false, npcSeatCount = 4 }))
		expect(held.kind):toBe("Held")
		expect((held.note :: string):find("4 of the seats") ~= nil):toBe(true)
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
			bounty = { streakTier = 1, outcomeTag = "SoleStealer" },
		}))
		expect(ids(beats)):toBe("Placement,Tasks,PowerUps,Finale,Rewards,Streak")
		local n = #beats
		expect(beats[n].at - beats[n - 1].at):toBeCloseTo(ResultsLogic.BEAT_GAP + ResultsLogic.STREAK_PAUSE)
	end)

	it("leaves out the finale and rewards for a non-qualifier", function()
		expect(ids(ResultsLogic.beats(recap("FailedToQualify", 3, 0)))):toBe("Placement,Tasks,PowerUps,Streak")
	end)

	it("shows no rewards for a loss even if a bounty is present", function()
		local r = recap("StudioLoss", 3, 0, { bounty = { streakTier = 1, outcomeTag = "AllShare" } })
		expect(ids(ResultsLogic.beats(r))):toBe("Placement,Tasks,PowerUps,Finale,Streak")
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
