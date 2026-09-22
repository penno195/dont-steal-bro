--!strict
-- Runs every registry (Maps, Tasks, PowerUps, Titles, NPCPersonalities)
-- plus GameConfig
-- through Validate.luau's pure checks at server boot, and fails LOUDLY -
-- naming the file and the exact broken field - rather than letting a
-- typo in a config file boot a half-valid server (Ground Rule 2). Any
-- service that reads config should declare `dependencies = {
-- "ConfigValidator" }` so Loader's topological sort runs this first and
-- a broken config throws before that service ever sees bad data.
--
-- Also does the one check Validate.luau can't do itself, because it
-- needs a real Instance tree: map-kit-spec.md §2 requires every
-- `enabled = true` map to have a matching built model in
-- `ServerStorage.Maps` - a config referencing a map nobody built in
-- Studio should fail here, not the first time a round tries to load it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Loader = require(ReplicatedStorage.Shared.Loader)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Maps = require(ReplicatedStorage.Shared.Config.Maps)
local Tasks = require(ReplicatedStorage.Shared.Config.Tasks)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local Titles = require(ReplicatedStorage.Shared.Config.Titles)
local NPCPersonalities = require(ReplicatedStorage.Shared.Config.NPCPersonalities)
local Store = require(ReplicatedStorage.Shared.Config.Store)

local function formatIssues(issues: { Validate.Issue }): string
	local lines = { string.format("ConfigValidator: %d config error(s):", #issues) }
	for _, problem in issues do
		table.insert(
			lines,
			string.format("  [%s] %s (%s): %s", problem.category, problem.fileName, problem.field, problem.message)
		)
	end
	return table.concat(lines, "\n")
end

local function checkBuiltMaps(maps: { Registry_Entry }, issues: { Validate.Issue })
	local mapsFolder = ServerStorage:FindFirstChild("Maps")

	for _, entry in maps do
		local def = entry.def :: Validate.MapDef
		if not def.enabled then
			continue
		end

		local built = mapsFolder ~= nil and mapsFolder:FindFirstChild(def.id) ~= nil
		if not built then
			table.insert(issues, {
				category = "Map",
				fileName = entry.fileName,
				field = "enabled",
				message = string.format("enabled = true but ServerStorage.Maps has no built model named %q", def.id),
			})
		end
	end
end

type Registry_Entry = { fileName: string, def: any }

local ConfigValidator: Loader.Service = {
	name = "ConfigValidator",
	dependencies = {},
}

function ConfigValidator:init()
	local issues = Validate.run({
		gameConfig = GameConfig,
		maps = Maps,
		tasks = Tasks,
		powerUps = PowerUps,
		titles = Titles,
		npcPersonalities = NPCPersonalities,
		store = Store,
	})

	checkBuiltMaps(Maps :: any, issues)

	if #issues > 0 then
		error(formatIssues(issues), 0)
	end

	print(
		string.format(
			"ConfigValidator: %d map(s), %d task(s), %d power-up(s), %d title(s), %d NPC personality(s), %d store entry(s) all valid",
			#Maps,
			#Tasks,
			#PowerUps,
			#Titles,
			#NPCPersonalities,
			#Store
		)
	)
end

return ConfigValidator
