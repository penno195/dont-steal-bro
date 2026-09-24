--!strict
-- Covers LightingLogic.luau (P7-5): the "no leaked state between rounds"
-- guarantee LightingService relies on. LightingService itself touches the
-- Lighting service, so it is exercised in Studio instead.

local TestRunner = require("./TestRunner")
local LightingLogic = require("../src/server/LightingLogic")

local function preset(): LightingLogic.Preset
	return {
		id = "Test",
		lightingStyle = "Realistic",
		prioritizeLightingQuality = false,
		globalShadows = false,
		ambient = "#50607A",
		outdoorAmbient = "#46556E",
		brightness = 1,
		clockTime = 0,
		environmentDiffuseScale = 0.3,
		environmentSpecularScale = 0.6,
		exposureCompensation = 0.2,
		fogColor = "#1A2A33",
		fogStart = 140,
		fogEnd = 500,
		colorCorrection = { brightness = 0.05, contrast = 0.15, saturation = 0, tintColor = "#E0F4FF" },
		bloom = { intensity = 0.4, size = 24, threshold = 1.2 },
	}
end

TestRunner.describe("LightingLogic.plan", function()
	TestRunner.it("writes exactly the properties the service snapshots, in order", function()
		local plan = LightingLogic.plan(preset())
		TestRunner.expect(#plan.lighting):toBe(#LightingLogic.LIGHTING_PROPERTIES)
		for index, assignment in plan.lighting do
			TestRunner.expect(assignment.property):toBe(LightingLogic.LIGHTING_PROPERTIES[index])
		end
	end)

	TestRunner.it("writes the full Lighting set even for a preset with no post effects", function()
		local bare = preset()
		bare.colorCorrection = nil
		bare.bloom = nil
		local plan = LightingLogic.plan(bare)
		TestRunner.expect(#plan.lighting):toBe(#LightingLogic.LIGHTING_PROPERTIES)
		TestRunner.expect(plan.colorCorrection == nil):toBeTruthy()
		TestRunner.expect(plan.bloom == nil):toBeTruthy()
	end)

	TestRunner.it("carries preset values through with the right kinds", function()
		local plan = LightingLogic.plan(preset())
		local byName: { [string]: LightingLogic.Assignment } = {}
		for _, assignment in plan.lighting do
			byName[assignment.property] = assignment
		end
		TestRunner.expect(byName.LightingStyle.kind):toBe("enum")
		TestRunner.expect(byName.LightingStyle.value):toBe("Realistic")
		TestRunner.expect(byName.Ambient.kind):toBe("color")
		TestRunner.expect(byName.Ambient.value):toBe("#50607A")
		TestRunner.expect(byName.GlobalShadows.value):toBe(false)
		TestRunner.expect(byName.FogEnd.value):toBe(500)
	end)

	TestRunner.it("plans post effects only when the preset has them", function()
		local plan = LightingLogic.plan(preset())
		TestRunner.expect(#(plan.colorCorrection :: { LightingLogic.Assignment })):toBe(4)
		TestRunner.expect(#(plan.bloom :: { LightingLogic.Assignment })):toBe(3)
	end)
end)

TestRunner.describe("LightingLogic.find", function()
	TestRunner.it("finds a preset by id and returns nil for an unknown one", function()
		local presets = { { def = preset() } }
		TestRunner.expect(LightingLogic.find(presets, "Test") ~= nil):toBeTruthy()
		TestRunner.expect(LightingLogic.find(presets, "Nope") == nil):toBeTruthy()
	end)
end)
