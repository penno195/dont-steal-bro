--!strict
-- Minimal two-phase lifecycle loader for Services (server) and
-- Controllers (client). No external framework - see architecture.md's
-- scaling rule: adding a module should never mean editing this file.
--
-- WHY TWO PHASES:
-- If a module ran its own setup the instant it was require()'d, whether
-- it could safely reference another module would depend on which one
-- Luau happened to require first - an accident of file order, not a real
-- guarantee. Splitting startup into init() then start() removes that
-- accident: every module's init() should only set up its OWN state and
-- fetch references to other modules via Loader.get(...); it must not
-- call methods on those references yet, because they might not have run
-- their own init() yet. By the time ANY module's start() runs, every
-- module has finished init() - so start() is the first point it's safe
-- to actually call into another module's public methods.

export type Lifecycle = {
	name: string,
	dependencies: { string }?,
	init: ((self: any) -> ())?,
	start: ((self: any) -> ())?,
	[any]: any,
}

-- Named separately from Lifecycle (even though the shape is identical)
-- so a new file reads clearly as "this is a Service" or "this is a
-- Controller" and gets that name in autocomplete.
export type Service = Lifecycle
export type Controller = Lifecycle

local Loader = {}

-- Populated by start(); shared module-level state is safe here because
-- server and client each require their own separate copy of this module
-- in their own Luau VM - there's no cross-boundary sharing to worry about.
local modules: { [string]: Lifecycle } = {}

-- Typed by the caller at the call site, e.g.
--   local Other = Loader.get("OtherService") :: OtherService.Type
-- so a service can reach another without requiring it directly (and
-- without caring what order they were required in).
function Loader.get(name: string): any
	local mod = modules[name]
	assert(mod ~= nil, string.format("Loader.get(%q): no module with that name has been loaded", name))
	return mod
end

-- Testing-only seam (P1-6): registers a module directly into the
-- singleton `modules` registry without needing a real Roblox `folder` to
-- scan - Loader.start's own `folder:GetChildren()` is a Roblox API this
-- can't reach under Lune. This is how a pure-logic unit test fakes a
-- service dependency reachable via Loader.get(name), the exact way a
-- real module would reach it in production - see
-- tests/Loader.spec.luau's "fakes a dependency" case. Never call this
-- outside a test.
function Loader.registerForTesting(module: Lifecycle)
	modules[module.name] = module
end

-- Topologically sorts by declared `dependencies`, so every module's
-- dependencies finish init() before it does. DFS with an explicit path
-- so a cycle error can name every module in the cycle, not just say
-- "a cycle exists somewhere." Exported (P1-6) so this pure algorithm can
-- be unit-tested directly against a hand-built registry, without needing
-- a real Roblox `folder` of ModuleScripts the way Loader.start does.
function Loader.topoSort(registry: { [string]: Lifecycle }): { string }
	local order: { string } = {}
	local state: { [string]: "visiting" | "done" } = {}
	local path: { string } = {}

	local function visit(name: string)
		if state[name] == "done" then
			return
		end
		if state[name] == "visiting" then
			table.insert(path, name)
			local cycleStart = table.find(path, name) :: number
			local cycle = table.concat(path, " -> ", cycleStart)
			error(string.format("Loader: dependency cycle detected: %s", cycle), 0)
		end

		state[name] = "visiting"
		table.insert(path, name)

		local mod = registry[name]
		for _, dependency in mod.dependencies or ({} :: { string }) do
			if registry[dependency] == nil then
				error(
					string.format("Loader: %q declares a dependency on %q, which was not loaded", name, dependency),
					0
				)
			end
			visit(dependency)
		end

		table.remove(path)
		state[name] = "done"
		table.insert(order, name)
	end

	for name in registry do
		visit(name)
	end

	return order
end

local function runPhase(order: { string }, registry: { [string]: Lifecycle }, phase: "init" | "start")
	for _, name in order do
		local mod = registry[name]
		local fn = mod[phase]
		if fn == nil then
			continue
		end

		local startedAt = os.clock()
		local ok, err = xpcall(function()
			fn(mod)
		end, debug.traceback)
		local elapsed = os.clock() - startedAt

		if not ok then
			warn(string.format("Loader: %q failed during %s() after %.3fs\n%s", name, phase, elapsed, tostring(err)))
			error(err, 0) -- re-thrown: a broken module must not fail silently
		end

		print(string.format("Loader: %q %s() in %.3fs", name, phase, elapsed))
	end
end

-- Requires every ModuleScript directly under `folder`, resolves init
-- order from their declared `dependencies`, then runs every init()
-- before any start().
function Loader.start(folder: Instance)
	local registry: { [string]: Lifecycle } = {}

	for _, child in folder:GetChildren() do
		if not child:IsA("ModuleScript") then
			continue
		end

		local mod = (require(child) :: any) :: Lifecycle
		local name = mod.name or child.Name
		if registry[name] ~= nil then
			error(string.format("Loader: duplicate module name %q (at least one is %s)", name, child:GetFullName()), 0)
		end

		mod.name = name
		registry[name] = mod
		modules[name] = mod
	end

	local order = Loader.topoSort(registry)
	runPhase(order, registry, "init")
	runPhase(order, registry, "start")
end

return Loader
