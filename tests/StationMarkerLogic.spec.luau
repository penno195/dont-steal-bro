--!strict
-- The pure half of the station markers (P7-6). How the markers look in a
-- real map is checked with the playtest in docs/station-readability.md.

local StationMarkerLogic = require("../src/client/UI/StationMarkerLogic")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function inputs(overrides: { [string]: any }): StationMarkerLogic.Inputs
	local base: { [string]: any } = { assigned = true, completed = false, mine = false, others = 0 }
	for key, value in overrides do
		base[key] = value
	end
	return base :: any
end

describe("StationMarkerLogic.state", function()
	it("hides a station that isn't on your route, even with rivals at it", function()
		expect(StationMarkerLogic.state(inputs({ assigned = false, others = 2 }))):toBe("Hidden")
	end)

	it("is Ready when assigned, not done and free", function()
		expect(StationMarkerLogic.state(inputs({}))):toBe("Ready")
	end)

	it("is Rival when someone else is working it", function()
		expect(StationMarkerLogic.state(inputs({ others = 1 }))):toBe("Rival")
	end)

	it("puts your own attempt above rivals at the same station", function()
		expect(StationMarkerLogic.state(inputs({ mine = true, others = 3 }))):toBe("Mine")
	end)

	it("puts Done above everything", function()
		expect(StationMarkerLogic.state(inputs({ completed = true, mine = true, others = 1 }))):toBe("Done")
	end)
end)

describe("StationMarkerLogic.look", function()
	it("draws nothing for Hidden", function()
		expect(StationMarkerLogic.look("Hidden")):toBe(nil)
	end)

	-- accessibility.md: every state must be told apart without colour.
	-- Every look uses the same tint, so the rest of its fields must
	-- differ between every pair of states.
	it("gives every visible state a distinct non-colour signature", function()
		local seen: { [string]: string } = {}
		for _, state in { "Ready", "Rival", "Mine", "Done" } do
			local look = StationMarkerLogic.look(state :: StationMarkerLogic.State) :: StationMarkerLogic.Look
			local signature = string.format(
				"%s|%s|%s|%s",
				look.beam,
				tostring(look.pulse),
				tostring(look.glyph),
				tostring(look.padTransparency)
			)
			expect(seen[signature]):toBe(nil)
			seen[signature] = state
		end
	end)

	it("only calls you with a shaft while there's still work there", function()
		expect((StationMarkerLogic.look("Ready") :: StationMarkerLogic.Look).beam):toBe("Solid")
		expect((StationMarkerLogic.look("Rival") :: StationMarkerLogic.Look).beam):toBe("Dashed")
		expect((StationMarkerLogic.look("Mine") :: StationMarkerLogic.Look).beam):toBe("Off")
		expect((StationMarkerLogic.look("Done") :: StationMarkerLogic.Look).beam):toBe("Off")
	end)
end)

describe("StationMarkerLogic.style", function()
	it("falls back to the defaults and the brand tint", function()
		local style = StationMarkerLogic.style(nil, "#8B5CF6")
		expect(style.beam):toBe(true)
		expect(style.pad):toBe(true)
		expect(style.beamHeight):toBe(StationMarkerLogic.DEFAULT_BEAM_HEIGHT)
		expect(style.tint):toBe("#8B5CF6")
	end)

	it("keeps a map's own values, and the brand tint when it sets none", function()
		local style = StationMarkerLogic.style({ beam = false, pad = true, beamHeight = 8 }, "#8B5CF6")
		expect(style.beam):toBe(false)
		expect(style.beamHeight):toBe(8)
		expect(style.tint):toBe("#8B5CF6")
	end)
end)

describe("StationMarkerLogic.beamTransparency", function()
	local function valid(points: { StationMarkerLogic.Keypoint })
		expect(#points <= 20):toBe(true) -- the engine's NumberSequence limit
		expect(points[1].time):toBe(0)
		expect(points[#points].time):toBe(1)
		for i = 2, #points do
			expect(points[i].time > points[i - 1].time):toBe(true)
		end
		for _, point in points do
			expect(point.value >= 0 and point.value <= 1):toBe(true)
		end
	end

	it("is empty when the shaft is off", function()
		expect(#StationMarkerLogic.beamTransparency("Off")):toBe(0)
	end)

	it("fades a solid shaft out to nothing at the top", function()
		local points = StationMarkerLogic.beamTransparency("Solid")
		valid(points)
		expect(points[1].value < 1):toBe(true)
		expect(points[#points].value):toBe(1)
	end)

	it("builds a dashed shaft the engine accepts, with real gaps in it", function()
		local points = StationMarkerLogic.beamTransparency("Dashed")
		valid(points)
		local gaps, lit = 0, 0
		for _, point in points do
			if point.value == 1 then
				gaps += 1
			elseif point.value < 0.9 then
				lit += 1
			end
		end
		expect(gaps >= 4):toBe(true)
		expect(lit >= 4):toBe(true)
	end)
end)
