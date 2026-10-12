--!strict
-- Covers EventLogic.luau: starting, reading and ordering the live event
-- and its audit log (staff-tools.md step 5). EventService itself touches
-- a DataStore and MessagingService, so it's exercised in Studio.

local TestRunner = require("./TestRunner")
local EventLogic = require("../src/server/EventLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local EVENTS: { EventLogic.EventInfo } = {
	{ id = "taco", enabled = true, displayName = "Taco Tuesday" },
	{ id = "off", enabled = false, displayName = "Old Event" },
}

describe("EventLogic.checkStart", function()
	it("accepts a shipped, enabled event for whole minutes in range", function()
		expect((EventLogic.checkStart("taco", 60, EVENTS) :: any).id):toBe("taco")
		expect((EventLogic.checkStart("taco", 1, EVENTS) :: any).id):toBe("taco")
		expect((EventLogic.checkStart("taco", EventLogic.MAX_MINUTES, EVENTS) :: any).id):toBe("taco")
	end)

	it("refuses an unknown or switched-off event", function()
		expect(EventLogic.checkStart("nope", 60, EVENTS)):toBe(nil)
		local event, why = EventLogic.checkStart("off", 60, EVENTS)
		expect(event):toBe(nil)
		expect(why ~= nil):toBe(true)
	end)

	it("refuses minutes that aren't a whole number from 1 to the cap", function()
		for _, minutes in { 0, -5, 1.5, EventLogic.MAX_MINUTES + 1, "60", nil :: any } do
			expect(EventLogic.checkStart("taco", minutes, EVENTS)):toBe(nil)
		end
	end)
end)

describe("EventLogic.parseState", function()
	it("keeps a well-formed record", function()
		local state = EventLogic.parseState({
			version = 2,
			id = "taco",
			startedAt = 10,
			endsAt = 70,
			by = 7,
			extra = true,
		}) :: any
		expect(state.id):toBe("taco")
		expect(state.endsAt):toBe(70)
		expect(state.extra):toBe(nil)
	end)

	it("reads anything malformed as no event", function()
		expect(EventLogic.parseState(nil)):toBe(nil)
		expect(EventLogic.parseState("taco")):toBe(nil)
		expect(EventLogic.parseState({ version = 1, id = "taco", startedAt = 10, by = 7 })):toBe(nil)
		expect(EventLogic.parseState({ version = 1, id = 5, startedAt = 10, endsAt = 70, by = 7 })):toBe(nil)
		expect(EventLogic.parseState({ id = "taco", startedAt = 10, endsAt = 70, by = 7 })):toBe(nil)
	end)
end)

describe("EventLogic.activeId", function()
	local state = EventLogic.start(nil, "taco", 30, 7, 1000)

	it("runs for exactly the minutes asked", function()
		expect(state.endsAt):toBe(1000 + 30 * 60)
		expect(EventLogic.activeId(state, 1000, EVENTS)):toBe("taco")
		expect(EventLogic.activeId(state, state.endsAt - 1, EVENTS)):toBe("taco")
		expect(EventLogic.activeId(state, state.endsAt, EVENTS)):toBe(nil)
	end)

	it("shows nothing with no state, or for an event no longer shipped or enabled", function()
		expect(EventLogic.activeId(nil, 1000, EVENTS)):toBe(nil)
		expect(EventLogic.activeId(EventLogic.start(nil, "gone", 30, 7, 1000), 1000, EVENTS)):toBe(nil)
		expect(EventLogic.activeId(EventLogic.start(nil, "off", 30, 7, 1000), 1000, EVENTS)):toBe(nil)
	end)

	it("ends at once when stopped", function()
		local stop = EventLogic.stop(state, 9, 1200)
		expect(EventLogic.activeId(stop, 1200, EVENTS)):toBe(nil)
		expect(stop.by):toBe(9)
		expect(stop.version):toBe(state.version + 1)
	end)
end)

describe("EventLogic.newer", function()
	local first = EventLogic.start(nil, "taco", 30, 7, 1000)
	local second = EventLogic.start(first, "taco", 60, 7, 2000)

	it("keeps the later change, whichever order they arrive in", function()
		expect(EventLogic.newer(first, second)):toBe(second)
		expect(EventLogic.newer(second, first)):toBe(second)
		expect(EventLogic.newer(nil, first)):toBe(first)
		expect(EventLogic.newer(first, nil)):toBe(first)
	end)

	it("lets a stop beat the start it ends, even in the same second", function()
		local stop = EventLogic.stop(first, 7, 1000)
		expect(EventLogic.newer(first, stop)):toBe(stop)
		-- A stale read of the start arriving after the stop doesn't revive it.
		expect(EventLogic.activeId(EventLogic.newer(stop, first), 1000, EVENTS)):toBe(nil)
		-- And a restart in that same second beats the stop.
		local again = EventLogic.start(stop, "taco", 30, 7, 1000)
		expect(EventLogic.newer(stop, again)):toBe(again)
	end)
end)

describe("EventLogic.appendAudit", function()
	it("appends, drops junk and keeps the newest `cap` entries", function()
		local log: any = { "junk", { at = 1 } }
		for i = 2, 4 do
			log = EventLogic.appendAudit(log, { at = i, staffUserId = 7, action = "Start", eventId = "taco" }, 3)
		end
		expect(#log):toBe(3)
		expect(log[1].at):toBe(2)
		expect(log[3].at):toBe(4)
		expect(#EventLogic.appendAudit(nil, { at = 1, staffUserId = 7, action = "Stop" }, 3)):toBe(1)
	end)
end)
