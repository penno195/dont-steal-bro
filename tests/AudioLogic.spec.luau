--!strict
-- Covers AudioLogic.luau (P8-3): the cue table's invariants, ducking,
-- the voice budget, race intensity and the reveal timeline.
-- AudioController itself creates Sounds, so it's exercised in Studio.

local AudioLogic = require("../src/client/UI/AudioLogic")
local DecisionLogic = require("../src/client/UI/DecisionLogic")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

describe("AudioLogic.CUES", function()
	it("gives every cue a sane volume, priority and cooldown", function()
		for id, def in AudioLogic.CUES do
			assert(def.volume > 0 and def.volume <= 1, id .. ": volume out of range")
			assert(def.priority >= 0 and def.priority <= 100, id .. ": priority out of range")
			assert(def.cooldown >= 0, id .. ": negative cooldown")
			if def.duck ~= nil then
				assert(def.duck.level >= 0 and def.duck.level < 1, id .. ": duck level must be below 1")
			end
		end
	end)

	it("keeps every bed looped Music and every other cue a one-shot", function()
		for _, id in { "HubAmbience", "RaceBed", "RaceTension", "StudioBed" } do
			local def = AudioLogic.CUES[id]
			expect(def.category):toBe("Music")
			expect(def.looped):toBe(true)
		end
		for id, def in AudioLogic.CUES do
			if def.category == "SFX" then
				assert(not def.looped, id .. ": an SFX loop would never release its voice")
			end
		end
	end)

	it("never lets the reveal or a resolution be dropped for budget", function()
		for _, id in { "RevealRiser", "RevealCard", "RevealOutcome", "Win", "Loss" } do
			expect(AudioLogic.CUES[id].priority):toBe(100)
			expect(AudioLogic.CUES[id].duck ~= nil):toBe(true)
		end
	end)

	it("makes the power-up used ON you outrank the one used BY you", function()
		local on, by = AudioLogic.CUES.PowerUpHitYou, AudioLogic.CUES.PowerUpUsedByYou
		expect(on.priority > by.priority):toBe(true)
		expect(on.duck ~= nil):toBe(true)
	end)
end)

describe("AudioLogic.resolveRaceBed", function()
	it("uses the map's own track when it's real", function()
		expect(AudioLogic.resolveRaceBed("rbxassetid://123")):toBe("rbxassetid://123")
	end)
	it("falls back for a placeholder or missing track", function()
		expect(AudioLogic.resolveRaceBed(nil)):toBe(AudioLogic.CUES.RaceBed.assetId)
		expect(AudioLogic.resolveRaceBed(AudioLogic.PLACEHOLDER_ASSET)):toBe(AudioLogic.CUES.RaceBed.assetId)
	end)
end)

describe("AudioLogic.bedFor", function()
	it("plays the hub before any round state arrives", function()
		expect(AudioLogic.bedFor(nil)):toBe("Hub")
	end)
	it("maps the round states", function()
		expect(AudioLogic.bedFor("Race")):toBe("Race")
		expect(AudioLogic.bedFor("Qualified")):toBe("Race")
		expect(AudioLogic.bedFor("DecisionStudio")):toBe("Studio")
		expect(AudioLogic.bedFor("Results")):toBe("None")
		expect(AudioLogic.bedFor("SomethingNew")):toBe("None")
	end)
end)

