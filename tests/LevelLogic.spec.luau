--!strict
-- Covers LevelLogic.luau: what every round pays, win or lose
-- (design-decisions.md Q1's "a payoff for every round", 2026-10-17).

local TestRunner = require("./TestRunner")
local LevelLogic = require("../src/shared/LevelLogic")

local function config(): LevelLogic.RoundRewardsConfig
	return {
		xp = {
			perTask = 8,
			studio = 40,
			win = 50,
			perHit = 5,
			maxHits = 6,
			byPlace = { 30, 25, 20, 15, 10, 5 },
		},
		currencyByPlace = { 12, 10, 8, 6, 4, 2 },
		level = { firstLevelXp = 100, perLevelXp = 25, maxLevel = 10, levelUpCurrency = 50 },
	}
end

local function performance(overrides: { [string]: any }?): LevelLogic.RoundPerformance
	local base: { [string]: any } = { tasksDone = 0, place = nil, reachedStudio = false, won = false, hits = 0 }
	for key, value in overrides or {} do
		base[key] = value
	end
	return base :: any
end

TestRunner.describe("LevelLogic.progressFor", function()
	TestRunner.it("starts at level 1 with nothing earned", function()
		local p = LevelLogic.progressFor(config().level, 0)
		TestRunner.expect(p.level):toBe(1)
		TestRunner.expect(p.xpIntoLevel):toBe(0)
		TestRunner.expect(p.xpForNext):toBe(100)
	end)

	TestRunner.it("levels up exactly on the threshold, and each level costs more", function()
		local curve = config().level
		TestRunner.expect(LevelLogic.progressFor(curve, 99).level):toBe(1)
		TestRunner.expect(LevelLogic.progressFor(curve, 100).level):toBe(2)
		-- Level 2 -> 3 costs 125, so level 3 is at 225 total.
		local p = LevelLogic.progressFor(curve, 224)
		TestRunner.expect(p.level):toBe(2)
		TestRunner.expect(p.xpIntoLevel):toBe(124)
		TestRunner.expect(p.xpForNext):toBe(125)
		TestRunner.expect(LevelLogic.progressFor(curve, 225).level):toBe(3)
	end)

	TestRunner.it("stops at maxLevel with an empty bar", function()
		local p = LevelLogic.progressFor(config().level, 1e9)
		TestRunner.expect(p.level):toBe(10)
		TestRunner.expect(p.xpIntoLevel):toBe(0)
		TestRunner.expect(p.xpForNext):toBe(0)
	end)

	TestRunner.it("treats negative or NaN XP as none", function()
		TestRunner.expect(LevelLogic.progressFor(config().level, -50).level):toBe(1)
		TestRunner.expect(LevelLogic.progressFor(config().level, 0 / 0).level):toBe(1)
	end)
end)

TestRunner.describe("LevelLogic.roundXp", function()
	TestRunner.it("pays a non-finalist for tasks, place and hits", function()
		local xp = LevelLogic.roundXp(config().xp, performance({ tasksDone = 4, place = 4, hits = 1 }))
		TestRunner.expect(xp):toBe(4 * 8 + 15 + 5)
	end)

	TestRunner.it("pays a finalist for the Studio, and a winner on top", function()
		local finalist = performance({ tasksDone = 6, place = 1, reachedStudio = true })
		TestRunner.expect(LevelLogic.roundXp(config().xp, finalist)):toBe(48 + 30 + 40)
		local winner = performance({ tasksDone = 6, place = 1, reachedStudio = true, won = true })
		TestRunner.expect(LevelLogic.roundXp(config().xp, winner)):toBe(48 + 30 + 40 + 50)
	end)

	TestRunner.it("never pays a win without the Studio", function()
		local xp = LevelLogic.roundXp(config().xp, performance({ won = true }))
		TestRunner.expect(xp):toBe(0)
	end)

	TestRunner.it("caps hits at maxHits", function()
		local xp = LevelLogic.roundXp(config().xp, performance({ hits = 50 }))
		TestRunner.expect(xp):toBe(6 * 5)
	end)

	TestRunner.it("pays nothing for a missing or out-of-range place", function()
		TestRunner.expect(LevelLogic.roundXp(config().xp, performance({ place = 9 }))):toBe(0)
		TestRunner.expect(LevelLogic.roundXp(config().xp, performance({ place = nil }))):toBe(0)
		TestRunner.expect(LevelLogic.roundXp(config().xp, performance({ tasksDone = -3 }))):toBe(0)
	end)
end)

TestRunner.describe("LevelLogic.award", function()
	TestRunner.it("pays place coins with no level-up", function()
		local award = LevelLogic.award(config(), 0, performance({ tasksDone = 2, place = 6 }), {})
		TestRunner.expect(award.xpGained):toBe(16 + 5)
		TestRunner.expect(award.xpAfter):toBe(21)
		TestRunner.expect(award.levelBefore):toBe(1)
		TestRunner.expect(award.levelAfter):toBe(1)
		TestRunner.expect(award.placeCurrency):toBe(2)
		TestRunner.expect(award.levelUpCurrency):toBe(0)
		TestRunner.expect(#award.milestonesReached):toBe(0)
	end)

	TestRunner.it("pays per level gained, including several in one round", function()
		-- 90 XP + a 198 XP round = 288: past level 2 (100) and 3 (225).
		local winner = performance({ tasksDone = 6, place = 1, reachedStudio = true, won = true, hits = 6 })
		local award = LevelLogic.award(config(), 90, winner, {})
		TestRunner.expect(award.xpAfter):toBe(288)
		TestRunner.expect(award.levelBefore):toBe(1)
		TestRunner.expect(award.levelAfter):toBe(3)
		TestRunner.expect(award.levelUpCurrency):toBe(100)
	end)

	TestRunner.it("returns only the milestones crossed this round, in order", function()
		local winner = performance({ tasksDone = 6, place = 1, reachedStudio = true, won = true, hits = 6 })
		local award = LevelLogic.award(config(), 90, winner, { 5, 3, 2, 1 })
		TestRunner.expect(#award.milestonesReached):toBe(2)
		TestRunner.expect(award.milestonesReached[1]):toBe(2)
		TestRunner.expect(award.milestonesReached[2]):toBe(3)
	end)

	TestRunner.it("pays no level-up coins past maxLevel", function()
		local award = LevelLogic.award(config(), 1e9, performance({ tasksDone = 6 }), {})
		TestRunner.expect(award.levelBefore):toBe(10)
		TestRunner.expect(award.levelAfter):toBe(10)
		TestRunner.expect(award.levelUpCurrency):toBe(0)
	end)
end)

TestRunner.describe("LevelLogic level unlocks", function()
	local unlocks: { LevelLogic.LevelUnlock } = {
		{ id = "trail-ten", level = 10 },
		{ id = "hat-five", level = 5 },
		{ id = "card-five", level = 5 },
	}

	TestRunner.it("lists each milestone level once, ascending", function()
		local levels = LevelLogic.milestoneLevels(unlocks)
		TestRunner.expect(#levels):toBe(2)
		TestRunner.expect(levels[1]):toBe(5)
		TestRunner.expect(levels[2]):toBe(10)
	end)

	TestRunner.it("is due nothing below the first milestone", function()
		TestRunner.expect(#LevelLogic.unlocksDue(unlocks, 4, {})):toBe(0)
	end)

	TestRunner.it("is due every unlock at or below the level, owned ones skipped", function()
		local due = LevelLogic.unlocksDue(unlocks, 10, { "hat-five" })
		TestRunner.expect(#due):toBe(2)
		TestRunner.expect(table.find(due, "trail-ten") ~= nil):toBe(true)
		TestRunner.expect(table.find(due, "card-five") ~= nil):toBe(true)
	end)
end)
