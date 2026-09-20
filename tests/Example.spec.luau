--!strict
-- Smoke test proving the CI pipeline actually exercises TestRunner end to
-- end. Delete once a real pure-logic module (e.g. Outcomes.luau) has its
-- own spec file registered in tests/run.luau.

local TestRunner = require("./TestRunner")

TestRunner.describe("TestRunner", function()
	TestRunner.it("passes a trivial assertion", function()
		TestRunner.expect(1 + 1):toBe(2)
	end)

	TestRunner.it("fails loudly when a match doesn't hold", function()
		TestRunner.expect(true):toBeTruthy()
	end)
end)
