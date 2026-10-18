--!strict
-- Covers LevelUpLogic.luau: the level-up pop-up's XP bar segments, its
-- length, and the XP counter that runs alongside.

local TestRunner = require("./TestRunner")
local LevelUpLogic = require("../src/client/UI/LevelUpLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

describe("LevelUpLogic.segments", function()
	it("fills a fresh account's first bar, then shows level 2 empty (the tutorial)", function()
		local parts = LevelUpLogic.segments(
			{ level = 1, xpIntoLevel = 0, xpForNext = 100 },
			{ level = 2, xpIntoLevel = 0, xpForNext = 125 }
		)
		expect(#parts):toBe(2)
		expect(parts[1].level):toBe(1)
		expect(parts[1].from):toBe(0)
		expect(parts[1].to):toBe(1)
		expect(parts[1].levelsUp):toBe(true)
		expect(parts[1].seconds):toBe(LevelUpLogic.FULL_BAR_SECONDS)
		expect(parts[2].level):toBe(2)
		expect(parts[2].to):toBe(0)
		expect(parts[2].seconds):toBe(0)
	end)

	it("fills part of one bar with no level-up", function()
		local parts = LevelUpLogic.segments(
			{ level = 3, xpIntoLevel = 30, xpForNext = 150 },
			{ level = 3, xpIntoLevel = 90, xpForNext = 150 }
		)
		expect(#parts):toBe(1)
		expect(parts[1].from):toBe(0.2)
		expect(parts[1].to):toBe(0.6)
		expect(parts[1].levelsUp):toBe(false)
	end)

	it("gives a tiny fill the minimum time", function()
		local parts = LevelUpLogic.segments(
			{ level = 3, xpIntoLevel = 0, xpForNext = 150 },
			{ level = 3, xpIntoLevel = 1, xpForNext = 150 }
		)
		expect(parts[1].seconds):toBe(LevelUpLogic.MIN_SECONDS)
	end)

	it("caps a big jump's full sweeps, still landing in level order", function()
		local parts = LevelUpLogic.segments(
			{ level = 1, xpIntoLevel = 50, xpForNext = 100 },
			{ level = 7, xpIntoLevel = 10, xpForNext = 250 }
		)
		expect(#parts):toBe(LevelUpLogic.MAX_SWEEPS + 1)
		expect(parts[1].level):toBe(1)
		expect(parts[#parts - 1].level):toBe(6)
		expect(parts[#parts].level):toBe(7)
		for index = 2, #parts - 1 do
			expect(parts[index].from):toBe(0)
			expect(parts[index].to):toBe(1)
		end
	end)

	it("treats the max level's bar as full", function()
		expect(LevelUpLogic.fraction({ level = 200, xpIntoLevel = 0, xpForNext = 0 })):toBe(1)
	end)
end)

describe("LevelUpLogic timing", function()
	it("adds a beat per level-up to the fill time", function()
		local parts = LevelUpLogic.segments(
			{ level = 1, xpIntoLevel = 0, xpForNext = 100 },
			{ level = 2, xpIntoLevel = 0, xpForNext = 125 }
		)
		expect(LevelUpLogic.fillSeconds(parts)):toBe(LevelUpLogic.FULL_BAR_SECONDS)
		expect(LevelUpLogic.totalSeconds(parts)):toBe(LevelUpLogic.FULL_BAR_SECONDS + LevelUpLogic.LEVEL_BEAT_SECONDS)
	end)

	it("counts the XP up to exactly the total as the fill ends", function()
		expect(LevelUpLogic.xpShown(100, 0, 1.2)):toBe(0)
		expect(LevelUpLogic.xpShown(100, 0.6, 1.2)):toBe(50)
		expect(LevelUpLogic.xpShown(100, 5, 1.2)):toBe(100)
		expect(LevelUpLogic.xpShown(100, 0, 0)):toBe(100)
	end)
end)
