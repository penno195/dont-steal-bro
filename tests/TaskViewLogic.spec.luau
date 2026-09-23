--!strict
-- Covers the pure half of the task view framework (P6-4). The shell and
-- adapters themselves are reviewed on device (docs/task-views.md).

local TaskViewLogic = require("../src/client/UI/TaskViewLogic")
local TestRunner = require("./TestRunner")
local Tokens = require("../src/client/UI/Tokens")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local PHONE = { x = 0, y = 0, width = 390, height = 800 }
local MONITOR = { x = 0, y = 0, width = 1920, height = 1040 }
local AREA = { x = 24, y = 24, width = 342, height = 752 }
local CONFIG = { slop = 8, staleSeconds = 1.5 }

describe("TaskViewLogic.presentation", function()
	it("gives touch a sheet even on a big screen", function()
		expect(TaskViewLogic.presentation(MONITOR, true, 600)):toBe("Sheet")
	end)

	it("gives a small non-touch screen a sheet", function()
		expect(TaskViewLogic.presentation({ x = 0, y = 0, width = 900, height = 500 }, false, 600)):toBe("Sheet")
	end)

	it("gives a big mouse screen a window", function()
		expect(TaskViewLogic.presentation(MONITOR, false, 600)):toBe("Window")
	end)
end)

describe("TaskViewLogic edge margin", function()
	it("flags a rect inside the margin on any side", function()
		expect(TaskViewLogic.violatesEdge({ x = 10, y = 100, width = 50, height = 50 }, PHONE, 24)):toBe(true)
		expect(TaskViewLogic.violatesEdge({ x = 100, y = 760, width = 50, height = 30 }, PHONE, 24)):toBe(true)
		expect(TaskViewLogic.violatesEdge({ x = 340, y = 100, width = 40, height = 40 }, PHONE, 24)):toBe(true)
	end)

	it("accepts a rect exactly on the margin", function()
		expect(TaskViewLogic.violatesEdge({ x = 24, y = 24, width = 342, height = 752 }, PHONE, 24)):toBe(false)
	end)

	it("play area is the usable rect inset by the margin", function()
		local a = TaskViewLogic.playArea(PHONE, 24)
		expect(a.x):toBe(24)
		expect(a.width):toBe(342)
		expect(a.height):toBe(752)
	end)

	it("play area never goes negative on a tiny rect", function()
		local a = TaskViewLogic.playArea({ x = 0, y = 0, width = 30, height = 30 }, 24)
		expect(a.width):toBe(0)
		expect(a.height):toBe(0)
	end)
end)

describe("TaskViewLogic.inflate / pickTarget", function()
	it("grows a small visual to the minimum, centred", function()
		local r = TaskViewLogic.inflate({ x = 100, y = 100, width = 20, height = 20 }, 44, 0)
		expect(r.width):toBe(44)
		expect(r.x):toBe(88)
	end)

	it("adds the extra margin to a visual already past the minimum", function()
		local r = TaskViewLogic.inflate({ x = 100, y = 100, width = 60, height = 60 }, 44, 10)
		expect(r.width):toBe(80)
		expect(r.y):toBe(90)
	end)

	it("picks the nearest centre where inflated targets overlap", function()
		local targets = {
			a = { x = 0, y = 0, width = 100, height = 100 },
			b = { x = 80, y = 0, width = 100, height = 100 },
		}
		expect(TaskViewLogic.pickTarget(targets, { x = 95, y = 50 })):toBe("b")
		expect(TaskViewLogic.pickTarget(targets, { x = 60, y = 50 })):toBe("a")
		expect(TaskViewLogic.pickTarget(targets, { x = 500, y = 50 })):toBe(nil)
	end)

	it("breaks an exact tie by id, not table order", function()
		local targets = {
			b = { x = 0, y = 0, width = 100, height = 100 },
			a = { x = 0, y = 0, width = 100, height = 100 },
		}
		expect(TaskViewLogic.pickTarget(targets, { x = 50, y = 50 })):toBe("a")
	end)
end)

