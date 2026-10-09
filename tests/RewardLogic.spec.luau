--!strict
-- Covers RewardLogic.luau: what a win pays (design-decisions.md Q1's
-- 2026-09-30 revision and its 2026-10-02 applied case). Rolls take a
-- scripted rng, so each branch - no drop, each rarity, a duplicate
-- cosmetic - is a fixed case rather than a statistical one.

local TestRunner = require("./TestRunner")
local RewardLogic = require("../src/server/RewardLogic")

local function config(): RewardLogic.WinRewardsConfig
	return {
		currency = { soleStealer = 100, loneSharer = 50, allShare = 25, perRungBonus = 0.1 },
		drop = {
			baseChance = 0.1,
			perRungChance = 0.02,
			maxChance = 0.5,
			rarityWeights = {
				Common = { weight = 70, perRungGrowth = 0 },
				Uncommon = { weight = 25, perRungGrowth = 0.05 },
				Rare = { weight = 5, perRungGrowth = 0.2 },
			},
			powerUpAmount = 1,
			duplicateCurrency = { Common = 50, Uncommon = 100, Rare = 250 },
		},
	}
end

-- The live ladder: 1-10, 12-20 by 2, 25-50 by 5.
local LADDER = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20, 25, 30, 35, 40, 45, 50 }

-- Returns the given numbers in order, then errors if asked for more, so
-- a test also pins how many rolls a path makes.
local function scripted(values: { number }): () -> number
	local index = 0
	return function()
		index += 1
		local value = values[index]
		assert(value ~= nil, "rng called more times than scripted")
		return value
	end
end

local POOL: { RewardLogic.PoolItem } = {
	{ kind = "PowerUp", id = "blind", rarity = "Uncommon" },
	{ kind = "Cosmetic", id = "nameplate-gilded", rarity = "Rare" },
	{ kind = "PowerUp", id = "sprint-boost", rarity = "Common" },
	{ kind = "PowerUp", id = "task-insight", rarity = "Common" },
}

TestRunner.describe("RewardLogic.rungFor", function()
	TestRunner.it("counts the rungs a streak reaches", function()
		TestRunner.expect(RewardLogic.rungFor(LADDER, 0)):toBe(0)
		TestRunner.expect(RewardLogic.rungFor(LADDER, 1)):toBe(1)
		TestRunner.expect(RewardLogic.rungFor(LADDER, 11)):toBe(10) -- 11 sits between rungs 10 and 12
		TestRunner.expect(RewardLogic.rungFor(LADDER, 50)):toBe(21)
		TestRunner.expect(RewardLogic.rungFor(LADDER, 80)):toBe(21)
	end)
end)

TestRunner.describe("RewardLogic.currencyFor", function()
	TestRunner.it("pays each outcome tier's base at rung 0", function()
		TestRunner.expect(RewardLogic.currencyFor(config(), "SoleStealer", 0)):toBe(100)
		TestRunner.expect(RewardLogic.currencyFor(config(), "LoneSharer", 0)):toBe(50)
		TestRunner.expect(RewardLogic.currencyFor(config(), "AllShare", 0)):toBe(25)
	end)

	TestRunner.it("grows with the rung and rounds down", function()
		TestRunner.expect(RewardLogic.currencyFor(config(), "SoleStealer", 21)):toBe(310)
		TestRunner.expect(RewardLogic.currencyFor(config(), "AllShare", 3)):toBe(32) -- 25 * 1.3 = 32.5
	end)

	TestRunner.it("keeps stealing ahead of sharing at every rung", function()
		for rung = 0, 21 do
			local steal = RewardLogic.currencyFor(config(), "SoleStealer", rung)
			local lone = RewardLogic.currencyFor(config(), "LoneSharer", rung)
			local all = RewardLogic.currencyFor(config(), "AllShare", rung)
			TestRunner.expect(steal > lone and lone > all):toBeTruthy()
		end
	end)
end)

TestRunner.describe("RewardLogic drop odds", function()
	TestRunner.it("raises the drop chance per rung up to the cap", function()
		TestRunner.expect(RewardLogic.dropChanceFor(config(), 0)):toBeCloseTo(0.1)
		TestRunner.expect(RewardLogic.dropChanceFor(config(), 10)):toBeCloseTo(0.3)
		TestRunner.expect(RewardLogic.dropChanceFor(config(), 21)):toBeCloseTo(0.5)
	end)

	TestRunner.it("shifts the rarity weights toward Rare as the rung climbs", function()
		local low = RewardLogic.rarityWeightsFor(config(), 0)
		local high = RewardLogic.rarityWeightsFor(config(), 21)
		TestRunner.expect(low.Rare):toBeCloseTo(5)
		TestRunner.expect(high.Rare):toBeCloseTo(26)
		TestRunner.expect(high.Common):toBeCloseTo(70)
		local lowShare = low.Rare / (low.Common + low.Uncommon + low.Rare)
		local highShare = high.Rare / (high.Common + high.Uncommon + high.Rare)
		TestRunner.expect(highShare > lowShare):toBeTruthy()
	end)
end)

