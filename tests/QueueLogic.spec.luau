--!strict
-- Covers the hub's Play button (QueueLogic): which intent a tap sends,
-- whether the player is still in line, and what the card says. The
-- card itself is reviewed in Studio (QueueController).

local QueueLogic = require("../src/client/UI/QueueLogic")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function after(...: any): QueueLogic.State
	local s = QueueLogic.new()
	for _, payload in { ... } do
		s = QueueLogic.apply(s, payload)
	end
	return s
end

describe("QueueLogic.apply", function()
	it("starts idle, offering Play", function()
		local v = QueueLogic.view(QueueLogic.new())
		expect(v.action):toBe("Join")
		expect(v.actionLabel):toBe("Play")
		expect(v.busy):toBe(false)
	end)

	it("offers Leave once joining or waiting", function()
		expect(QueueLogic.actionFor(after({ status = "Joining" }))):toBe("Leave")
		expect(QueueLogic.actionFor(after({ status = "Joining" }, { status = "Waiting" }))):toBe("Leave")
	end)

	it("offers no button once the match is committed", function()
		expect(QueueLogic.actionFor(after({ status = "Waiting" }, { status = "MatchFound" }))):toBe(nil)
		expect(QueueLogic.actionFor(after({ status = "Travelling" }))):toBe(nil)
	end)

	it("keeps a waiting player in line through an outage", function()
		local s = after({ status = "Waiting" }, { status = "Unavailable", message = "hang tight" })
		expect(s.queued):toBe(true)
		expect(QueueLogic.view(s).action):toBe("Leave")
		expect(QueueLogic.apply(s, { status = "Unavailable" }).queued):toBe(true)
	end)

	it("treats a refused or failed join as not queued", function()
		expect(after({ status = "Unavailable" }).queued):toBe(false)
		expect(after({ status = "Joining" }, { status = "Unavailable" }).queued):toBe(false)
	end)

	it("returns to Play on Idle, keeping a requeue message", function()
		local s = after({ status = "Travelling" }, { status = "Idle", message = "Teleport failed" })
		local v = QueueLogic.view(s)
		expect(v.action):toBe("Join")
		expect(v.detail):toBe("Teleport failed")
	end)

	it("ignores malformed payloads", function()
		local s = after({ status = "Waiting" })
		expect(QueueLogic.apply(s, nil)):toBe(s)
		expect(QueueLogic.apply(s, { status = "Bogus" })):toBe(s)
		expect(QueueLogic.apply(s, { status = 3 })):toBe(s)
	end)

	it("keeps the last numbers across a bare Waiting", function()
		local s = after(
			{ status = "Waiting", position = 2, queueSize = 5, estimatedWaitSeconds = 20 },
			{ status = "Waiting" }
		)
		expect(s.position):toBe(2)
		expect(s.queueSize):toBe(5)
		expect(s.estimatedWaitSeconds):toBe(20)
	end)

	it("drops bad numbers rather than showing them", function()
		local s = after({ status = "Waiting", position = -1, queueSize = 0 / 0, estimatedWaitSeconds = math.huge })
		expect(s.position):toBe(nil)
		expect(s.queueSize):toBe(nil)
		expect(s.estimatedWaitSeconds):toBe(nil)
	end)
end)

describe("QueueLogic.tap", function()
	it("fires the intent once and waits for the server", function()
		local s, intent = QueueLogic.tap(QueueLogic.new(), 10)
		expect(intent):toBe("Join")
		expect(QueueLogic.view(s).busy):toBe(true)
		local _, again = QueueLogic.tap(s, 11)
		expect(again):toBe(nil)
	end)

	it("clears the spinner when the server answers", function()
		local s = QueueLogic.tap(QueueLogic.new(), 10)
		s = QueueLogic.apply(s, { status = "Waiting" })
		expect(s.pendingSince):toBe(nil)
		expect(QueueLogic.view(s).busy):toBe(false)
	end)

	it("gives up on an unanswered tap after the timeout", function()
		local s = QueueLogic.tap(QueueLogic.new(), 10)
		expect(QueueLogic.tick(s, 10 + QueueLogic.PENDING_TIMEOUT - 0.1).pendingSince):toBe(10)
		expect(QueueLogic.tick(s, 10 + QueueLogic.PENDING_TIMEOUT).pendingSince):toBe(nil)
		local _, intent = QueueLogic.tap(s, 10 + QueueLogic.PENDING_TIMEOUT)
		expect(intent):toBe("Join")
	end)

	it("sends Leave when queued and nothing when committed", function()
		local _, leave = QueueLogic.tap(after({ status = "Waiting" }), 0)
		expect(leave):toBe("Leave")
		local _, none = QueueLogic.tap(after({ status = "MatchFound" }), 0)
		expect(none):toBe(nil)
	end)
end)

describe("QueueLogic.view", function()
	it("shows place, size and wait while waiting", function()
		local v = QueueLogic.view(after({
			status = "Waiting",
			position = 2,
			queueSize = 5,
			queueSizeIsLowerBound = true,
			estimatedWaitSeconds = 20,
		}))
		expect(v.detail):toBe("#2 of 5+  ·  ~20s")
		expect(v.board):toBe("In line  #2 of 5+  ·  ~20s")
	end)

	it("marks match found as success and outages as warnings", function()
		expect(QueueLogic.view(after({ status = "MatchFound" })).tone):toBe("success")
		expect(QueueLogic.view(after({ status = "Unavailable" })).tone):toBe("warning")
	end)

	it("formats waits, rounding up", function()
		expect(QueueLogic.formatWait(0)):toBe("~1s")
		expect(QueueLogic.formatWait(19.2)):toBe("~20s")
		expect(QueueLogic.formatWait(60)):toBe("~1 min")
		expect(QueueLogic.formatWait(61)):toBe("~2 min")
	end)
end)

describe("QueueLogic.view on a practice server", function()
	it("says nothing is at stake before you queue, and who you're waiting for after", function()
		local idle = QueueLogic.view(QueueLogic.new(), true)
		expect(idle.detail):toBe("Practice server: no streak, coins or stats at stake.")
		expect(idle.board):toBe("Tap PLAY for a practice match")
		local waiting = QueueLogic.view(after({ status = "Waiting" }), true)
		expect(waiting.headline):toBe("Waiting for your friends...")
	end)

	it("keeps a return message over the practice note", function()
		local back = QueueLogic.view(after({ status = "Idle", message = "Round over." }), true)
		expect(back.detail):toBe("Round over.")
	end)

	it("changes nothing on a public server", function()
		expect(QueueLogic.view(QueueLogic.new()).board):toBe("Tap PLAY to join")
	end)
end)
