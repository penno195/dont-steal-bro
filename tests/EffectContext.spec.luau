--!strict
-- Covers EffectContext.luau (P5-5): the practice flag PowerUpService and
-- StatusEffects share. The zone gate is injected, so these tests fake
-- "who is standing in the practice area" with a plain table. The Roblox
-- half (PracticeService, the volumes) is checked in Studio - see
-- docs/practice-area.md.

local TestRunner = require("./TestRunner")
local EffectContext = require("../src/server/EffectContext")

local RULES: EffectContext.PracticeRules = { durationScale = 0.5, maxEffectSeconds = 2, maxActiveEffects = 1 }

local function enterWith(inside: { [number]: boolean })
	EffectContext.resetForTesting()
	EffectContext.enterPractice(RULES, function(id: number): boolean
		return inside[id] == true
	end)
end

TestRunner.describe("EffectContext in Round mode (the default)", function()
	TestRunner.it("changes nothing a round does", function()
		EffectContext.resetForTesting()
		TestRunner.expect(EffectContext.mode()):toBe("Round")
		TestRunner.expect(EffectContext.recordsStats()):toBe(true)
		TestRunner.expect(EffectContext.mayAct(123)):toBe(true)
		TestRunner.expect(EffectContext.mayAct(-4)):toBe(true) -- NPC ids too
		TestRunner.expect(EffectContext.inPracticeArea(123)):toBe(false)
		TestRunner.expect(EffectContext.effectDuration(2.5)):toBe(2.5)
		TestRunner.expect(EffectContext.effectDuration(10)):toBe(10)
		TestRunner.expect(EffectContext.admits(50, false)):toBe(true)
	end)

	TestRunner.it("lets a round start", function()
		EffectContext.resetForTesting()
		local ok = pcall(EffectContext.assertRound, "test")
		TestRunner.expect(ok):toBe(true)
	end)
end)

TestRunner.describe("EffectContext in Practice mode", function()
	TestRunner.it("records no stats", function()
		enterWith({})
		TestRunner.expect(EffectContext.recordsStats()):toBe(false)
	end)

	TestRunner.it("lets only people inside the area act", function()
		enterWith({ [1] = true })
		TestRunner.expect(EffectContext.mayAct(1)):toBe(true)
		TestRunner.expect(EffectContext.inPracticeArea(1)):toBe(true)
		TestRunner.expect(EffectContext.mayAct(2)):toBe(false)
		TestRunner.expect(EffectContext.inPracticeArea(2)):toBe(false)
	end)

	TestRunner.it("reads the gate live, never a cached answer", function()
		local inside = { [1] = true }
		enterWith(inside)
		TestRunner.expect(EffectContext.mayAct(1)):toBe(true)
		inside[1] = false -- walked onto the queue pad
		TestRunner.expect(EffectContext.mayAct(1)):toBe(false)
	end)

	TestRunner.it("scales durations, then caps them", function()
		enterWith({})
		TestRunner.expect(EffectContext.effectDuration(2.5)):toBe(1.25) -- freeze
		TestRunner.expect(EffectContext.effectDuration(1)):toBe(0.5) -- push-trip
		TestRunner.expect(EffectContext.effectDuration(6)):toBe(2) -- sprint-boost: 3, capped at 2
		TestRunner.expect(EffectContext.effectDuration(10)):toBe(2)
	end)

	TestRunner.it("enforces the effect cap, but never blocks a refresh", function()
		enterWith({})
		TestRunner.expect(EffectContext.admits(0, false)):toBe(true)
		TestRunner.expect(EffectContext.admits(1, false)):toBe(false)
		TestRunner.expect(EffectContext.admits(1, true)):toBe(true)
	end)

	TestRunner.it("refuses to run a round", function()
		enterWith({})
		local ok = pcall(EffectContext.assertRound, "test")
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("can't be entered twice", function()
		enterWith({})
		local ok = pcall(EffectContext.enterPractice, RULES, function(_id: number): boolean
			return true
		end)
		TestRunner.expect(ok):toBe(false)
	end)
end)

TestRunner.describe("EffectContext pure rules", function()
	TestRunner.it("never lengthens an effect", function()
		for _, base in { 0.5, 1, 2.5, 4, 6, 10 } do
			local scaled = EffectContext.scaledDuration(base, RULES)
			TestRunner.expect(scaled <= base):toBe(true)
			TestRunner.expect(scaled <= RULES.maxEffectSeconds):toBe(true)
		end
	end)

	TestRunner.it("admits up to the cap", function()
		TestRunner.expect(EffectContext.admitsEffect(2, false, 3)):toBe(true)
		TestRunner.expect(EffectContext.admitsEffect(3, false, 3)):toBe(false)
		TestRunner.expect(EffectContext.admitsEffect(3, true, 3)):toBe(true)
	end)
end)
