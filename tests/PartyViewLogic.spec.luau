--!strict
-- Covers the practice party's client rules (PartyViewLogic): which queue
-- buttons a player gets in and out of a party, when the invite prompt
-- is up, and who the party panel offers to invite. The panel and prompt
-- themselves are reviewed in Studio (PartyController).

local PartyViewLogic = require("../src/client/UI/PartyViewLogic")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local ME, FRIEND, OTHER = 1, 2, 3
local TTL = 30
local MAX = 6

local function party(leader: number, members: { number }): PartyViewLogic.State
	local s = PartyViewLogic.apply(PartyViewLogic.new(), { leaderId = leader, memberIds = members }, 0)
	return s
end

describe("PartyViewLogic.apply", function()
	it("reads a party and hands back the notice", function()
		local s, notice = PartyViewLogic.apply(
			PartyViewLogic.new(),
			{ leaderId = ME, memberIds = { ME, FRIEND }, notice = "Invite sent." },
			0
		)
		expect(s.leaderId):toBe(ME)
		expect(#s.memberIds):toBe(2)
		expect(notice):toBe("Invite sent.")
	end)

	it("ignores a malformed payload", function()
		local s = party(ME, { ME, FRIEND })
		expect(PartyViewLogic.apply(s, "nope", 1)):toBe(s)
		expect(PartyViewLogic.apply(s, { leaderId = ME }, 1)):toBe(s)
	end)

	it("drops ids that aren't user ids", function()
		local s = PartyViewLogic.apply(PartyViewLogic.new(), { memberIds = { ME, "x", 0, 1.5, 0 / 0, math.huge } }, 0)
		expect(#s.memberIds):toBe(1)
	end)

	it("accepts Studio's negative test-player ids", function()
		local s = PartyViewLogic.apply(PartyViewLogic.new(), { memberIds = {}, inviteFromId = -2 }, 5)
		expect(s.inviteFromId):toBe(-2)
		expect(PartyViewLogic.inviteOpen(s, 5, 30)):toBe(true)
	end)

	it("keeps an invite's clock across repeat pushes", function()
		local s = PartyViewLogic.apply(PartyViewLogic.new(), { memberIds = {}, inviteFromId = FRIEND }, 10)
		s = PartyViewLogic.apply(s, { memberIds = {}, inviteFromId = FRIEND }, 25)
		expect(s.inviteAt):toBe(10)
		s = PartyViewLogic.apply(s, { memberIds = {}, inviteFromId = OTHER }, 26)
		expect(s.inviteAt):toBe(26)
	end)
end)

describe("PartyViewLogic.queueButtons", function()
	it("offers Play and Practice when solo", function()
		local b = PartyViewLogic.queueButtons(PartyViewLogic.new(), ME, false)
		expect(b.play):toBe(true)
		expect(b.practice):toBe(true)
	end)

	it("offers the leader Practice only, never ranked", function()
		local b = PartyViewLogic.queueButtons(party(ME, { ME, FRIEND }), ME, false)
		expect(b.play):toBe(false)
		expect(b.practice):toBe(true)
		expect(b.note):toBeTruthy()
	end)

	it("offers a member no queue button at all", function()
		local b = PartyViewLogic.queueButtons(party(FRIEND, { FRIEND, ME }), ME, false)
		expect(b.play):toBe(false)
		expect(b.practice):toBe(false)
		expect(b.note):toBe("Your party leader starts the practice queue.")
	end)

	it("offers only Play on a private server, where it is practice", function()
		local b = PartyViewLogic.queueButtons(party(ME, { ME, FRIEND }), ME, true)
		expect(b.play):toBe(true)
		expect(b.practice):toBe(false)
		expect(PartyViewLogic.queueButtons(party(FRIEND, { FRIEND, ME }), ME, true).play):toBe(false)
	end)
end)

describe("PartyViewLogic.inviteOpen", function()
	it("is up until the invite's TTL runs out", function()
		local s = PartyViewLogic.apply(PartyViewLogic.new(), { memberIds = {}, inviteFromId = FRIEND }, 100)
		expect(PartyViewLogic.inviteOpen(s, 100, TTL)):toBe(true)
		expect(PartyViewLogic.inviteOpen(s, 100 + TTL, TTL)):toBe(false)
		expect(PartyViewLogic.inviteOpen(PartyViewLogic.new(), 0, TTL)):toBe(false)
	end)
end)

describe("PartyViewLogic.rowAction", function()
	it("lets a solo player or leader invite anyone not in the party", function()
		expect(PartyViewLogic.rowAction(PartyViewLogic.new(), ME, OTHER, MAX, nil, 0, TTL)):toBe("Invite")
		local s = party(ME, { ME, FRIEND })
		expect(PartyViewLogic.rowAction(s, ME, OTHER, MAX, nil, 0, TTL)):toBe("Invite")
		expect(PartyViewLogic.rowAction(s, ME, FRIEND, MAX, nil, 0, TTL)):toBe(nil)
		expect(PartyViewLogic.rowAction(s, ME, ME, MAX, nil, 0, TTL)):toBe(nil)
	end)

	it("shows Sent until the invite would have expired", function()
		local s = PartyViewLogic.new()
		expect(PartyViewLogic.rowAction(s, ME, OTHER, MAX, 50, 60, TTL)):toBe("Sent")
		expect(PartyViewLogic.rowAction(s, ME, OTHER, MAX, 50, 50 + TTL, TTL)):toBe("Invite")
	end)

	it("offers nothing to a member, or once the party is full", function()
		expect(PartyViewLogic.rowAction(party(FRIEND, { FRIEND, ME }), ME, OTHER, MAX, nil, 0, TTL)):toBe(nil)
		expect(PartyViewLogic.rowAction(party(ME, { ME, FRIEND }), ME, OTHER, 2, nil, 0, TTL)):toBe(nil)
	end)
end)

describe("PartyViewLogic.title", function()
	it("counts members once there is a party", function()
		expect(PartyViewLogic.title(PartyViewLogic.new(), MAX)):toBe("Party")
		expect(PartyViewLogic.title(party(ME, { ME, FRIEND }), MAX)):toBe("Party 2/6")
	end)
end)
