--!strict
-- Covers TitleLogic.luau (P4-2): unlocking, the newly-crossed-rung
-- diff, equip validation, the Q7 visibility rule and the NPC
-- distribution. TitleService.luau itself isn't required here - it
-- touches Players, remotes and TextChatService at call time, so it's
-- exercised in Studio, the same split every other spec in this suite
-- uses.
--
-- The case that matters most is permanence: a title is never revoked,
-- and P4-2 asks for that to be structurally impossible rather than
-- merely intended. The tests below check the half that lives in this
-- module (unlocking reads bestStreak alone, and a falling
-- currentStreak cannot be expressed as an input); the other half -
-- bestStreak never being lowered - is asserted for every reason code
-- in tests/ProgressionLogic.spec.luau.

local TestRunner = require("./TestRunner")
local TitleLogic = require("../src/server/TitleLogic")

-- The real ladder's shape, trimmed to five rungs so the expectations
-- below stay readable. The live one is src/shared/Config/Titles/.
local LADDER: { TitleLogic.TitleDef } = {
	{ id = "got-one", displayName = "Got One", colorHex = "#9aa5b1", minStreak = 1 },
	{ id = "hot-streak", displayName = "Hot Streak", colorHex = "#f0913a", minStreak = 5 },
	{ id = "menace", displayName = "Menace", colorHex = "#c65ad6", minStreak = 15 },
	{ id = "final-boss", displayName = "Final Boss", colorHex = "#1fd1c3", minStreak = 60, effect = "Glow" },
	{ id = "touch-grass", displayName = "Touch Grass", colorHex = "#7cf03a", minStreak = 120, effect = "Rainbow" },
}

