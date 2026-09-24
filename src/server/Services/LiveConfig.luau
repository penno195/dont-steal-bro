--!strict
-- Live operations (P8-5): tune and switch off parts of the game after
-- launch without shipping an update. Every rule lives in
-- LiveConfigLogic.luau (tested headlessly); this file is only the
-- Roblox side of it - the DataStore read and refresh, applying a
-- resolved config to the live config tables, and the admin chat
-- command. Operator guide: docs/live-ops.md.
--
-- HOW OTHER SERVICES READ IT
--
--   Tunables need no code at all. The resolved values are copied leaf
--   by leaf INTO the live GameConfig / PowerUps / StatusEffectDefs /
--   Maps tables (LiveConfigLogic.syncLeaves), so any service that reads
--   `GameConfig.roundTimers.resultsSeconds` at the moment it needs it
--   sees the live value. The one way to break this is caching a scalar
--   at require time (`local RESULTS = GameConfig.roundTimers.results
--   Seconds`) - don't; capturing a sub-TABLE is fine.
--
--   Flags are read on demand through `LiveConfig.flags()` and the
--   `is*Enabled` helpers, at the moment a decision is made. Services
--   that consult them declare `dependencies = { "LiveConfig" }`.
--
-- WHAT ARRIVES WHEN
--
--   The first fetch happens in init(), so a kill switch set before this
--   server booted is in force before any other service starts. If that
--   fetch fails the server runs shipped defaults until the first
--   successful refresh (every liveOps.refreshSeconds). A later failed
--   fetch keeps the last good resolution rather than dropping to
--   defaults - an outage must not undo a kill switch.
--
-- VERIFIED APIs (globalTypes.d.luau):
--   DataStoreService:GetDataStore(name) -> DataStore
--   GlobalDataStore:GetAsync(key, DataStoreGetOptions?) -> (any, DataStoreKeyInfo)
--   GlobalDataStore:UpdateAsync(key, (any, DataStoreKeyInfo) -> any) -> (any, DataStoreKeyInfo)
--   DataStoreGetOptions.UseCache: boolean
--   TextChatCommand.PrimaryAlias / AutocompleteVisible / Triggered(TextSource, string)
--   TextSource.UserId: number
-- Triggered is handled on the server, as in Roblox's own "custom text
-- chat commands" example (a ServerScriptService script reading
-- textSource.UserId). Command replies go to the server log (F9 ->
-- Server) - there is no remote for them, and admins are developers.

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TextChatService = game:GetService("TextChatService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Maps = require(ReplicatedStorage.Shared.Config.Maps)
local Tasks = require(ReplicatedStorage.Shared.Config.Tasks)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local Titles = require(ReplicatedStorage.Shared.Config.Titles)
local NPCPersonalities = require(ReplicatedStorage.Shared.Config.NPCPersonalities)
local Store = require(ReplicatedStorage.Shared.Config.Store)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local LightingPresets = require(ReplicatedStorage.Shared.Config.LightingPresets)
local StatusEffectDefs = require(ServerScriptService.Server.Services.StatusEffectDefs)
local LiveConfigLogic = require(ServerScriptService.Server.LiveConfigLogic)

local config = GameConfig.liveOps
local COMMAND_ALIAS = "/liveops"

-- Separate store in Studio, decided by RunService like DataService's -
-- so a Studio session with API access on can't flip a production kill
-- switch by testing a command.
local STORE_NAME = if RunService:IsStudio() then config.dataStoreName .. "_Studio" else config.dataStoreName

-- ===== roots ===============================================================

-- The live tables an override path walks into. These ARE the shipped
-- config tables, so syncing into them is what makes a tunable live.
local liveRoots: LiveConfigLogic.Roots = {
	game = GameConfig :: any,
	powerUp = {},
	effect = StatusEffectDefs :: any,
	map = {},
}
for _, entry in PowerUps do
	liveRoots.powerUp[entry.def.id] = entry.def
end
for _, entry in Maps do
	liveRoots.map[entry.def.id] = entry.def
end

-- Rebuilds a registry list around candidate defs, keeping file names so
-- a refusal reads exactly like a boot-time ConfigValidator error.
local function withDefs(registry: { { fileName: string, def: any } }, byId: { [string]: any }): { any }
	local list = {}
	for _, entry in registry do
		table.insert(list, { fileName = entry.fileName, def = byId[entry.def.id] or entry.def })
	end
	return list
end

-- Effects have no checker in Validate.luau (they are code-owned, not a
-- registry), so the live bounds are here: finite, positive, and a
-- Multiply can't flip direction - a debuff can't be tuned into a buff.
local function checkEffects(effects: { [string]: any }, issues: { string })
	for id, def in effects do
		local magnitude, duration = def.magnitude, def.durationSeconds
		if type(duration) ~= "number" or not (duration > 0 and duration < math.huge) then
			table.insert(issues, string.format("effect %s: durationSeconds must be positive", id))
		end
		if type(magnitude) ~= "number" or not (magnitude > 0 and magnitude < math.huge) then
			table.insert(issues, string.format("effect %s: magnitude must be positive", id))
		elseif def.operation == "Multiply" then
			if def.kind == "Debuff" and magnitude > 1 then
				table.insert(issues, string.format("effect %s: a debuff multiplier must be <= 1", id))
			elseif def.kind == "Buff" and magnitude < 1 then
				table.insert(issues, string.format("effect %s: a buff multiplier must be >= 1", id))
			end
		end
	end
end

local function validateRoots(roots: LiveConfigLogic.Roots): { string }
	local found = Validate.run({
		gameConfig = roots.game :: any,
		maps = withDefs(Maps :: any, roots.map) :: any,
		tasks = Tasks :: any,
		powerUps = withDefs(PowerUps :: any, roots.powerUp) :: any,
		titles = Titles :: any,
		npcPersonalities = NPCPersonalities :: any,
		store = Store :: any,
		cosmetics = Cosmetics :: any,
		lightingPresets = LightingPresets :: any,
	})
	local issues = {}
	for _, problem in found do
		table.insert(issues, string.format("%s (%s): %s", problem.fileName, problem.field, problem.message))
	end
	checkEffects(roots.effect, issues)
	return issues
end

local function buildCatalogue(): LiveConfigLogic.Catalogue
	local mapTasks = {}
	for _, entry in Maps do
		if entry.def.enabled then
			mapTasks[entry.def.id] = table.clone(entry.def.enabledTaskIds)
		end
	end
	local taskIds, powerUpIds = {}, {}
	for _, entry in Tasks do
		table.insert(taskIds, entry.def.id)
	end
	for _, entry in PowerUps do
		table.insert(powerUpIds, entry.def.id)
	end
	return { mapTasks = mapTasks, taskIds = taskIds, powerUpIds = powerUpIds }
end

-- Snapshotted before anything is synced, so "shipped defaults" means
-- what shipped, not whatever the last resolution left in the tables.
local context: LiveConfigLogic.Context = {
	defaults = LiveConfigLogic.deepCopy(liveRoots),
	tunablePaths = config.tunablePaths,
	catalogue = buildCatalogue(),
	validate = validateRoots,
}

-- ===== state ===============================================================

local bucket = LiveConfigLogic.bucketFor(game.JobId)
local store: DataStore? = nil
local current: LiveConfigLogic.Resolution = {
	source = "Defaults",
	version = 0,
	roots = context.defaults,
	flags = LiveConfigLogic.defaultFlags(),
	issues = {},
}

local function apply(resolution: LiveConfigLogic.Resolution)
	local changed = LiveConfigLogic.syncLeaves(liveRoots, resolution.roots)
	local moved = resolution.source ~= current.source or resolution.version ~= current.version
	current = resolution
	for _, problem in resolution.issues do
		warn("LiveConfig: " .. problem)
	end
	if moved or changed > 0 then
		print(
			string.format(
				"LiveConfig: running %s v%d (bucket %d, %d value(s) changed)",
				resolution.source,
				resolution.version,
				bucket,
				changed
			)
		)
	end
end

-- (ok, raw). ok = false means the read failed - keep what we have.
local function fetch(): (boolean, any)
	local liveStore = store
	if liveStore == nil then
		return false, nil
	end
	local options = Instance.new("DataStoreGetOptions")
	options.UseCache = false
	local ok, raw = pcall(function()
		return (liveStore:GetAsync(config.envelopeKey, options))
	end)
	if not ok then
		warn("LiveConfig: fetch failed, keeping the current config: " .. tostring(raw))
	end
	return ok, raw
end

local function refresh()
	local ok, raw = fetch()
	if ok then
		apply(LiveConfigLogic.resolve(raw, bucket, context))
	end
end

-- ===== admin commands ======================================================

local function audit(entry: LiveConfigLogic.AuditEntry)
	local liveStore = store :: DataStore
	local ok, err = pcall(function()
		liveStore:UpdateAsync(config.auditKey, function(log: any): any
			return LiveConfigLogic.appendAudit(log, entry, config.auditLogCap)
		end)
	end)
	if not ok then
		warn("LiveConfig: audit write failed: " .. tostring(err))
	end
end

local function runCommand(userId: number, text: string)
	local liveStore = store
	if liveStore == nil then
		print("LiveConfig: live config is disabled on this server (liveOps.enabled = false)")
		return
	end

	local command, parseError = LiveConfigLogic.parseCommand(text)
	if command == nil then
		print(string.format("LiveConfig: %s\n%s", parseError or "bad command", LiveConfigLogic.USAGE))
		return
	end
	if command.kind == "Status" then
		local _, raw = fetch()
		local envelope = LiveConfigLogic.checkEnvelopeShape(raw) or LiveConfigLogic.emptyEnvelope()
		print("LiveConfig:\n" .. LiveConfigLogic.describe(envelope, bucket, current))
		return
	end

	-- UpdateAsync, so two admins on two servers can't overwrite each
	-- other. The transform may run more than once; applyCommand is pure,
	-- so the LAST run's message is the true one.
	local message = "no change"
	local written: LiveConfigLogic.Envelope? = nil
	local actor = { userId = userId, now = os.time() }
	local ok, err = pcall(function()
		liveStore:UpdateAsync(config.envelopeKey, function(raw: any): any
			written = nil
			local envelope, shapeIssues = LiveConfigLogic.checkEnvelopeShape(raw)
			if envelope == nil then
				if raw ~= nil and command.kind ~= "Kill" and command.kind ~= "ReadOnly" then
					-- Only an emergency may replace an unreadable document;
					-- anything else is a hand-fix (DataStore history keeps
					-- the old version).
					message = "refused: the stored config is unreadable ("
						.. table.concat(shapeIssues, "; ")
						.. ") - only kill/readonly may overwrite it"
					return nil
				end
				envelope = LiveConfigLogic.emptyEnvelope()
			end
			local nextEnvelope, reply = LiveConfigLogic.applyCommand(envelope :: any, command, actor, context)
			message = reply
			written = nextEnvelope
			return nextEnvelope -- nil cancels the write
		end)
	end)
	if not ok then
		message = "DataStore write failed: " .. tostring(err)
		written = nil
	end

	local wroteEnvelope = written
	audit({
		at = actor.now,
		userId = userId,
		command = string.sub(text, 1, 200),
		ok = wroteEnvelope ~= nil,
		message = message,
		version = if wroteEnvelope ~= nil then wroteEnvelope.nextVersion - 1 else 0,
	})
	print(string.format("LiveConfig [%d]: %s", userId, message))
	if wroteEnvelope ~= nil then
		-- This server applies at once; every other server within
		-- liveOps.refreshSeconds.
		apply(LiveConfigLogic.resolve(wroteEnvelope, bucket, context))
	end
end

local function installCommand()
	local command = Instance.new("TextChatCommand")
	command.Name = "LiveOpsCommand"
	command.PrimaryAlias = COMMAND_ALIAS
	command.AutocompleteVisible = false
	command.Triggered:Connect(function(source: TextSource, text: string)
		-- The only gate. A non-admin gets no reply and no audit entry, so
		-- the command's existence isn't confirmed to them.
		if not LiveConfigLogic.isAdmin(source.UserId, config.adminUserIds) then
			return
		end
		local body = string.gsub(string.sub(text, #COMMAND_ALIAS + 1), "^%s+", "")
		task.spawn(runCommand, source.UserId, body)
	end)
	command.Parent = TextChatService
end

-- ===== service =============================================================

local LiveConfig: Loader.Service = {
	name = "LiveConfig",
	dependencies = { "ConfigValidator" },
}

function LiveConfig.flags(): LiveConfigLogic.Effective
	return current.flags
end

function LiveConfig.isMapEnabled(mapId: string): boolean
	return not current.flags.disabledMaps[mapId]
end

function LiveConfig.isTaskEnabled(taskId: string): boolean
	return not current.flags.disabledTasks[taskId]
end

function LiveConfig.isPowerUpEnabled(powerUpId: string): boolean
	return not current.flags.disabledPowerUps[powerUpId]
end

function LiveConfig:init()
	if not config.enabled then
		print("LiveConfig: disabled (liveOps.enabled = false) - running shipped defaults")
		return
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn("LiveConfig: no DataStore access, running shipped defaults: " .. tostring(result))
		return
	end
	store = result
	refresh()
end

function LiveConfig:start()
	if store == nil then
		return
	end
	installCommand()
	task.spawn(function()
		while true do
			task.wait(config.refreshSeconds)
			refresh()
		end
	end)
end

return LiveConfig
