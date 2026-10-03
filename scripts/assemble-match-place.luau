--!strict
-- Assembles the Match place from per-map working files. Runs under Lune,
-- not Studio:
--
--     lune run scripts/assemble-match-place <base.rbxl> <out.rbxl> <file.rbxl>:<MapName> ...
--
-- e.g.
--
--     lune run scripts/assemble-match-place SpaceStation-Studio.rbxl Match.rbxl \
--         SpaceStation-Studio.rbxl:SpaceStation School-Studio.rbxl:School
--
-- WHY. Maps are built one per working file (CLAUDE.md: the .rbxl is
-- authoritative for map content), but the game ships one Match place
-- with every map under ServerStorage.Maps (architecture.md). This is the
-- step between the two, and re-running it is how a rebuilt or new map
-- gets in.
--
-- WHAT IT DOES:
--   1. Opens <base.rbxl> for everything that isn't code or a map: place
--      settings (Workspace streaming, Lighting, Players...), the shared
--      Decision Studio set, PowerUpModels, PracticeDummy, PropLibrary.
--   2. Replaces every Rojo-managed tree (default.project.json) with a
--      fresh `rojo build`, so code patched inside a place file never
--      survives into the Match place.
--   3. Deletes every other script in the place's code containers
--      (ReplicatedFirst, StarterGui, StarterPlayer, ServerScriptService),
--      and logs each one. Code lives in this repo or nowhere.
--   4. Puts each <file>:<MapName> into ServerStorage.Maps.<MapName>,
--      replacing any copy already there. The model is taken from that
--      file's Workspace first, then its ServerStorage.Maps. A map that
--      contains a script fails the run - map-kit-spec.md §3 step 1.
--   5. Copies each map file's ServerStorage.PropLibrary into
--      ServerStorage.PropLibrary.<MapName>, so its sanitised props can be
--      reused when the map is edited in the Match place.
--   6. Leaves Workspace empty of maps. StudioTestService clones
--      GameConfig.studioTest.mapId from ServerStorage.Maps; to edit a map,
--      drag it into Workspace (StudioTestService uses that copy first).
--   7. Adds Workspace.ArrivalPad if the place has no SpawnLocation.
--      Players load in before the round's map exists, and with no
--      SpawnLocation Roblox drops them at the world origin - straight
--      onto whatever map sits there (School's atrium roof), or into the
--      void. The pad is far from every map, and the round moves each
--      player onto the map's own SpawnPoints at Loading.
--
--   8. Applies lighting-and-streaming.md §1's place settings: Workspace
--      streaming (most of it can't be set from any script in Studio,
--      only in the Properties panel or here) and no Atmosphere or post
--      effects under Lighting, which would stack with every preset.
--
-- Once the Match place exists, pass it as <base.rbxl> to add or rebuild
-- a map; the maps already in it are kept unless named again. With no
-- map arguments at all it just refreshes code and place settings.
--
-- Then validate the result: `lune run scripts/validate-maps <out.rbxl>`.

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

type Instance = any

local MANAGED: { { string } } = {
	{ "ReplicatedFirst", "First" },
	{ "ReplicatedStorage", "Shared" },
	{ "ReplicatedStorage", "Packages" },
	{ "ServerScriptService", "Server" },
	{ "ServerScriptService", "ServerPackages" },
	{ "StarterPlayer", "StarterPlayerScripts", "Client" },
}
local CODE_CONTAINERS = { "ReplicatedFirst", "StarterGui", "StarterPlayer", "ServerScriptService" }

local function fail(message: string): never
	print("FAIL " .. message)
	process.exit(1)
	error("unreachable")
end

local args = table.clone(process.args)
if args[1] == "--" then
	table.remove(args, 1)
end
if #args < 2 then
	print("usage: lune run scripts/assemble-match-place <base.rbxl> <out.rbxl> [<file.rbxl>:<MapName> ...]")
	process.exit(2)
end
local basePath, outPath = args[1], args[2]

local function load(path: string): Instance
	if not fs.isFile(path) then
		fail("no such file: " .. path)
	end
	return roblox.deserializePlace(fs.readFile(path))
end

local function walk(root: Instance, path: { string }, upTo: number): Instance?
	local node = root:GetService(path[1])
	for i = 2, upTo do
		if node == nil then
			return nil
		end
		node = node:FindFirstChild(path[i])
	end
	return node
end

local game = load(basePath)

-- 2. fresh code
local builtPath = outPath .. ".rojo-build.rbxl"
local build = process.exec("rojo", { "build", "default.project.json", "-o", builtPath })
if not build.ok then
	fail("rojo build: " .. build.stderr)
end
local built = load(builtPath)
fs.removeFile(builtPath)
for _, path in MANAGED do
	local fresh = walk(built, path, #path)
	if fresh == nil then
		fail("rojo build has no " .. table.concat(path, "."))
	end
	local parent = walk(game, path, #path - 1)
	if parent == nil then
		fail("base place has no " .. table.concat(path, ".", 1, #path - 1))
	end
	local old = parent:FindFirstChild(path[#path])
	if old ~= nil then
		old:Destroy()
	end
	fresh.Parent = parent
	print("code   " .. table.concat(path, "."))
end

-- 3. stray scripts
local function isManaged(instance: Instance): boolean
	for _, path in MANAGED do
		local root = walk(game, path, #path)
		if root ~= nil and (instance == root or instance:IsDescendantOf(root)) then
			return true
		end
	end
	return false
end
for _, name in CODE_CONTAINERS do
	for _, d in game:GetService(name):GetDescendants() do
		if d.Parent ~= nil and d:IsA("LuaSourceContainer") and not isManaged(d) then
			print("strip  " .. d:GetFullName() .. " (" .. d.ClassName .. ", not in the repo)")
			d:Destroy()
		end
	end
end

-- 4/5. maps and their prop libraries
local serverStorage = game:GetService("ServerStorage")
local maps = serverStorage:FindFirstChild("Maps")
if maps == nil then
	maps = roblox.Instance.new("Folder")
	maps.Name = "Maps"
	maps.Parent = serverStorage
end
local props = serverStorage:FindFirstChild("PropLibrary")

local loaded: { [string]: Instance } = { [basePath] = game }
for i = 3, #args do
	local file, mapName = string.match(args[i], "^(.+):([%w_]+)$")
	if file == nil or mapName == nil then
		fail("expected <file.rbxl>:<MapName>, got " .. args[i])
	end
	local source = loaded[file :: string] or load(file :: string)
	loaded[file :: string] = source

	local sourceMaps = source:GetService("ServerStorage"):FindFirstChild("Maps")
	local model = source:GetService("Workspace"):FindFirstChild(mapName)
		or (sourceMaps and sourceMaps:FindFirstChild(mapName))
	if model == nil then
		fail(string.format("%s has no %s in Workspace or ServerStorage.Maps", file :: string, mapName :: string))
	end
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			fail("map contains a script: " .. d:GetFullName())
		end
	end

	-- Clone before touching anything: the base file can be a map source
	-- too, and its Workspace copy is removed below.
	local copy = model:Clone()
	local existing = maps:FindFirstChild(mapName)
	if existing ~= nil then
		existing:Destroy()
	end
	copy.Parent = maps
	print(string.format("map    %s <- %s (%d instances)", mapName :: string, file :: string, #copy:GetDescendants()))

	local sourceProps = source:GetService("ServerStorage"):FindFirstChild("PropLibrary")
	if sourceProps ~= nil and source ~= game then
		if props == nil then
			props = roblox.Instance.new("Folder")
			props.Name = "PropLibrary"
			props.Parent = serverStorage
		end
		local old = props:FindFirstChild(mapName :: string)
		if old ~= nil then
			old:Destroy()
		end
		local folder = sourceProps:Clone()
		folder.Name = mapName :: string
		folder.Parent = props
		print("props  PropLibrary." .. (mapName :: string))
	end
end

-- 6. no maps left in Workspace
local workspace = game:GetService("Workspace")
for _, map in maps:GetChildren() do
	local stale = workspace:FindFirstChild(map.Name)
	if stale ~= nil then
		stale:Destroy()
		print("clear  Workspace." .. map.Name)
	end
end

-- 7. somewhere to stand before the map exists
local hasSpawn = false
for _, d in workspace:GetDescendants() do
	if d:IsA("SpawnLocation") then
		hasSpawn = true
	end
end
if not hasSpawn then
	-- Far along -X: maps are built around the origin, and the Decision
	-- Studio set is moved +X at runtime (GameConfig.decisionStudioStage).
	local origin = roblox.Vector3.new(-3000, 100, 0)
	local pad = roblox.Instance.new("Model")
	pad.Name = "ArrivalPad"
	local floor = roblox.Instance.new("Part")
	floor.Name = "Floor"
	floor.Size = roblox.Vector3.new(40, 2, 40)
	floor.CFrame = roblox.CFrame.new(origin)
	floor.Anchored = true
	floor.Material = roblox.Enum.Material.SmoothPlastic
	floor.Color = roblox.Color3.fromRGB(60, 64, 72)
	floor.Parent = pad
	local spawn = roblox.Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Size = roblox.Vector3.new(12, 1, 12)
	spawn.CFrame = roblox.CFrame.new(origin + roblox.Vector3.new(0, 1.5, 0))
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0 -- no spawn ForceField; the round re-places everyone anyway
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Parent = pad
	pad.Parent = workspace
	print("spawn  Workspace.ArrivalPad (no SpawnLocation in the place)")
end

-- 8. place settings (lighting-and-streaming.md §1)
workspace.StreamingEnabled = true
workspace.StreamingMinRadius = 64
workspace.StreamingTargetRadius = 256
workspace.ModelStreamingBehavior = roblox.Enum.ModelStreamingBehavior.Improved
workspace.StreamOutBehavior = roblox.Enum.StreamOutBehavior.LowMemory
workspace.StreamingIntegrityMode = roblox.Enum.StreamingIntegrityMode.PauseOutsideLoadedArea
print("place  Workspace streaming per lighting-and-streaming.md §1")
for _, child in game:GetService("Lighting"):GetChildren() do
	if child:IsA("PostEffect") or child:IsA("Atmosphere") then
		print("strip  Lighting." .. child.Name .. " (" .. child.ClassName .. ", stacks with presets)")
		child:Destroy()
	end
end

fs.writeFile(outPath, roblox.serializePlace(game))
print("wrote  " .. outPath)