describe("TaskViewLogic drag", function()
	local finger, palm = {}, {}

	it("a lift before the slop is a tap", function()
		local d = TaskViewLogic.newDrag()
		TaskViewLogic.dragBegin(d, finger, { x = 100, y = 100 }, 0, AREA)
		TaskViewLogic.dragMove(d, finger, { x = 103, y = 102 }, 0.1, AREA, CONFIG)
		expect(TaskViewLogic.dragEnd(d, finger, { x = 103, y = 102 }, AREA).kind):toBe("Tap")
	end)

	it("a lift after travelling is a drop", function()
		local d = TaskViewLogic.newDrag()
		TaskViewLogic.dragBegin(d, finger, { x = 100, y = 100 }, 0, AREA)
		TaskViewLogic.dragMove(d, finger, { x = 200, y = 300 }, 0.1, AREA, CONFIG)
		local out = TaskViewLogic.dragEnd(d, finger, { x = 200, y = 300 }, AREA)
		expect(out.kind):toBe("Drop")
	end)

	it("ignores a second finger mid-drag", function()
		local d = TaskViewLogic.newDrag()
		TaskViewLogic.dragBegin(d, finger, { x = 100, y = 100 }, 0, AREA)
		expect(TaskViewLogic.dragBegin(d, palm, { x = 300, y = 700 }, 0.05, AREA).kind):toBe("Ignored")
		expect(TaskViewLogic.dragMove(d, palm, { x = 310, y = 700 }, 0.1, AREA, CONFIG).kind):toBe("Ignored")
		expect(TaskViewLogic.dragEnd(d, palm, { x = 310, y = 700 }, AREA).kind):toBe("Ignored")
		-- The owning finger still completes its drag.
		TaskViewLogic.dragMove(d, finger, { x = 150, y = 200 }, 0.2, AREA, CONFIG)
		expect(TaskViewLogic.dragEnd(d, finger, { x = 150, y = 200 }, AREA).kind):toBe("Drop")
	end)

	it("ignores a press that starts in the edge margin", function()
		local d = TaskViewLogic.newDrag()
		expect(TaskViewLogic.dragBegin(d, finger, { x = 5, y = 400 }, 0, AREA).kind):toBe("Ignored")
	end)

	it("clamps the ghost to the play area", function()
		local d = TaskViewLogic.newDrag()
		TaskViewLogic.dragBegin(d, finger, { x = 100, y = 100 }, 0, AREA)
		local out = TaskViewLogic.dragMove(d, finger, { x = -50, y = 100 }, 0.1, AREA, CONFIG) :: any
		expect(out.at.x):toBe(24)
	end)

	it("cancels when the finger ran off the edge, even if the lift is reported inside", function()
		local d = TaskViewLogic.newDrag()
		TaskViewLogic.dragBegin(d, finger, { x = 100, y = 400 }, 0, AREA)
		TaskViewLogic.dragMove(d, finger, { x = 2, y = 400 }, 0.1, AREA, CONFIG)
		expect(TaskViewLogic.dragEnd(d, finger, { x = 30, y = 400 }, AREA).kind):toBe("Cancel")
	end)

	it("recovers when the finger comes back from the edge before lifting", function()
		local d = TaskViewLogic.newDrag()
		TaskViewLogic.dragBegin(d, finger, { x = 100, y = 400 }, 0, AREA)
		TaskViewLogic.dragMove(d, finger, { x = 2, y = 400 }, 0.1, AREA, CONFIG)
		TaskViewLogic.dragMove(d, finger, { x = 150, y = 400 }, 0.2, AREA, CONFIG)
		expect(TaskViewLogic.dragEnd(d, finger, { x = 150, y = 400 }, AREA).kind):toBe("Drop")
	end)

	it("cancels a pointer that went quiet, then accepts a fresh one", function()
		local d = TaskViewLogic.newDrag()
		TaskViewLogic.dragBegin(d, finger, { x = 100, y = 100 }, 0, AREA)
		expect(TaskViewLogic.dragTick(d, 1.0, CONFIG).kind):toBe("Ignored")
		expect(TaskViewLogic.dragTick(d, 1.6, CONFIG).kind):toBe("Cancel")
		-- The lost InputEnded arriving late changes nothing.
		expect(TaskViewLogic.dragEnd(d, finger, { x = 100, y = 100 }, AREA).kind):toBe("Ignored")
		expect(TaskViewLogic.dragBegin(d, palm, { x = 100, y = 100 }, 2, AREA).kind):toBe("Started")
	end)

	it("dragCancel is a no-op with nothing held", function()
		local d = TaskViewLogic.newDrag()
		expect(TaskViewLogic.dragCancel(d).kind):toBe("Ignored")
		TaskViewLogic.dragBegin(d, finger, { x = 100, y = 100 }, 0, AREA)
		expect(TaskViewLogic.dragCancel(d).kind):toBe("Cancel")
	end)
end)

