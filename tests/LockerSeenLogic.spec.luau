--!strict
-- Covers LockerSeenLogic.luau: which Locker tabs hold something new, and
-- what opening one marks seen. DataService and the Locker's dots
-- themselves are exercised in Studio.

local TestRunner = require("./TestRunner")
local LockerSeenLogic = require("../src/server/LockerSeenLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local NONE: LockerSeenLogic.Seen = { Power = {}, Style = {}, Titles = {} }

describe("LockerSeenLogic.held", function()
	it("is the power-ups with stock, sorted", function()
		expect(table.concat(LockerSeenLogic.held({ Freeze = 1, Banana = 0, Dash = 3 }), ",")):toBe("Dash,Freeze")
		expect(#LockerSeenLogic.held({})):toBe(0)
	end)
end)

describe("LockerSeenLogic.unseen", function()
	it("dots only the tabs holding something not yet seen", function()
		local owned = LockerSeenLogic.owned({ Freeze = 1 }, { "GoldTrail" }, {})
		local seen: LockerSeenLogic.Seen = { Power = { "Freeze" }, Style = {}, Titles = {} }
		local unseen = LockerSeenLogic.unseen(owned, seen)
		expect(unseen.Power):toBe(false)
		expect(unseen.Style):toBe(true)
		expect(unseen.Titles):toBe(false)
	end)

	it("dots nothing when nothing is owned", function()
		local unseen = LockerSeenLogic.unseen(LockerSeenLogic.owned({}, {}, {}), NONE)
		expect(unseen.Power or unseen.Style or unseen.Titles):toBe(false)
	end)

	it("doesn't count a power-up that ran out", function()
		local owned = LockerSeenLogic.owned({ Freeze = 0 }, {}, {})
		expect(LockerSeenLogic.unseen(owned, NONE).Power):toBe(false)
	end)
end)

describe("LockerSeenLogic.markSeen", function()
	it("adds what's owned, keeping what was seen, once each", function()
		local seen = { "Freeze" }
		local marked = LockerSeenLogic.markSeen(seen, { "Dash", "Freeze", "Dash" })
		expect(table.concat(marked, ",")):toBe("Freeze,Dash")
		expect(#seen):toBe(1) -- a fresh list, not the one passed in
	end)

	it("keeps a power-up seen after it runs out, so it isn't new again", function()
		local seen = LockerSeenLogic.markSeen({}, LockerSeenLogic.held({ Freeze = 1 }))
		seen = LockerSeenLogic.markSeen(seen, LockerSeenLogic.held({ Freeze = 0 }))
		expect(LockerSeenLogic.anyUnseen(LockerSeenLogic.held({ Freeze = 2 }), seen)):toBe(false)
	end)
end)