TestRunner.describe("TitleLogic.unlockedFor", function()
	TestRunner.it("unlocks nothing below the first rung", function()
		TestRunner.expect(#TitleLogic.unlockedFor(LADDER, 0)):toBe(0)
	end)

	TestRunner.it("unlocks a rung exactly at its threshold", function()
		local unlocked = TitleLogic.unlockedFor(LADDER, 1)
		TestRunner.expect(#unlocked):toBe(1)
		TestRunner.expect(unlocked[1].id):toBe("got-one")
	end)

	TestRunner.it("unlocks every rung at or below the streak, lowest first", function()
		local unlocked = TitleLogic.unlockedFor(LADDER, 20)
		TestRunner.expect(#unlocked):toBe(3)
		TestRunner.expect(unlocked[1].id):toBe("got-one")
		TestRunner.expect(unlocked[3].id):toBe("menace")
	end)

	TestRunner.it("sorts by threshold rather than by registry order", function()
		-- Registry order follows filenames, and the ladder must not.
		local shuffled: { TitleLogic.TitleDef } = {
			LADDER[3],
			LADDER[1],
			LADDER[2],
		}
		local unlocked = TitleLogic.unlockedFor(shuffled, 100)
		TestRunner.expect(unlocked[1].minStreak):toBe(1)
		TestRunner.expect(unlocked[2].minStreak):toBe(5)
		TestRunner.expect(unlocked[3].minStreak):toBe(15)
	end)

	TestRunner.it("unlocks the whole ladder at an absurd streak", function()
		TestRunner.expect(#TitleLogic.unlockedFor(LADDER, 500)):toBe(5)
	end)
end)

TestRunner.describe("TitleLogic - permanence", function()
	TestRunner.it("is a function of bestStreak alone, so a reset cannot revoke anything", function()
		-- The signature is the guarantee: there is no currentStreak
		-- parameter to pass a zero into. A player whose streak just
		-- reset still has bestStreak 60, and still has four rungs.
		local afterAReset = TitleLogic.unlockedFor(LADDER, 60)
		TestRunner.expect(#afterAReset):toBe(4)
		TestRunner.expect(afterAReset[4].id):toBe("final-boss")
	end)

	TestRunner.it("exposes no way to remove an unlocked title", function()
		-- Stated as a test so that adding one trips something. If this
		-- ever fails, read P4-2's brief again before "fixing" it.
		TestRunner.expect((TitleLogic :: any).revoke):toBe(nil)
		TestRunner.expect((TitleLogic :: any).lock):toBe(nil)
		TestRunner.expect((TitleLogic :: any).clear):toBe(nil)
	end)
end)

TestRunner.describe("TitleLogic.newlyUnlocked", function()
	TestRunner.it("reports the rung just crossed", function()
		local crossed = TitleLogic.newlyUnlocked(LADDER, 4, 5)
		TestRunner.expect(#crossed):toBe(1)
		TestRunner.expect(crossed[1].id):toBe("hot-streak")
	end)

	TestRunner.it("reports nothing when no threshold was crossed", function()
		TestRunner.expect(#TitleLogic.newlyUnlocked(LADDER, 5, 6)):toBe(0)
	end)

	TestRunner.it("reports every rung crossed by a single large jump", function()
		-- A profile migration, or a config edit adding a rung below
		-- where a player already is. Firing one notification and
		-- dropping the rest would leave titles nobody was told about.
		local crossed = TitleLogic.newlyUnlocked(LADDER, 0, 60)
		TestRunner.expect(#crossed):toBe(4)
		TestRunner.expect(crossed[1].id):toBe("got-one")
		TestRunner.expect(crossed[4].id):toBe("final-boss")
	end)

	TestRunner.it("is exclusive at the bottom and inclusive at the top", function()
		-- (previousBest, newBest]: a rung already held is not re-fired.
		TestRunner.expect(#TitleLogic.newlyUnlocked(LADDER, 5, 15)):toBe(1)
		TestRunner.expect(#TitleLogic.newlyUnlocked(LADDER, 4, 15)):toBe(2)
	end)

	TestRunner.it("reports nothing for a bestStreak that went backwards", function()
		-- Cannot happen (P4-1 never lowers bestStreak), but a
		-- recomputation must stay harmless rather than erroring.
		TestRunner.expect(#TitleLogic.newlyUnlocked(LADDER, 60, 5)):toBe(0)
	end)
end)

TestRunner.describe("TitleLogic.highestUnlocked", function()
	TestRunner.it("returns the top rung reached", function()
		TestRunner.expect((TitleLogic.highestUnlocked(LADDER, 70) :: any).id):toBe("final-boss")
	end)

	TestRunner.it("returns nil below the first rung", function()
		TestRunner.expect(TitleLogic.highestUnlocked(LADDER, 0)):toBe(nil)
	end)
end)

TestRunner.describe("TitleLogic.canEquip", function()
	TestRunner.it("allows a title the player has unlocked", function()
		TestRunner.expect(TitleLogic.canEquip({ "got-one", "hot-streak" }, "hot-streak")):toBe(true)
	end)

	TestRunner.it("refuses a title the player has not unlocked", function()
		TestRunner.expect(TitleLogic.canEquip({ "got-one" }, "touch-grass")):toBe(false)
	end)

	TestRunner.it("always allows unequipping", function()
		-- Putting a title away is not the same as losing it.
		TestRunner.expect(TitleLogic.canEquip({}, nil)):toBe(true)
	end)
end)

TestRunner.describe("TitleLogic.isVisibleInState - design-decisions.md Q7", function()
	TestRunner.it("shows titles in the pre-round lobby and after the result", function()
		TestRunner.expect(TitleLogic.isVisibleInState("WaitingForPlayers", false)):toBe(true)
		TestRunner.expect(TitleLogic.isVisibleInState("Results", false)):toBe(true)
		TestRunner.expect(TitleLogic.isVisibleInState("Cleanup", false)):toBe(true)
	end)

	TestRunner.it("hides them for every live-round state", function()
		-- Q7 condition 1 names "nameplate" specifically, and a title
		-- maps to a bestStreak threshold.
		for _, state in { "Loading", "Intro", "Race", "Qualified" } do
			TestRunner.expect(TitleLogic.isVisibleInState(state, false)):toBe(false)
		end
	end)

	TestRunner.it("hides them in the Decision Studio too", function()
		-- Three finalists reading each other's rungs would learn who
		-- needs the win, in the one phase where that's worth most.
		TestRunner.expect(TitleLogic.isVisibleInState("DecisionStudio", false)):toBe(false)
	end)

	TestRunner.it("shows them everywhere when the config flag is flipped", function()
		for _, state in { "Race", "DecisionStudio", "Qualified" } do
			TestRunner.expect(TitleLogic.isVisibleInState(state, true)):toBe(true)
		end
	end)

	TestRunner.it("hides them in an unrecognised state rather than defaulting to visible", function()
		-- A round state added later must not leak by omission.
		TestRunner.expect(TitleLogic.isVisibleInState("SomeFutureState", false)):toBe(false)
	end)
end)

TestRunner.describe("TitleLogic.pickNPCTitle", function()
	TestRunner.it("gives no title at all below the no-title chance", function()
		TestRunner.expect(TitleLogic.pickNPCTitle(LADDER, 0.1, 0.35, 2)):toBe(nil)
	end)

	TestRunner.it("never hands a bot one of the excluded top rungs", function()
		-- A bot wearing the rarest title in the game is MORE obviously
		-- fake than a bot wearing nothing.
		for step = 0, 100 do
			local def = TitleLogic.pickNPCTitle(LADDER, step / 100, 0.35, 2)
			if def ~= nil then
				assert(
					def.id ~= "final-boss" and def.id ~= "touch-grass",
					string.format("roll %.2f handed a bot %q", step / 100, def.id)
				)
			end
		end
	end)

	TestRunner.it("weights the low rungs more heavily than the high ones", function()
		local counts: { [string]: number } = {}
		for step = 0, 999 do
			local def = TitleLogic.pickNPCTitle(LADDER, step / 1000, 0.35, 2)
			if def ~= nil then
				counts[def.id] = (counts[def.id] or 0) + 1
			end
		end
		assert(
			(counts["got-one"] or 0) > (counts["menace"] or 0),
			"expected the first rung to be more common than the third"
		)
	end)

	TestRunner.it("returns nil when every rung is excluded", function()
		TestRunner.expect(TitleLogic.pickNPCTitle(LADDER, 0.9, 0, 5)):toBe(nil)
	end)

	TestRunner.it("is deterministic for a given roll", function()
		local first = TitleLogic.pickNPCTitle(LADDER, 0.6, 0.35, 2)
		local second = TitleLogic.pickNPCTitle(LADDER, 0.6, 0.35, 2)
		TestRunner.expect((first :: any).id):toBe((second :: any).id)
	end)
end)

TestRunner.describe("TitleLogic.findById", function()
	TestRunner.it("finds a rung by id", function()
		TestRunner.expect((TitleLogic.findById(LADDER, "menace") :: any).minStreak):toBe(15)
	end)

	TestRunner.it("returns nil for an unknown id or a nil id", function()
		TestRunner.expect(TitleLogic.findById(LADDER, "no-such-title")):toBe(nil)
		TestRunner.expect(TitleLogic.findById(LADDER, nil)):toBe(nil)
	end)
end)
