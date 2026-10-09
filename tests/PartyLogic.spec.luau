--!strict
-- Covers PartyLogic.luau: practice parties (design-decisions.md Q7, the
-- "practice matches and parties" case). PartyService.luau itself needs
-- Players and remotes, so it is exercised in Studio instead.

local TestRunner = require("./TestRunner")
local PartyLogic = require("../src/server/PartyLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local CONFIG: PartyLogic.Config = { maxSize = 6, inviteTtlSeconds = 30 }

local function party(...: number): PartyLogic.State
	local ids = { ... }
	local state = PartyLogic.new()
	for i = 2, #ids do
		PartyLogic.invite(state, ids[1], ids[i], 0, CONFIG)
		PartyLogic.respond(state, ids[i], true, 0, CONFIG)
	end
	return state
end

describe("PartyLogic invites", function()
	it("forms a party when a solo player's invite is accepted, inviter leading", function()
		local state = PartyLogic.new()
		expect(PartyLogic.invite(state, 1, 2, 0, CONFIG)):toBe("Sent")
		local result, affected = PartyLogic.respond(state, 2, true, 5, CONFIG)
		expect(result):toBe("Joined")
		expect(#affected):toBe(2)
		local p = PartyLogic.partyFor(state, 2) :: PartyLogic.Party
		expect(p.leader):toBe(1)
		expect(PartyLogic.membersOf(state, 1)[2]):toBe(2)
	end)

	it("refuses inviting yourself, a member inviting, and anyone already partied", function()
		local state = party(1, 2)
		expect(PartyLogic.invite(state, 3, 3, 0, CONFIG)):toBe("Self")
		expect(PartyLogic.invite(state, 2, 3, 0, CONFIG)):toBe("NotLeader")
		expect(PartyLogic.invite(state, 1, 2, 0, CONFIG)):toBe("AlreadyInYourParty")
		expect(PartyLogic.invite(state, 4, 1, 0, CONFIG)):toBe("AlreadyInParty")
	end)

	it("caps a party at one match", function()
		local state = party(1, 2, 3, 4, 5, 6)
		expect(#PartyLogic.membersOf(state, 1)):toBe(6)
		expect(PartyLogic.invite(state, 1, 7, 0, CONFIG)):toBe("Full")
	end)

	it("lets an invite expire, and a decline joins nobody", function()
		local state = PartyLogic.new()
		PartyLogic.invite(state, 1, 2, 0, CONFIG)
		expect((PartyLogic.respond(state, 2, true, 31, CONFIG))):toBe("Expired")
		PartyLogic.invite(state, 1, 2, 40, CONFIG)
		expect((PartyLogic.respond(state, 2, false, 41, CONFIG))):toBe("Declined")
		expect(PartyLogic.partyFor(state, 1)):toBe(nil)
		expect((PartyLogic.respond(state, 2, true, 42, CONFIG))):toBe("NoInvite")
	end)

	it("refuses a stale invite from someone who now follows another leader", function()
		local state = PartyLogic.new()
		PartyLogic.invite(state, 1, 2, 0, CONFIG)
		PartyLogic.invite(state, 3, 1, 0, CONFIG)
		PartyLogic.respond(state, 1, true, 1, CONFIG)
		expect((PartyLogic.respond(state, 2, true, 2, CONFIG))):toBe("Gone")
	end)

	it("moves an accepting player out of a party they formed while invited", function()
		local state = PartyLogic.new()
		PartyLogic.invite(state, 1, 3, 0, CONFIG) -- pending while 3 forms their own
		PartyLogic.invite(state, 3, 4, 0, CONFIG)
		PartyLogic.respond(state, 4, true, 1, CONFIG)
		local result, affected = PartyLogic.respond(state, 3, true, 2, CONFIG)
		expect(result):toBe("Joined")
		expect(#affected):toBe(3) -- 3 and 4 from the old party, 1 from the new
		expect(PartyLogic.partyFor(state, 4)):toBe(nil) -- left alone, it dissolved
		expect((PartyLogic.partyFor(state, 3) :: PartyLogic.Party).leader):toBe(1)
	end)
end)

describe("PartyLogic leaving", function()
	it("hands a party to its next member when the leader leaves", function()
		local state = party(1, 2, 3)
		PartyLogic.leave(state, 1)
		expect((PartyLogic.partyFor(state, 2) :: PartyLogic.Party).leader):toBe(2)
		expect(PartyLogic.partyFor(state, 1)):toBe(nil)
	end)

	it("dissolves a party left with one member", function()
		local state = party(1, 2)
		local affected = PartyLogic.leave(state, 2)
		expect(#affected):toBe(2)
		expect(PartyLogic.partyFor(state, 1)):toBe(nil)
		expect(PartyLogic.membersOf(state, 1)[1]):toBe(1)
	end)

	it("clears invites to and from a player who leaves the server", function()
		local state = PartyLogic.new()
		PartyLogic.invite(state, 1, 2, 0, CONFIG)
		PartyLogic.invite(state, 3, 1, 0, CONFIG)
		PartyLogic.removePlayer(state, 1)
		expect(state.invites[2]):toBe(nil)
		expect(state.invites[1]):toBe(nil)
	end)
end)
