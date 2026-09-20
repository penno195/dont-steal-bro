--!strict
-- Covers Loader.luau's pure half (P1-6): the topological sort, and the
-- registerForTesting seam that lets a pure-logic test fake a service
-- dependency reached via Loader.get. Loader.start itself isn't covered
-- here - it walks a real `folder:GetChildren()`, a Roblox API this can't
-- reach under Lune - and is instead exercised manually in Studio, the
-- same split every other *.spec.luau in this suite follows for its
-- Roblox-touching counterpart module.
--
-- This file is the "mocked-service module" example P1-6 asks for: the
-- second half below shows the actual pattern to copy when a future pure-
-- logic test needs to fake ITS OWN dependency reached through the
-- loader, per docs/testing-conventions.md.

local TestRunner = require("./TestRunner")
local Loader = require("../src/shared/Loader")

TestRunner.describe("Loader.topoSort", function()
	TestRunner.it("orders dependencies before dependents", function()
		local order = Loader.topoSort({
			A = { name = "A", dependencies = {} },
			B = { name = "B", dependencies = { "A" } },
			C = { name = "C", dependencies = { "B" } },
		})
		TestRunner.expect(table.find(order, "A") < table.find(order, "B")):toBeTruthy()
		TestRunner.expect(table.find(order, "B") < table.find(order, "C")):toBeTruthy()
	end)

	TestRunner.it("names every module in a dependency cycle", function()
		local ok, err = pcall(function()
			Loader.topoSort({
				A = { name = "A", dependencies = { "B" } },
				B = { name = "B", dependencies = { "A" } },
			})
		end)
		TestRunner.expect(ok):toBe(false)
		TestRunner.expect(string.find(tostring(err), "A") ~= nil):toBeTruthy()
		TestRunner.expect(string.find(tostring(err), "B") ~= nil):toBeTruthy()
	end)

	TestRunner.it("errors on a dependency that was never loaded", function()
		local ok = pcall(function()
			Loader.topoSort({
				A = { name = "A", dependencies = { "Nonexistent" } },
			})
		end)
		TestRunner.expect(ok):toBe(false)
	end)

	TestRunner.it("handles a module with no dependencies field at all", function()
		local order = Loader.topoSort({ A = { name = "A" } })
		TestRunner.expect(#order):toBe(1)
	end)
end)

-- ===== The "mocked-service module" example ===============================
-- Say a real pure-logic module - call it StreakMath - needs to reach
-- another service through Loader.get(...) rather than require()'ing it
-- directly (the whole point of Loader.get: no direct coupling, no caring
-- about require order). A unit test for StreakMath shouldn't have to
-- boot the entire Loader.start pipeline, with a real Roblox `folder`,
-- just to satisfy one dependency it doesn't actually care about testing.
-- Loader.registerForTesting is the seam that avoids that: register a
-- fake directly, call the code under test, done.

local function computeBountyLabel(streak: number): string
	local Titles = Loader.get("TitleService") :: { labelFor: (streak: number) -> string }
	return Titles.labelFor(streak)
end

TestRunner.describe("Loader.registerForTesting (mocked-service example)", function()
	TestRunner.it("lets a test fake a dependency reached via Loader.get", function()
		Loader.registerForTesting({
			name = "TitleService",
			labelFor = function(streak: number): string
				if streak >= 10 then
					return "Legend"
				end
				return "Rookie"
			end,
		})

		TestRunner.expect(computeBountyLabel(3)):toBe("Rookie")
		TestRunner.expect(computeBountyLabel(10)):toBe("Legend")
	end)
end)