TestRunner.describe("RewardLogic.buildDropPool", function()
	TestRunner.it("keeps free loadout power-ups and opted-in enabled cosmetics, sorted by id", function()
		local pool = RewardLogic.buildDropPool({
			{ id = "sprint-boost", rarity = "Common", acquisition = { loadoutEligible = true, freelyEarnable = true } },
			{ id = "paid-only", rarity = "Rare", acquisition = { loadoutEligible = true, freelyEarnable = false } },
			{ id = "field-only", rarity = "Common", acquisition = { loadoutEligible = false, freelyEarnable = true } },
			{ id = "blind", rarity = "Uncommon", acquisition = { loadoutEligible = true, freelyEarnable = true } },
		}, {
			{ id = "trail-a", rarity = "Rare", enabled = true, winDrop = true },
			{ id = "founder-skin", rarity = "Rare", enabled = true }, -- not opted in
			{ id = "trail-off", rarity = "Common", enabled = false, winDrop = true }, -- disabled
		})
		TestRunner.expect(#pool):toBe(3)
		TestRunner.expect(pool[1].id):toBe("blind")
		TestRunner.expect(pool[2].id):toBe("sprint-boost")
		TestRunner.expect(pool[3].id):toBe("trail-a")
		TestRunner.expect(pool[3].kind):toBe("Cosmetic")
	end)
end)

TestRunner.describe("RewardLogic.rollDrop", function()
	TestRunner.it("drops nothing when the chance roll misses, using one roll", function()
		TestRunner.expect(RewardLogic.rollDrop(config(), 0, POOL, {}, scripted({ 0.1 }))):toBe(nil)
	end)

	TestRunner.it("drops nothing from an empty pool, without rolling", function()
		TestRunner.expect(RewardLogic.rollDrop(config(), 0, {}, {}, scripted({}))):toBe(nil)
	end)

	TestRunner.it("picks a Common power-up and grants loadout stock", function()
		-- rarity roll 0.5 * 100 = 50 < 70 -> Common; item roll 0.9 -> the 2nd Common
		local drop = RewardLogic.rollDrop(config(), 0, POOL, {}, scripted({ 0.05, 0.5, 0.9 }))
		assert(drop ~= nil)
		TestRunner.expect(drop.item.id):toBe("task-insight")
		TestRunner.expect(drop.duplicate):toBe(false)
		TestRunner.expect(drop.grant.kind):toBe("PowerUpStock")
		TestRunner.expect(drop.grant.powerUpId):toBe("task-insight")
		TestRunner.expect(drop.grant.amount):toBe(1)
	end)

	TestRunner.it("grants a Rare cosmetic the winner doesn't own", function()
		local drop = RewardLogic.rollDrop(config(), 0, POOL, {}, scripted({ 0.05, 0.99, 0 }))
		assert(drop ~= nil)
		TestRunner.expect(drop.grant.kind):toBe("Cosmetic")
		TestRunner.expect(drop.grant.cosmeticId):toBe("nameplate-gilded")
	end)

	TestRunner.it("pays currency by rarity for a cosmetic already owned", function()
		local drop = RewardLogic.rollDrop(config(), 0, POOL, { "nameplate-gilded" }, scripted({ 0.05, 0.99, 0 }))
		assert(drop ~= nil)
		TestRunner.expect(drop.duplicate):toBe(true)
		TestRunner.expect(drop.grant.kind):toBe("Currency")
		TestRunner.expect(drop.grant.amount):toBe(250)
	end)

	TestRunner.it("never rolls a rarity the pool has no items for", function()
		local commonsOnly: { RewardLogic.PoolItem } = { { kind = "PowerUp", id = "sprint-boost", rarity = "Common" } }
		local drop = RewardLogic.rollDrop(config(), 21, commonsOnly, {}, scripted({ 0, 0.999, 0 }))
		assert(drop ~= nil)
		TestRunner.expect(drop.item.id):toBe("sprint-boost")
	end)
end)

TestRunner.describe("RewardLogic.rollWinReward", function()
	TestRunner.it("pays currency at the rung this win reached, plus the drop", function()
		-- A first-ever win: streak after = 1, so rung 1 (applied case, 2026-10-02).
		local reward =
			RewardLogic.rollWinReward(config(), "LoneSharer", 1, LADDER, POOL, {}, scripted({ 0.05, 0.5, 0 }))
		TestRunner.expect(reward.rung):toBe(1)
		TestRunner.expect(reward.currency):toBe(55)
		TestRunner.expect(#reward.grants):toBe(2)
		TestRunner.expect(reward.grants[1].kind):toBe("Currency")
		TestRunner.expect(reward.grants[1].amount):toBe(55)
		TestRunner.expect(reward.grants[2].powerUpId):toBe("sprint-boost")
	end)

	TestRunner.it("pays only currency when no drop lands", function()
		local reward = RewardLogic.rollWinReward(config(), "AllShare", 50, LADDER, POOL, {}, scripted({ 0.9 }))
		TestRunner.expect(reward.drop):toBe(nil)
		TestRunner.expect(#reward.grants):toBe(1)
		TestRunner.expect(reward.currency):toBe(77) -- 25 * 3.1 = 77.5
	end)
end)
