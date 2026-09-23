--!strict
-- Headless map validator (P7-1). Runs under Lune, not Studio:
--
--     lune run scripts/validate-maps path/to/DontStealBro.rbxl [MapName ...]
--
-- Loads the place file, validates every Model under ServerStorage.Maps
-- (or only the named ones) with the exact same rules as the Studio
-- plugin - plugin/MapValidator/MapCheck.luau - prints each report, and
-- exits 1 if any map has an error. That exit code is the CI gate.
--
-- One check is missing here by necessity: spawn-to-station reachability
-- needs PathfindingService, which only exists in a running Roblox
-- engine. The report marks it skipped rather than passing it silently;
-- run the Studio plugin for that one before shipping.
--
-- The place file isn't in this repo (maps are hand-built and live only
-- in the .rbxl - CLAUDE.md), so CI needs the file supplied - see
-- docs/map-validator.md for the options.
--
-- Unlike the other files in scripts/, this one is never pasted into
-- Studio's Command Bar: the `@lune/*` requires don't exist there.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

-- ===== a minimal Roblox-style module loader ==================================
--
-- The config files and the plugin modules are written for Roblox:
-- `require(ReplicatedStorage.Shared.Config.Validate)`,
-- `require(script.Parent.MapCheck)`. Rather than fork them for Lune,
-- they're loaded with a stand-in `game`, `script` and `require` that
-- resolve those instance paths onto files in this repo - the same
-- mapping default.project.json gives Rojo. Anything outside that
-- mapping errors loudly: a config module that starts calling real
-- Roblox services at load time has broken Ground Rule 4 and should
-- fail here, not be papered over.

local SERVICE_ROOTS: { [string]: { [string]: string } } = {
	ReplicatedStorage = { Shared = "src/shared" },
}

type PathProxy = { __fsPath: string }

local proxyMeta = {}
local function proxy(fsPath: string): PathProxy
	return setmetatable({ __fsPath = fsPath }, proxyMeta) :: any
end
proxyMeta.__index = function(self: PathProxy, key: string): any
	if key == "Parent" then
		return proxy(string.match(self.__fsPath, "^(.*)/[^/]+$") or ".")
	end
	return proxy(self.__fsPath .. "/" .. key)
end

local function serviceProxy(name: string): any
	local roots = SERVICE_ROOTS[name]
	if roots == nil then
		error(string.format("validate-maps: config code asked for game:GetService(%q) at load time", name))
	end
	return setmetatable({}, {
		__index = function(_, child: string)
			local path = roots[child]
			if path == nil then
				error(string.format("validate-maps: %s.%s isn't mapped to a repo folder", name, child))
			end
			return proxy(path)
		end,
	})
end

local fakeGame = {
	GetService = function(_self: any, name: string): any
		return serviceProxy(name)
	end,
}

local cache: { [string]: any } = {}

local function resolve(fsPath: string): string
	if fs.isFile(fsPath .. ".luau") then
		return fsPath .. ".luau"
	elseif fs.isFile(fsPath .. "/init.luau") then
		return fsPath .. "/init.luau"
	end
	error(string.format("validate-maps: no module at %s(.luau|/init.luau)", fsPath))
end

local loadModule: (fsPath: string) -> any

local function fakeRequire(target: any): any
	if type(target) == "table" and rawget(target, "__fsPath") then
		return loadModule(target.__fsPath)
	end
	error("validate-maps: require() of something that isn't a repo module path")
end

-- `fsPath` has no extension: "src/shared/Config/Tasks/PressureValve".
loadModule = function(fsPath: string): any
	local file = resolve(fsPath)
	if cache[file] ~= nil then
		return cache[file]
	end
	-- `script` is fsPath for both X.luau and X/init.luau - Rojo turns an
	-- init.luau into its folder's own ModuleScript, so script.Parent is
	-- the enclosing folder either way.
	local chunk = luau.load(fs.readFile(file), {
		debugName = file,
		environment = { game = fakeGame, script = proxy(fsPath), require = fakeRequire },
	})
	local result = chunk()
	cache[file] = result
	return result
end

-- ===== config ================================================================

-- Every definition file in a registry folder. The folder's init.luau is
-- skipped: it walks Instance children via Registry.collect, which is the
-- Roblox half of the same job this does with the filesystem.
local function loadDefs(folder: string): { any }
	local defs = {}
	local names = fs.readDir(folder)
	table.sort(names)
	for _, name in names do
		local base = string.match(name, "^(.+)%.luau$")
		if base and base ~= "init" then
			table.insert(defs, loadModule(folder .. "/" .. base))
		end
	end
	return defs
end

local MapCheck = loadModule("plugin/MapValidator/MapCheck")
local Snapshot = loadModule("plugin/MapValidator/Snapshot")

local taskIds = {}
for _, def in loadDefs("src/shared/Config/Tasks") do
	table.insert(taskIds, def.id)
end
local powerUps = {}
for _, def in loadDefs("src/shared/Config/PowerUps") do
	table.insert(powerUps, { id = def.id, rarity = def.rarity })
end
-- ConfigValidator matches a MapDef to its built model by def.id == the
-- model's Name; the same key is used here.
local mapDefs: { [string]: any } = {}
for _, def in loadDefs("src/shared/Config/Maps") do
	mapDefs[def.id] = def
end

-- ===== run ===================================================================

local args = table.clone(process.args)
-- Lune hands a literal "--" through to process.args rather than eating
-- it, so accept both `validate-maps x.rbxl` and `validate-maps -- x.rbxl`.
if args[1] == "--" then
	table.remove(args, 1)
end
local placePath = table.remove(args, 1)
if placePath == nil then
	print("usage: lune run scripts/validate-maps <place.rbxl> [MapName ...]")
	process.exit(2)
end

local game = roblox.deserializePlace(fs.readFile(placePath :: string))
local mapsFolder = game:GetService("ServerStorage"):FindFirstChild("Maps")
if mapsFolder == nil then
	print(string.format("FAIL %s has no ServerStorage.Maps folder", placePath :: string))
	process.exit(1)
end

local wanted: { [string]: boolean }? = nil
if #args > 0 then
	wanted = {}
	for _, name in args do
		(wanted :: { [string]: boolean })[name] = true
	end
end

local maps = {}
for _, child in mapsFolder:GetChildren() do
	if child:IsA("Model") and (wanted == nil or wanted[child.Name]) then
		table.insert(maps, child)
	end
end
table.sort(maps, function(a, b)
	return a.Name < b.Name
end)

if #maps == 0 then
	print("FAIL no matching map Models under ServerStorage.Maps")
	process.exit(1)
end

local failed = 0
for _, map in maps do
	local snapshot = Snapshot.build(map)
	local report = MapCheck.run(snapshot, {
		taskIds = taskIds,
		powerUps = powerUps,
		mapDef = mapDefs[map.Name],
		unreachableIds = nil,
	})
	print(MapCheck.formatText(report))
	print("")
	if not report.passed then
		failed += 1
	end
end

print(string.format("%d map(s) checked, %d failed", #maps, failed))
process.exit(if failed > 0 then 1 else 0)
