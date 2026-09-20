--!strict
-- Minimal Luau test runner for pure-logic modules (Ground Rule 4: the
-- outcome table, pricing, ranking, tie-breaks and streak maths must stay
-- free of Roblox API calls so they can be unit-tested headlessly in CI).
--
-- Hand-rolled deliberately, not a third-party dependency: Jest-Lua
-- currently only runs inside the real Roblox engine (no Lune support as
-- of writing - see the README's Testing section), and TestEZ's headless
-- CI path (Lemur) runs on a Lua 5.1 interpreter that can't parse
-- `--!strict` Luau syntax at all. Since these modules never touch a
-- Roblox API in the first place, they don't need Roblox emulation -
-- Lune's real Luau runtime is sufficient on its own, and a ~60-line
-- runner is lower-risk than an unverified community dependency for
-- foundational CI infrastructure. Revisit if Jest-Lua ships real Lune
-- support later.

local process = require("@lune/process")

type Case = { name: string, fn: () -> () }
type Suite = { name: string, cases: { Case } }

local TestRunner = {}

local suites: { Suite } = {}
local currentSuite: Suite? = nil

function TestRunner.describe(name: string, fn: () -> ())
	local suite: Suite = { name = name, cases = {} }
	table.insert(suites, suite)
	local previous = currentSuite
	currentSuite = suite
	fn()
	currentSuite = previous
end

function TestRunner.it(name: string, fn: () -> ())
	assert(currentSuite ~= nil, "it() must be called inside describe()")
	table.insert((currentSuite :: Suite).cases, { name = name, fn = fn })
end

function TestRunner.expect(value: any)
	local matchers = {}

	function matchers.toBe(_self, expected: any)
		assert(value == expected, string.format("expected %s, got %s", tostring(expected), tostring(value)))
	end

	function matchers.toBeTruthy(_self)
		assert(value, string.format("expected a truthy value, got %s", tostring(value)))
	end

	function matchers.toBeCloseTo(_self, expected: number, tolerance: number?)
		local eps = tolerance or 1e-6
		assert(
			math.abs((value :: number) - expected) <= eps,
			string.format("expected %s to be close to %s", tostring(value), tostring(expected))
		)
	end

	return matchers
end

function TestRunner.run()
	local totalPassed = 0
	local totalFailed = 0

	for _, suite in suites do
		print(suite.name)
		for _, case in suite.cases do
			-- Luau's strict-mode return-arity inference for pcall/xpcall only
			-- accounts for the wrapped function's own return count (zero,
			-- for a test case), so the failure message is captured through
			-- the handler's upvalue instead of xpcall's second return value.
			local errMessage: string? = nil
			local ok = xpcall(case.fn, function(e)
				errMessage = tostring(e)
			end)
			if ok then
				totalPassed += 1
				print(string.format("  PASS  %s", case.name))
			else
				totalFailed += 1
				print(string.format("  FAIL  %s", case.name))
				print(string.format("          %s", tostring(errMessage)))
			end
		end
	end

	print(string.format("\n%d passed, %d failed", totalPassed, totalFailed))

	if totalFailed > 0 then
		process.exit(1)
	end
end

return TestRunner