describe("AudioLogic.duckEnvelope", function()
	local duck = { level = 0.2, attack = 0.1, hold = 0.5, release = 0.4 }

	it("is untouched before and after", function()
		expect(AudioLogic.duckEnvelope(duck, 10, 9.9)):toBe(1)
		expect(AudioLogic.duckEnvelope(duck, 10, 11.1)):toBe(1)
	end)
	it("ramps down, holds, then ramps back", function()
		expect(AudioLogic.duckEnvelope(duck, 0, 0.05)):toBeCloseTo(0.6)
		expect(AudioLogic.duckEnvelope(duck, 0, 0.3)):toBeCloseTo(0.2)
		expect(AudioLogic.duckEnvelope(duck, 0, 0.8)):toBeCloseTo(0.6)
	end)
	it("takes the deepest of overlapping ducks rather than multiplying", function()
		local shallow = { level = 0.5, attack = 0, hold = 1, release = 0 }
		local deep = { level = 0.2, attack = 0, hold = 1, release = 0 }
		local level = AudioLogic.duckLevel({ { duck = shallow, startedAt = 0 }, { duck = deep, startedAt = 0 } }, 0.5)
		expect(level):toBeCloseTo(0.2)
	end)
	it("prunes only fully released ducks", function()
		local kept = AudioLogic.pruneDucks({ { duck = duck, startedAt = 0 }, { duck = duck, startedAt = 5 } }, 5.5)
		expect(#kept):toBe(1)
		expect(kept[1].startedAt):toBe(5)
	end)
	it("covers the whole reveal with the blanket duck", function()
		local length = DecisionLogic.revealLength(3)
		local d = AudioLogic.revealDuck(length)
		expect(AudioLogic.duckEnvelope(d, 0, length - 0.01)):toBeCloseTo(d.level)
	end)
end)

describe("AudioLogic.admit", function()
	local function voices(n: number, priority: number)
		local out = {}
		for i = 1, n do
			table.insert(out, { priority = priority, startedAt = i })
		end
		return out
	end

	it("plays under budget", function()
		expect((AudioLogic.admit(voices(3, 50), 10, 8))):toBe("play")
	end)
	it("steals the weakest, oldest voice when full", function()
		local v = voices(8, 50)
		v[5].priority = 20
		v[6].priority = 20
		local verdict, index = AudioLogic.admit(v, 90, 8)
		expect(verdict):toBe("steal")
		expect(index):toBe(5)
	end)
	it("drops a newcomer that doesn't outrank anything", function()
		expect((AudioLogic.admit(voices(8, 50), 50, 8))):toBe("drop")
		expect((AudioLogic.admit(voices(8, 50), 10, 8))):toBe("drop")
	end)
end)

describe("AudioLogic.offCooldown", function()
	it("respects the cue's cooldown", function()
		local def = AudioLogic.CUES.TaskSuccess
		expect(AudioLogic.offCooldown(nil, def, 0)):toBe(true)
		expect(AudioLogic.offCooldown(10, def, 10 + def.cooldown / 2)):toBe(false)
		expect(AudioLogic.offCooldown(10, def, 10 + def.cooldown)):toBe(true)
	end)
end)

describe("AudioLogic.raceIntensity", function()
	it("is calm with plenty of time", function()
		local i = AudioLogic.raceIntensity(200)
		expect(i.tier):toBe(0)
		expect(i.tension):toBe(0)
		expect(i.playbackSpeed):toBe(1)
	end)
	it("fades the tension stem in between the two thresholds", function()
		local mid = (AudioLogic.TENSION_START + AudioLogic.TENSION_FULL) / 2
		local i = AudioLogic.raceIntensity(mid)
		expect(i.tier):toBe(1)
		expect(i.tension):toBeCloseTo(0.5)
	end)
	it("is at full tension and top speed at zero", function()
		local i = AudioLogic.raceIntensity(0)
		expect(i.tier):toBe(3)
		expect(i.tension):toBe(1)
		expect(i.playbackSpeed):toBeCloseTo(AudioLogic.MAX_SPEED)
	end)
	it("only ever rises as time runs down", function()
		local last = -1
		for s = 120, 0, -0.5 do
			local t = AudioLogic.raceIntensity(s).tension
			assert(t >= last, "tension fell at " .. s)
			last = t
		end
	end)
end)

describe("AudioLogic.tickDue", function()
	it("ticks once per whole second inside the window", function()
		expect(AudioLogic.tickDue(15, nil)):toBe(nil)
		expect(AudioLogic.tickDue(9.5, nil)):toBe(10)
		expect(AudioLogic.tickDue(9.2, 10)):toBe(nil)
		expect(AudioLogic.tickDue(8.9, 10)):toBe(9)
	end)
	it("jumps to the current second after a long frame", function()
		expect(AudioLogic.tickDue(4.5, 9)):toBe(5)
	end)
	it("is silent once time is up", function()
		expect(AudioLogic.tickDue(0, 1)):toBe(nil)
	end)
end)

describe("AudioLogic.revealSchedule", function()
	it("lands each card on the frame revealStep turns it", function()
		local timing = DecisionLogic.TIMING
		local schedule, resultAt = AudioLogic.revealSchedule(3, timing)
		local cards = 0
		for _, entry in schedule do
			if entry.cue == "RevealCard" then
				cards += 1
				expect(DecisionLogic.revealStep(entry.at, 3).cardsShown):toBe(cards)
				expect(DecisionLogic.revealStep(entry.at - 0.01, 3).cardsShown):toBe(cards - 1)
			elseif entry.cue == "RevealOutcome" then
				expect(DecisionLogic.revealStep(entry.at, 3).outcomeShown):toBe(true)
				expect(DecisionLogic.revealStep(entry.at - 0.01, 3).outcomeShown):toBe(false)
			end
		end
		expect(cards):toBe(3)
		expect(DecisionLogic.revealStep(resultAt, 3).resultShown):toBe(true)
		expect(DecisionLogic.revealStep(resultAt - 0.01, 3).resultShown):toBe(false)
	end)
end)

describe("AudioLogic.resolutionCue", function()
	it("prefers the personal result", function()
		expect(AudioLogic.resolutionCue(1, { 1 }, {}, false)):toBe("Loss")
	end)
	it("falls back to the reveal's id lists", function()
		expect(AudioLogic.resolutionCue(1, { 1, 2 }, { 3 }, nil)):toBe("Win")
		expect(AudioLogic.resolutionCue(3, { 1, 2 }, { 3 }, nil)):toBe("Loss")
	end)
	it("gives a spectator nothing", function()
		expect(AudioLogic.resolutionCue(9, { 1 }, { 3 }, nil)):toBe(nil)
	end)
end)

describe("AudioLogic.qualificationCue", function()
	it("tells a qualifier, a racer who missed, and a spectator apart", function()
		expect(AudioLogic.qualificationCue(1, { 1, 2, 3, 4 }, { 1, 2, 3 })):toBe("Qualified")
		expect(AudioLogic.qualificationCue(4, { 1, 2, 3, 4 }, { 1, 2, 3 })):toBe("NotQualified")
		expect(AudioLogic.qualificationCue(9, { 1, 2, 3, 4 }, { 1, 2, 3 })):toBe(nil)
	end)
end)

describe("AudioLogic.newDebuffs", function()
	it("hits on a new debuff and ignores buffs", function()
		local keys, hit = AudioLogic.newDebuffs({}, { { id = "SprintBoost", kind = "Buff", expiresAt = 5 } })
		expect(hit):toBe(false)
		keys, hit = AudioLogic.newDebuffs(keys, { { id = "SlowField", kind = "Debuff", expiresAt = 5 } })
		expect(hit):toBe(true)
		keys, hit = AudioLogic.newDebuffs(keys, { { id = "SlowField", kind = "Debuff", expiresAt = 5 } })
		expect(hit):toBe(false)
	end)
	it("hits again when the same debuff is re-applied", function()
		local keys = AudioLogic.newDebuffs({}, { { id = "SlowField", kind = "Debuff", expiresAt = 5 } })
		local _, hit = AudioLogic.newDebuffs(keys, { { id = "SlowField", kind = "Debuff", expiresAt = 9 } })
		expect(hit):toBe(true)
	end)
end)
