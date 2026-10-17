--!strict
-- Covers GuessViewLogic.luau: the Guess Token picker's own state (one
-- guess, final once the server acks it, refused on silence), when it
-- shows, and what it says (payoff-loop step 2c).

local TestRunner = require("./TestRunner")
local GuessViewLogic = require("../src/client/UI/GuessViewLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local step = GuessViewLogic.step
local OPEN = GuessViewLogic.OPEN

local function nameOf(id: number): string
	return if id == -1 then "Bot Bea" else "Alex"
end

describe("GuessViewLogic.step", function()
	it("sends a tap, then locks on the server's ack", function()
		local sending = step(OPEN, { type = "Pick", targetId = 7 })
		expect(sending.status):toBe("Sending")
		expect(sending.targetId):toBe(7)
		local locked = step(sending, { type = "Ack", targetId = 7 })
		expect(locked.status):toBe("Locked")
		expect(locked.targetId):toBe(7)
	end)

	it("takes one guess only: a second tap while sending or locked does nothing", function()
		local sending = step(OPEN, { type = "Pick", targetId = 7 })
		expect(step(sending, { type = "Pick", targetId = -1 })):toBe(sending)
		local locked = step(sending, { type = "Ack", targetId = 7 })
		expect(step(locked, { type = "Pick", targetId = -1 })):toBe(locked)
		expect(step(locked, { type = "Ack", targetId = -1 })):toBe(locked)
	end)

	it("reads silence as a refusal, and a late ack still locks it in", function()
		local refused = step(step(OPEN, { type = "Pick", targetId = 7 }), { type = "Timeout" })
		expect(refused.status):toBe("Refused")
		expect(GuessViewLogic.canPick(refused)):toBe(false)
		expect(step(refused, { type = "Ack", targetId = 7 }).status):toBe("Locked")
	end)

	it("trusts the ack's target over the tapped one", function()
		local sending = step(OPEN, { type = "Pick", targetId = 7 })
		expect(step(sending, { type = "Ack", targetId = -1 }).targetId):toBe(-1)
	end)

	it("ignores a timeout that isn't waiting on anything", function()
		expect(step(OPEN, { type = "Timeout" })):toBe(OPEN)
		local locked = step(step(OPEN, { type = "Pick", targetId = 7 }), { type = "Ack", targetId = 7 })
		expect(step(locked, { type = "Timeout" })):toBe(locked)
	end)
end)

describe("GuessViewLogic.visible", function()
	it("shows only to a knocked-out racer, from the Studio's start until the reveal", function()
		expect(GuessViewLogic.visible(false, true, true, false)):toBe(true)
		expect(GuessViewLogic.visible(true, true, true, false)):toBe(false) -- a finalist
		expect(GuessViewLogic.visible(false, false, true, false)):toBe(false) -- joined to watch
		expect(GuessViewLogic.visible(false, true, false, false)):toBe(false) -- no phase yet
		expect(GuessViewLogic.visible(false, true, true, true)):toBe(false) -- the reveal is on
	end)
end)

describe("GuessViewLogic cards and copy", function()
	it("marks the picked card and dims the rest once the guess is out", function()
		expect(GuessViewLogic.cardState(OPEN, 7)):toBe("Pickable")
		local sending = step(OPEN, { type = "Pick", targetId = -1 })
		expect(GuessViewLogic.cardState(sending, -1)):toBe("Picked") -- NPC seats count
		expect(GuessViewLogic.cardState(sending, 7)):toBe("Dimmed")
	end)

	it("says what happened to the guess", function()
		expect(GuessViewLogic.title(OPEN)):toBe("Who walks out?")
		local locked = step(step(OPEN, { type = "Pick", targetId = -1 }), { type = "Ack", targetId = -1 })
		expect(GuessViewLogic.title(locked)):toBe("Your Guess Token")
		expect(GuessViewLogic.line(locked, nameOf)):toBe("Your guess: Bot Bea. Locked in.")
		local refused = step(step(OPEN, { type = "Pick", targetId = 7 }), { type = "Timeout" })
		expect(GuessViewLogic.line(refused, nameOf)):toBe("Your guess didn't go through this round.")
	end)
end)
