--!strict
-- Covers RecordViewLogic.luau: the Hub's "Your record" panel (payoff-loop
-- step 7) - reading StoreState.record and what the panel says.

local TestRunner = require("./TestRunner")
local RecordViewLogic = require("../src/client/UI/RecordViewLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

describe("RecordViewLogic.parse", function()
	it("reads a well-formed record", function()
		local r = RecordViewLogic.parse({ steals = 2, shares = 5, betrayed = 1 }) :: RecordViewLogic.Record
		expect(r.steals):toBe(2)
		expect(r.shares):toBe(5)
		expect(r.betrayed):toBe(1)
	end)

	it("hides the button off the Hub or on junk", function()
		expect(RecordViewLogic.parse(nil)):toBe(nil)
		expect(RecordViewLogic.parse({ steals = 2, shares = 5 })):toBe(nil)
		expect(RecordViewLogic.parse({ steals = -1, shares = 5, betrayed = 0 })):toBe(nil)
		expect(RecordViewLogic.parse({ steals = 0 / 0, shares = 5, betrayed = 0 })):toBe(nil)
	end)
end)

describe("RecordViewLogic.body", function()
	it("invites a first-timer to the Studio", function()
		local body = RecordViewLogic.body({ steals = 0, shares = 0, betrayed = 0 })
		expect(string.find(body, "No Studio choices yet", 1, true) ~= nil):toBe(true)
	end)

	it("lists shares, steals and times robbed", function()
		local body = RecordViewLogic.body({ steals = 3, shares = 7, betrayed = 2 })
		expect(string.find(body, "Shared: 7", 1, true) ~= nil):toBe(true)
		expect(string.find(body, "Stole: 3", 1, true) ~= nil):toBe(true)
		expect(string.find(body, "Robbed: 2×", 1, true) ~= nil):toBe(true)
	end)

	it("says so when never robbed", function()
		local body = RecordViewLogic.body({ steals = 3, shares = 7, betrayed = 0 })
		expect(string.find(body, "Never robbed yet.", 1, true) ~= nil):toBe(true)
	end)
end)
