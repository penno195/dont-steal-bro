--!strict
-- Covers Participants.luau (P3-5): the roster every race-side service
-- keys its state on. The properties asserted here are the ones the
-- no-NPC-branch design rests on - if the negative-id guarantee or the
-- human/NPC invariant breaks, an NPC stops being indistinguishable from
-- a player to TaskService, and the branching architecture.md §4 forbids
-- comes back.
--
-- A Player/Model is only ever stored and handed back, never touched, so
-- the fakes below are plain tables - the same approach ProfileLogic.
-- spec.luau takes.

local TestRunner = require("./TestRunner")
local Participants = require("../src/server/Participants")

local function fakePlayer(userId: number): any
	return { UserId = userId, Name = "player" .. userId }
end

local function human(userId: number)
	return Participants.register({
		id = userId,
		displayName = "Player" .. userId,
		isNPC = false,
		player = fakePlayer(userId) :: any,
		character = nil,
	})
end

local function npc()
	local id = Participants.allocateNPCId()
	return Participants.register({
		id = id,
		displayName = "Rapid Gecko0" .. math.abs(id),
		isNPC = true,
		player = nil,
		character = nil,
	})
end

TestRunner.describe("Participants - NPC ids", function()
	TestRunner.it("hands out only negative ids, which no real UserId can be", function()
		Participants.resetForTesting()
		for _ = 1, 10 do
			local id = Participants.allocateNPCId()
			assert(id < 0, string.format("%d is not negative", id))
			TestRunner.expect(Participants.isNPCId(id)):toBe(true)
		end
	end)

	TestRunner.it("never hands out the same id twice, even after one is unregistered", function()
		Participants.resetForTesting()
		local first = npc()
		Participants.unregister(first.id)
		local second = npc()
		assert(second.id ~= first.id, "expected a freed NPC id never to be reused")
	end)

	TestRunner.it("classifies a real UserId as human", function()
		TestRunner.expect(Participants.isNPCId(1234567)):toBe(false)
	end)
end)

TestRunner.describe("Participants - registration", function()
	TestRunner.it("finds a registered participant by id", function()
		Participants.resetForTesting()
		human(42)
		local found = Participants.get(42)
		TestRunner.expect(found ~= nil):toBe(true)
		TestRunner.expect((found :: any).displayName):toBe("Player42")
	end)

	TestRunner.it("crosses over from a Player to its participant", function()
		Participants.resetForTesting()
		local registered = human(7)
		local found = Participants.fromPlayer(fakePlayer(7) :: any)
		TestRunner.expect(found):toBe(registered)
	end)

	TestRunner.it("refuses a duplicate id rather than silently replacing the entry", function()
		Participants.resetForTesting()
		human(1)
		local ok = pcall(human, 1)
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("refuses a human with no Player - the field consumers branch on", function()
		Participants.resetForTesting()
		local ok = pcall(function()
			Participants.register({ id = 5, displayName = "x", isNPC = false, player = nil, character = nil })
		end)
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("refuses an NPC that carries a Player", function()
		Participants.resetForTesting()
		local ok = pcall(function()
			Participants.register({
				id = -99,
				displayName = "x",
				isNPC = true,
				player = fakePlayer(3) :: any,
				character = nil,
			})
		end)
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("unregistering an unknown id is a no-op, not an error", function()
		Participants.resetForTesting()
		Participants.unregister(123)
		TestRunner.expect(#Participants.all()):toBe(0)
	end)
end)

TestRunner.describe("Participants - the roster", function()
	TestRunner.it("counts humans and NPCs separately", function()
		Participants.resetForTesting()
		human(1)
		human(2)
		npc()
		TestRunner.expect(Participants.countHumans()):toBe(2)
		TestRunner.expect(Participants.countNPCs()):toBe(1)
		TestRunner.expect(#Participants.all()):toBe(3)
	end)

	TestRunner.it("iterates in insertion order, not hash order", function()
		Participants.resetForTesting()
		human(30)
		human(10)
		human(20)
		local all = Participants.all()
		TestRunner.expect(all[1].id):toBe(30)
		TestRunner.expect(all[2].id):toBe(10)
		TestRunner.expect(all[3].id):toBe(20)
	end)

	TestRunner.it("keeps its order after a removal from the middle", function()
		Participants.resetForTesting()
		human(1)
		human(2)
		human(3)
		Participants.unregister(2)
		local all = Participants.all()
		TestRunner.expect(#all):toBe(2)
		TestRunner.expect(all[1].id):toBe(1)
		TestRunner.expect(all[2].id):toBe(3)
	end)

	TestRunner.it("returns a fresh array each call, safe to hold across a mutation", function()
		Participants.resetForTesting()
		human(1)
		local snapshot = Participants.all()
		Participants.unregister(1)
		-- The caller's own copy is untouched; a scan mid-iteration can't
		-- have the roster pulled out from under it.
		TestRunner.expect(#snapshot):toBe(1)
		TestRunner.expect(#Participants.all()):toBe(0)
	end)

	TestRunner.it("splits the roster into humans and NPCs", function()
		Participants.resetForTesting()
		human(1)
		local bot = npc()
		human(2)

		local humans = Participants.humans()
		TestRunner.expect(#humans):toBe(2)
		TestRunner.expect(humans[1].id):toBe(1)

		local bots = Participants.npcs()
		TestRunner.expect(#bots):toBe(1)
		TestRunner.expect(bots[1].id):toBe(bot.id)
	end)
end)

TestRunner.describe("Participants - characters", function()
	TestRunner.it("updates a live character in place", function()
		Participants.resetForTesting()
		human(1)
		local rig = { Name = "rig" } :: any
		Participants.setCharacter(1, rig)
		TestRunner.expect((Participants.get(1) :: any).character):toBe(rig)
	end)

	TestRunner.it("clears one back to nil on respawn", function()
		Participants.resetForTesting()
		human(1)
		Participants.setCharacter(1, { Name = "rig" } :: any)
		Participants.setCharacter(1, nil)
		TestRunner.expect((Participants.get(1) :: any).character):toBe(nil)
	end)

	TestRunner.it("ignores a character set for an unknown id", function()
		Participants.resetForTesting()
		Participants.setCharacter(999, { Name = "rig" } :: any)
		TestRunner.expect(Participants.get(999)):toBe(nil)
	end)
end)
