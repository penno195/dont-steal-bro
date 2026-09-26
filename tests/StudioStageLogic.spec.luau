--!strict
-- Covers StudioStageLogic.luau: the pure half of staging the shared
-- Decision Studio set. StudioStageService itself moves real characters,
-- so it's checked in Studio (docs/decision-studio.md "Staging").

local TestRunner = require("./TestRunner")
local StudioStageLogic = require("../src/server/StudioStageLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end

describe("StudioStageLogic.topY", function()
	it("is centre plus half the height for an upright block", function()
		expect(StudioStageLogic.topY(10, 6, 2, 6, 0, 1, 0)):toBe(11)
	end)

	it("uses Size.X for a cylinder turned so its axis points up", function()
		-- RightVector straight up, UpVector and LookVector flat.
		expect(StudioStageLogic.topY(10, 2, 6, 6, 1, 0, 0)):toBe(11)
	end)
end)

describe("StudioStageLogic.standOn", function()
	it("stands on top of the podium, facing the centre on the level", function()
		local stand = StudioStageLogic.standOn(10, 20, 0, 3, 0, 0)
		expect(stand.x):toBe(10)
		expect(stand.y):toBe(23)
		expect(stand.z):toBe(0)
		expect(near(stand.lookX, -1)):toBe(true)
		expect(near(stand.lookZ, 0)):toBe(true)
	end)

	it("gives a podium on the centre a valid facing", function()
		local stand = StudioStageLogic.standOn(0, 0, 0, 3, 0, 0)
		expect(stand.lookX):toBe(0)
		expect(stand.lookZ):toBe(1)
	end)
end)

describe("StudioStageLogic.podiumFor", function()
	it("puts seat n on SlotIndex n, NPC ids included", function()
		local out = StudioStageLogic.podiumFor({ 50, -2, 7 }, { 3, 1, 2 })
		expect(out[50]):toBe(1)
		expect(out[-2]):toBe(2)
		expect(out[7]):toBe(3)
	end)

	it("leaves out a seat with no podium", function()
		local out = StudioStageLogic.podiumFor({ 50, 60, 70 }, { 1, 2 })
		expect(out[70]):toBe(nil)
	end)
end)

describe("StudioStageLogic.lookoutFor", function()
	it("spreads spectators over the lookouts in id order", function()
		local out = StudioStageLogic.lookoutFor({ 30, -1, 20, 10 }, 3)
		expect(out[-1]):toBe(1)
		expect(out[10]):toBe(2)
		expect(out[20]):toBe(3)
		expect(out[30]):toBe(1)
	end)
end)

describe("StudioStageLogic.isInsideArea", function()
	it("is true inside the box, edges included", function()
		expect(StudioStageLogic.isInsideArea(0, 0, 0, 20, 20, 60)):toBe(true)
		expect(StudioStageLogic.isInsideArea(10, -10, 30, 20, 20, 60)):toBe(true)
	end)

	it("is false past any face: over the fence, below the floor, off the end", function()
		expect(StudioStageLogic.isInsideArea(-10.5, 0, 0, 20, 20, 60)):toBe(false)
		expect(StudioStageLogic.isInsideArea(0, -10.5, 0, 20, 20, 60)):toBe(false)
		expect(StudioStageLogic.isInsideArea(0, 0, 30.5, 20, 20, 60)):toBe(false)
	end)
end)

describe("StudioStageLogic chat rules", function()
	it("keeps finalists out of the general channel both ways", function()
		expect(StudioStageLogic.mayDeliverGeneral(false, true, false)):toBe(false)
		expect(StudioStageLogic.mayDeliverGeneral(true, false, false)):toBe(false)
		expect(StudioStageLogic.mayDeliverGeneral(false, false, false)):toBe(true)
		expect(StudioStageLogic.mayDeliverGeneral(true, true, true)):toBe(true)
	end)

	it("lets spectators read the negotiation at any range but never speak", function()
		expect(StudioStageLogic.mayDeliverNegotiate(true, false, false, false)):toBe(true)
		expect(StudioStageLogic.mayDeliverNegotiate(false, true, false, true)):toBe(false)
		expect(StudioStageLogic.mayDeliverNegotiate(false, false, true, true)):toBe(false)
	end)

	it("still range-limits finalist to finalist", function()
		expect(StudioStageLogic.mayDeliverNegotiate(true, true, false, true)):toBe(true)
		expect(StudioStageLogic.mayDeliverNegotiate(true, true, false, false)):toBe(false)
	end)
end)