describe("TaskViewLogic hold / sweep / clock", function()
	it("hold fraction clamps and handles a zero requirement", function()
		expect(TaskViewLogic.holdFraction(1, 2)):toBe(0.5)
		expect(TaskViewLogic.holdFraction(5, 2)):toBe(1)
		expect(TaskViewLogic.holdFraction(1, 0)):toBe(1)
	end)

	it("sweep ping-pongs without a jump at the period boundary", function()
		expect(TaskViewLogic.sweep(0, 2)):toBe(0)
		expect(TaskViewLogic.sweep(1, 2)):toBe(1)
		expect(TaskViewLogic.sweep(1.5, 2)):toBe(0.5)
		expect(TaskViewLogic.sweep(1.999, 2)):toBeCloseTo(0, 2)
	end)

	it("clock formats whole seconds", function()
		expect(TaskViewLogic.clock(7.9)):toBe("0:07")
		expect(TaskViewLogic.clock(75)):toBe("1:15")
		expect(TaskViewLogic.clock(-3)):toBe("0:00")
	end)
end)

describe("TaskViewLogic.stepGrid", function()
	-- A 3-column keypad of 10 keys: 1 2 3 / 4 5 6 / 7 8 9 / 10
	it("moves within the grid", function()
		expect(TaskViewLogic.stepGrid(5, 3, 10, 1, 0)):toBe(6)
		expect(TaskViewLogic.stepGrid(5, 3, 10, 0, -1)):toBe(2)
	end)

	it("stops at edges instead of wrapping", function()
		expect(TaskViewLogic.stepGrid(3, 3, 10, 1, 0)):toBe(3)
		expect(TaskViewLogic.stepGrid(1, 3, 10, 0, -1)):toBe(1)
	end)

	it("won't step into the short last row's gap", function()
		expect(TaskViewLogic.stepGrid(8, 3, 10, 0, 1)):toBe(8)
		expect(TaskViewLogic.stepGrid(7, 3, 10, 0, 1)):toBe(10)
	end)
end)

describe("TaskViewLogic.aim", function()
	local o = { x = 0, y = 0 }

	it("returns nil inside the deadzone", function()
		local dir, strength = TaskViewLogic.aim(o, { x = 0.1, y = 0 }, 1, 0.2)
		expect(dir):toBe(nil)
		expect(strength):toBe(0)
	end)

	it("normalises direction and rescales strength past the deadzone", function()
		local dir, strength = TaskViewLogic.aim(o, { x = 0, y = 0.6 }, 1, 0.2)
		expect((dir :: any).y):toBe(1)
		expect(strength):toBeCloseTo(0.5, 5)
	end)

	it("caps strength at full deflection", function()
		local _, strength = TaskViewLogic.aim(o, { x = 300, y = 0 }, 100, 0.2)
		expect(strength):toBe(1)
	end)
end)

describe("TaskViewLogic lock set", function()
	it("freezes on the first acquire and restores on the last release", function()
		local set = TaskViewLogic.newLockSet()
		local view, cutscene = {}, {}
		expect(TaskViewLogic.acquire(set, view)):toBe(true)
		expect(TaskViewLogic.acquire(set, cutscene)):toBe(false)
		expect(TaskViewLogic.release(set, view)):toBe(false)
		expect(TaskViewLogic.release(set, cutscene)):toBe(true)
	end)

	it("double acquire and double release are no-ops", function()
		local set = TaskViewLogic.newLockSet()
		local view = {}
		TaskViewLogic.acquire(set, view)
		expect(TaskViewLogic.acquire(set, view)):toBe(false)
		expect(TaskViewLogic.release(set, view)):toBe(true)
		expect(TaskViewLogic.release(set, view)):toBe(false)
		expect(set.count):toBe(0)
	end)
end)

describe("TaskViewLogic.feedback", function()
	local states: { TaskViewLogic.Feedback } = { "Neutral", "Active", "Good", "Bad" }

	it("never signals two states with the same icon", function()
		local seen: { [string]: boolean } = {}
		for _, s in states do
			local icon = TaskViewLogic.feedback(s).icon or "<none>"
			expect(seen[icon]):toBe(nil)
			seen[icon] = true
		end
	end)

	it("uses only colour tokens that exist", function()
		local colors = Tokens.color :: { [string]: string }
		for _, s in states do
			expect(colors[TaskViewLogic.feedback(s).color] ~= nil):toBe(true)
		end
	end)
end)
