--!strict
-- The pure rules behind live operations (P8-5): tuning the game after
-- launch without shipping an update. The service
-- (src/server/Services/LiveConfig.luau) does the DataStore and chat
-- calls; everything it has to DECIDE lives here so it can be tested
-- headlessly (tests/LiveConfigLogic.spec.luau).
--
-- Self-contained on purpose, like TeleportLogic: no requires, so Lune can
-- load it. Revalidation against the real config checkers is passed IN as
-- a callback (Validator), so this file never has to know what a
-- GameConfig is.
--
-- ===== THE ONE RULE =======================================================
--
-- A bad live config must never brick a server. Nothing here errors on
-- bad input - every function that reads a stored document returns
-- issues instead, and the answer to "this is wrong" is always "use the
-- last thing that was right": staged -> active -> shipped defaults.
--
-- The one exception to all-or-nothing rejection is the kill switches
-- (safetyFlags below). A layer that fails validation still has its
-- "turn this OFF" flags honoured, so a code update that happens to
-- invalidate an old override can't silently switch the store back on
-- in the middle of an incident. Kill switches fail closed.
--
-- ===== THE STORED DOCUMENT ================================================
--
-- One DataStore key holds an Envelope:
--
--   active  - the layer every server runs
--   staged  - an optional candidate layer, plus the percentage of
--             servers that run it INSTEAD of active (never merged with
--             it - a staged layer is a whole config, tested as one)
--
-- A server's bucket (0-99) comes from its JobId, so a given server stays
-- in or out of a rollout for its whole life rather than flapping between
-- configs on every refresh.
--
-- Overrides are dotted paths into named ROOTS, e.g.
-- "game.roundTimers.resultsSeconds" or "powerUp.freeze.durationSeconds".
-- Only paths matching GameConfig.liveOps.tunablePaths are accepted, and
-- only onto a leaf that already exists with the same type - an override
-- can change a number, never the shape of the config.

local LiveConfigLogic = {}

LiveConfigLogic.SCHEMA_VERSION = 1

-- The roots an override path may start with. Validate.luau keeps its own
-- copy of this list to check tunablePaths (it has zero requires by
-- design) - change both together.
LiveConfigLogic.ROOTS = { "game", "powerUp", "effect", "map" }

local MAX_PATH_LENGTH = 200
local MAX_STRING_VALUE_LENGTH = 100
local MAX_NOTE_LENGTH = 200
local MAX_OVERRIDES = 200

-- ===== types ===============================================================

export type Value = number | boolean | string

-- Every field optional: a missing flag means "as shipped", so an empty
-- layer is a valid layer and an older document keeps working when a new
-- flag is added.
export type Flags = {
	readOnly: boolean?,
	storeEnabled: boolean?,
	npcFillEnabled: boolean?,
	leaderboardWritesEnabled: boolean?,
	matchmakingEnabled: boolean?,
	disabledMapIds: { string }?,
	disabledTaskIds: { string }?,
	disabledPowerUpIds: { string }?,
}

export type Layer = {
	version: number,
	flags: Flags?,
	overrides: { [string]: Value }?,
	note: string?,
	editedBy: number?,
	editedAt: number?,
}

export type Staged = {
	percent: number, -- 0-100
	layer: Layer,
}

export type Envelope = {
	schema: number,
	nextVersion: number,
	active: Layer?,
	staged: Staged?,
}

-- What the rest of the server actually reads. Never optional: resolution
-- always produces a complete answer.
export type Effective = {
	readOnly: boolean,
	storeEnabled: boolean,
	npcFillEnabled: boolean,
	leaderboardWritesEnabled: boolean,
	matchmakingEnabled: boolean,
	disabledMaps: { [string]: boolean },
	disabledTasks: { [string]: boolean },
	disabledPowerUps: { [string]: boolean },
}

-- Named config trees an override path walks into. The service builds
-- this from GameConfig and the content registries.
export type Roots = { [string]: { [any]: any } }

-- The shipped content a flag may disable. `mapTasks` lists only maps
-- that ship ENABLED - a flag can switch content off, never on, because a
-- map shipped disabled may not even exist in ServerStorage yet.
export type Catalogue = {
	mapTasks: { [string]: { string } },
	taskIds: { string },
	powerUpIds: { string },
}

-- Runs the real config checkers (Validate.checkGameConfig and friends)
-- over a candidate. Returns one message per problem; empty = valid.
export type Validator = (roots: Roots) -> { string }

export type Context = {
	defaults: Roots,
	tunablePaths: { string },
	catalogue: Catalogue,
	validate: Validator,
}

export type Source = "Staged" | "Active" | "Defaults"

export type Resolution = {
	source: Source,
	version: number, -- 0 = shipped defaults
	roots: Roots,
	flags: Effective,
	issues: { string },
}

-- ===== small helpers =======================================================

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: any do
		copy[key] = deepCopy(child)
	end
	return (copy :: any) :: T
end
LiveConfigLogic.deepCopy = deepCopy

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value: any): boolean
	return isFiniteNumber(value) and value == math.floor(value)
end

local function splitPath(path: string): { string }
	return string.split(path, ".")
end

local function toSet(list: { string }?): { [string]: boolean }
	local set = {}
	if list ~= nil then
		for _, id in list do
			set[id] = true
		end
	end
	return set
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- ===== rollout bucket ======================================================

-- FNV-1a, 32-bit. Stable across servers and Luau versions, which a
-- built-in hash is not guaranteed to be. The multiply by the FNV prime
-- (2^24 + 403) is split in two so no intermediate passes 2^53.
function LiveConfigLogic.bucketFor(jobId: string): number
	local hash = 2166136261
	for i = 1, #jobId do
		hash = bit32.bxor(hash, string.byte(jobId, i))
		hash = (bit32.lshift(hash, 24) + hash * 403) % 4294967296
	end
	return hash % 100
end

-- Bucket 0-99 against a 0-100 percentage: 0% runs nobody, 100% runs
-- everybody, and raising the percentage only ever ADDS servers - a
-- server already in the rollout never drops out of it.
function LiveConfigLogic.inRollout(bucket: number, percent: number): boolean
	return bucket < percent
end

-- ===== paths ===============================================================

-- "*" matches exactly one segment; a trailing "**" matches one or more.
function LiveConfigLogic.matchesPattern(path: string, pattern: string): boolean
	local segments = splitPath(path)
	local parts = splitPath(pattern)
	for i, part in parts do
		if part == "**" and i == #parts then
			return #segments >= i
		end
		local segment = segments[i]
		if segment == nil or (part ~= "*" and part ~= segment) then
			return false
		end
	end
	return #segments == #parts
end

function LiveConfigLogic.isTunable(path: string, tunablePaths: { string }): boolean
	for _, pattern in tunablePaths do
		if LiveConfigLogic.matchesPattern(path, pattern) then
			return true
		end
	end
	return false
end

-- Walks `path` into `roots`. Returns the table holding the leaf and the
-- leaf's key, or nil if any step is missing. An all-digit segment
-- indexes an array ("game.bountyTiers.2.soleStealerVU").
local function locate(roots: Roots, path: string): ({ [any]: any }?, any)
	local segments = splitPath(path)
	local node: any = roots
	for i = 1, #segments - 1 do
		local segment = segments[i]
		local key: any = if string.match(segment, "^%d+$") then tonumber(segment) else segment
		node = if type(node) == "table" then node[key] else nil
		if type(node) ~= "table" then
			return nil, nil
		end
	end
	local last = segments[#segments]
	local key: any = if string.match(last, "^%d+$") then tonumber(last) else last
	if node[key] == nil then
		return nil, nil
	end
	return node, key
end

-- nil = acceptable. Checked both when an admin types the command (so the
-- mistake is reported to them straight away) and again at resolution (so
-- a hand-edited document gets the same treatment).
function LiveConfigLogic.checkOverride(path: any, value: any, context: Context): string?
	if type(path) ~= "string" or path == "" or #path > MAX_PATH_LENGTH then
		return "override path must be a non-empty string"
	end
	if not LiveConfigLogic.isTunable(path, context.tunablePaths) then
		return string.format("%s is not a tunable path (see GameConfig.liveOps.tunablePaths)", path)
	end
	local parent, key = locate(context.defaults, path)
	if parent == nil then
		return string.format("%s does not exist in the shipped config", path)
	end
	local default = parent[key]
	local kind = type(default)
	if kind ~= "number" and kind ~= "boolean" and kind ~= "string" then
		return string.format("%s is a %s, not a single value - override its fields instead", path, kind)
	end
	if type(value) ~= kind then
		return string.format("%s must be a %s, got %s", path, kind, type(value))
	end
	if kind == "number" and not isFiniteNumber(value) then
		return string.format("%s must be a finite number", path)
	end
	if kind == "string" and #value > MAX_STRING_VALUE_LENGTH then
		return string.format("%s is longer than %d characters", path, MAX_STRING_VALUE_LENGTH)
	end
	return nil
end

-- ===== flags ===============================================================

function LiveConfigLogic.defaultFlags(): Effective
	return {
		readOnly = false,
		storeEnabled = true,
		npcFillEnabled = true,
		leaderboardWritesEnabled = true,
		matchmakingEnabled = true,
		disabledMaps = {},
		disabledTasks = {},
		disabledPowerUps = {},
	}
end

-- Read-only mode implies the money and data kill switches: a purchase
-- taken while profiles can't be written would charge Robux for nothing,
-- so the store must refuse it (and Roblox retries the receipt later).
local function enforceImplications(effective: Effective): Effective
	if effective.readOnly then
		effective.storeEnabled = false
		effective.leaderboardWritesEnabled = false
	end
	return effective
end

function LiveConfigLogic.effectiveFlags(flags: Flags?): Effective
	local effective = LiveConfigLogic.defaultFlags()
	if flags ~= nil then
		for _, name in
			{ "readOnly", "storeEnabled", "npcFillEnabled", "leaderboardWritesEnabled", "matchmakingEnabled" }
		do
			local value = (flags :: any)[name]
			if type(value) == "boolean" then
				(effective :: any)[name] = value
			end
		end
		effective.disabledMaps = toSet(flags.disabledMapIds)
		effective.disabledTasks = toSet(flags.disabledTaskIds)
		effective.disabledPowerUps = toSet(flags.disabledPowerUpIds)
	end
	return enforceImplications(effective)
end

-- The fail-closed read (see THE ONE RULE): only the "switch it OFF"
-- direction of each kill switch, from a layer that may be malformed.
-- Content disables and tunables are NOT carried - those are ordinary
-- config, and ordinary config falls back whole.
function LiveConfigLogic.safetyFlags(rawLayer: any): Effective
	local effective = LiveConfigLogic.defaultFlags()
	local flags = if type(rawLayer) == "table" then rawLayer.flags else nil
	if type(flags) ~= "table" then
		return effective
	end
	if flags.readOnly == true then
		effective.readOnly = true
	end
	for _, name in { "storeEnabled", "npcFillEnabled", "leaderboardWritesEnabled", "matchmakingEnabled" } do
		if flags[name] == false then
			(effective :: any)[name] = false
		end
	end
	return enforceImplications(effective)
end

-- Strictest of two answers, switch by switch. Used so a kill switch set
-- in a rejected layer still wins over the layer that replaced it.
local function strictest(a: Effective, b: Effective): Effective
	a.readOnly = a.readOnly or b.readOnly
	a.storeEnabled = a.storeEnabled and b.storeEnabled
	a.npcFillEnabled = a.npcFillEnabled and b.npcFillEnabled
	a.leaderboardWritesEnabled = a.leaderboardWritesEnabled and b.leaderboardWritesEnabled
	a.matchmakingEnabled = a.matchmakingEnabled and b.matchmakingEnabled
	return enforceImplications(a)
end

local function checkIdList(label: string, list: any, known: { [string]: boolean }, issues: { string })
	if list == nil then
		return
	end
	if type(list) ~= "table" then
		table.insert(issues, string.format("flags.%s must be a list of ids", label))
		return
	end
	for _, id in list do
		if type(id) ~= "string" or not known[id] then
			table.insert(issues, string.format("flags.%s: %s is not a shipped, enabled id", label, tostring(id)))
		end
	end
end

-- Content disables must leave a playable game: at least one map, and
-- every remaining map with at least one task (Validate.checkMap's own
-- floor for a shipped map).
local function checkContentFlags(flags: Flags, catalogue: Catalogue, issues: { string })
	local mapIds = {}
	for id in catalogue.mapTasks do
		mapIds[id] = true
	end
	checkIdList("disabledMapIds", flags.disabledMapIds, mapIds, issues)
	checkIdList("disabledTaskIds", flags.disabledTaskIds, toSet(catalogue.taskIds), issues)
	checkIdList("disabledPowerUpIds", flags.disabledPowerUpIds, toSet(catalogue.powerUpIds), issues)
	if #issues > 0 then
		return
	end

	local disabledMaps = toSet(flags.disabledMapIds)
	local disabledTasks = toSet(flags.disabledTaskIds)
	local remainingMaps = 0
	for _, mapId in sortedKeys(catalogue.mapTasks) do
		if disabledMaps[mapId] then
			continue
		end
		remainingMaps += 1
		local hasTask = false
		for _, taskId in catalogue.mapTasks[mapId] do
			if not disabledTasks[taskId] then
				hasTask = true
				break
			end
		end
		if not hasTask then
			table.insert(issues, string.format("map %s would have no enabled tasks left - disable the map too", mapId))
		end
	end
	if remainingMaps == 0 then
		table.insert(issues, "every map would be disabled - at least one must stay enabled")
	end
end

-- ===== document shape ======================================================

-- The stored document is untrusted input: another build, a hand edit in
-- the Creator Hub DataStore manager, or plain corruption. Nothing past
-- this function assumes a type it didn't check.
local function checkLayerShape(raw: any, label: string, issues: { string }): Layer?
	if type(raw) ~= "table" then
		table.insert(issues, label .. " must be a table")
		return nil
	end
	local before = #issues
	if not isInteger(raw.version) or raw.version < 0 then
		table.insert(issues, label .. ".version must be a non-negative integer")
	end
	if raw.note ~= nil and (type(raw.note) ~= "string" or #raw.note > MAX_NOTE_LENGTH) then
		table.insert(issues, label .. ".note must be a short string")
	end
	if raw.editedBy ~= nil and not isInteger(raw.editedBy) then
		table.insert(issues, label .. ".editedBy must be a user id")
	end
	if raw.editedAt ~= nil and not isFiniteNumber(raw.editedAt) then
		table.insert(issues, label .. ".editedAt must be a timestamp")
	end
	if raw.flags ~= nil then
		if type(raw.flags) ~= "table" then
			table.insert(issues, label .. ".flags must be a table")
		else
			for name, value in raw.flags do
				local isList = name == "disabledMapIds" or name == "disabledTaskIds" or name == "disabledPowerUpIds"
				local isSwitch = name == "readOnly"
					or name == "storeEnabled"
					or name == "npcFillEnabled"
					or name == "leaderboardWritesEnabled"
					or name == "matchmakingEnabled"
				if isSwitch and type(value) ~= "boolean" then
					table.insert(issues, string.format("%s.flags.%s must be a boolean", label, tostring(name)))
				elseif not isSwitch and not isList then
					table.insert(issues, string.format("%s.flags.%s is not a known flag", label, tostring(name)))
				end
			end
		end
	end
	if raw.overrides ~= nil then
		if type(raw.overrides) ~= "table" then
			table.insert(issues, label .. ".overrides must be a table")
		else
			local count = 0
			for key in raw.overrides do
				count += 1
				if type(key) ~= "string" then
					table.insert(issues, label .. ".overrides keys must be path strings")
					break
				end
			end
			if count > MAX_OVERRIDES then
				table.insert(issues, string.format("%s has %d overrides, more than %d", label, count, MAX_OVERRIDES))
			end
		end
	end
	return if #issues == before then raw :: Layer else nil
end

function LiveConfigLogic.emptyEnvelope(): Envelope
	return { schema = LiveConfigLogic.SCHEMA_VERSION, nextVersion = 1, active = nil, staged = nil }
end

-- nil (never written) is the normal first-launch state, not an error.
function LiveConfigLogic.checkEnvelopeShape(raw: any): (Envelope?, { string })
	local issues = {}
	if raw == nil then
		return LiveConfigLogic.emptyEnvelope(), issues
	end
	if type(raw) ~= "table" then
		table.insert(issues, "the live config document is not a table")
		return nil, issues
	end
	if raw.schema ~= LiveConfigLogic.SCHEMA_VERSION then
		table.insert(
			issues,
			string.format(
				"schema %s is not the %d this build reads",
				tostring(raw.schema),
				LiveConfigLogic.SCHEMA_VERSION
			)
		)
		return nil, issues
	end
	if not isInteger(raw.nextVersion) or raw.nextVersion < 1 then
		table.insert(issues, "nextVersion must be a positive integer")
	end
	if raw.active ~= nil then
		checkLayerShape(raw.active, "active", issues)
	end
	if raw.staged ~= nil then
		if type(raw.staged) ~= "table" then
			table.insert(issues, "staged must be a table")
		else
			if not isInteger(raw.staged.percent) or raw.staged.percent < 0 or raw.staged.percent > 100 then
				table.insert(issues, "staged.percent must be an integer 0-100")
			end
			checkLayerShape(raw.staged.layer, "staged.layer", issues)
		end
	end
	return if #issues == 0 then raw :: Envelope else nil, issues
end

-- ===== applying a layer ====================================================

-- Builds the full candidate for one layer: a copy of the shipped
-- defaults with every override written in, checked as a whole. All or
-- nothing - a layer with one bad override is rejected entirely, because
-- a half-applied tuning pass is a combination nobody tested.
function LiveConfigLogic.applyLayer(layer: Layer, context: Context): (Roots?, Effective?, { string })
	local issues = {}
	local roots = deepCopy(context.defaults)

	local overrides = layer.overrides or {}
	for _, path in sortedKeys(overrides) do
		local value = overrides[path]
		local problem = LiveConfigLogic.checkOverride(path, value, context)
		if problem ~= nil then
			table.insert(issues, problem)
			continue
		end
		local parent, key = locate(roots, path)
		assert(parent ~= nil, "checkOverride already located this path")
		parent[key] = value
	end

	if layer.flags ~= nil then
		checkContentFlags(layer.flags, context.catalogue, issues)
	end
	if #issues > 0 then
		return nil, nil, issues
	end

	-- The validator is the service's code path into Validate.luau; if it
	-- throws, that's a rejection, not a crash.
	local ok, result = pcall(context.validate, roots)
	if not ok then
		return nil, nil, { "the config validator threw: " .. tostring(result) }
	end
	if #result > 0 then
		return nil, nil, result
	end
	return roots, LiveConfigLogic.effectiveFlags(layer.flags), issues
end

-- The whole decision for one server, from whatever was in the DataStore.
-- Staged (if this server is in the rollout) -> active -> shipped
-- defaults, taking the first that validates.
function LiveConfigLogic.resolve(raw: any, bucket: number, context: Context): Resolution
	local issues = {}
	local envelope, shapeIssues = LiveConfigLogic.checkEnvelopeShape(raw)
	local safety = LiveConfigLogic.defaultFlags()

	if envelope == nil then
		for _, problem in shapeIssues do
			table.insert(issues, problem)
		end
		-- Even an unreadable document may carry a kill switch.
		if type(raw) == "table" then
			safety = strictest(safety, LiveConfigLogic.safetyFlags(raw.active))
		end
		return {
			source = "Defaults",
			version = 0,
			roots = deepCopy(context.defaults),
			flags = safety,
			issues = issues,
		}
	end

	local candidates: { { source: Source, layer: Layer } } = {}
	local staged = envelope.staged
	if staged ~= nil and LiveConfigLogic.inRollout(bucket, staged.percent) then
		table.insert(candidates, { source = "Staged", layer = staged.layer })
	end
	if envelope.active ~= nil then
		table.insert(candidates, { source = "Active", layer = envelope.active })
	end

	for _, candidate in candidates do
		local roots, flags, layerIssues = LiveConfigLogic.applyLayer(candidate.layer, context)
		if roots ~= nil and flags ~= nil then
			return {
				source = candidate.source,
				version = candidate.layer.version,
				roots = roots,
				flags = strictest(flags, safety),
				issues = issues,
			}
		end
		for _, problem in layerIssues do
			table.insert(issues, string.format("%s v%d: %s", candidate.source, candidate.layer.version, problem))
		end
		safety = strictest(safety, LiveConfigLogic.safetyFlags(candidate.layer))
	end

	return { source = "Defaults", version = 0, roots = deepCopy(context.defaults), flags = safety, issues = issues }
end

-- Copies every leaf of `resolved` into the matching leaf of `live`, in
-- place, and returns how many changed. In place because services capture
-- sub-tables at require time (`local config = GameConfig.matchmaking`):
-- replacing the table would leave them reading the old one forever.
-- Syncing EVERY leaf (not just overridden ones) is what restores a
-- default when an override is removed.
function LiveConfigLogic.syncLeaves(live: { [any]: any }, resolved: { [any]: any }): number
	local changed = 0
	for key, value in resolved do
		local current = live[key]
		if type(value) == "table" then
			if type(current) == "table" then
				changed += LiveConfigLogic.syncLeaves(current, value)
			end
		elseif current ~= value then
			live[key] = value
			changed += 1
		end
	end
	return changed
end

-- ===== admin commands ======================================================

export type CommandKind =
	"Status"
	| "Set"
	| "Unset"
	| "Disable"
	| "Enable"
	| "Flag"
	| "Kill"
	| "ReadOnly"
	| "Rollout"
	| "Promote"
	| "Abort"

export type Command = {
	kind: CommandKind,
	path: string?,
	value: Value?,
	category: string?, -- "map" | "task" | "powerup"
	id: string?,
	switch: string?, -- a key of SWITCHES
	on: boolean?,
	percent: number?,
}

-- Admin-facing names for the kill switches.
local SWITCHES: { [string]: string } = {
	store = "storeEnabled",
	npcfill = "npcFillEnabled",
	leaderboard = "leaderboardWritesEnabled",
	matchmaking = "matchmakingEnabled",
}

local CONTENT_LISTS: { [string]: string } = {
	map = "disabledMapIds",
	task = "disabledTaskIds",
	powerup = "disabledPowerUpIds",
}

LiveConfigLogic.USAGE = table.concat({
	"status",
	"set <path> <value> | unset <path>",
	"disable|enable map|task|powerup <id>",
	"flag store|npcfill|leaderboard|matchmaking on|off",
	"rollout <0-100> | promote | abort",
	"kill store|npcfill|leaderboard|matchmaking   (immediate, every server)",
	"readonly on|off   (immediate, every server)",
}, "\n")

-- "true"/"false" -> boolean, anything tonumber reads -> number, else the
-- raw string. checkOverride then insists it matches the default's type.
function LiveConfigLogic.parseValue(text: string): Value
	if text == "true" then
		return true
	elseif text == "false" then
		return false
	end
	local number = tonumber(text)
	if number ~= nil then
		return number
	end
	return text
end

local function parseOnOff(word: string?): boolean?
	if word == "on" then
		return true
	elseif word == "off" then
		return false
	end
	return nil
end

-- `text` is everything after the command prefix, e.g.
-- "set game.roundTimers.resultsSeconds 10". Case-sensitive on paths and
-- ids (config keys are), lower-case on keywords.
function LiveConfigLogic.parseCommand(text: string): (Command?, string?)
	local words = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(words, word)
	end
	local verb = string.lower(words[1] or "")
	local arg1, arg2 = words[2], words[3]
	local bad = "usage:\n" .. LiveConfigLogic.USAGE

	if verb == "status" and #words == 1 then
		return { kind = "Status" }, nil
	elseif verb == "set" and #words >= 3 then
		-- A string value may contain spaces; everything after the path is it.
		local rest = table.concat(words, " ", 3)
		return { kind = "Set", path = arg1, value = LiveConfigLogic.parseValue(rest) }, nil
	elseif verb == "unset" and #words == 2 then
		return { kind = "Unset", path = arg1 }, nil
	elseif (verb == "disable" or verb == "enable") and #words == 3 then
		local category = string.lower(arg1)
		if CONTENT_LISTS[category] == nil then
			return nil, "category must be map, task or powerup"
		end
		return { kind = if verb == "disable" then "Disable" else "Enable", category = category, id = arg2 }, nil
	elseif verb == "flag" and #words == 3 then
		local switch = string.lower(arg1)
		local on = parseOnOff(string.lower(arg2))
		if SWITCHES[switch] == nil or on == nil then
			return nil, bad
		end
		return { kind = "Flag", switch = switch, on = on }, nil
	elseif verb == "kill" and #words == 2 then
		local switch = string.lower(arg1)
		if SWITCHES[switch] == nil then
			return nil, bad
		end
		return { kind = "Kill", switch = switch }, nil
	elseif verb == "readonly" and #words == 2 then
		local on = parseOnOff(string.lower(arg1))
		if on == nil then
			return nil, bad
		end
		return { kind = "ReadOnly", on = on }, nil
	elseif verb == "rollout" and #words == 2 then
		local percent = tonumber(arg1)
		if percent == nil or not isInteger(percent) or percent < 0 or percent > 100 then
			return nil, "rollout takes an integer percentage, 0-100"
		end
		return { kind = "Rollout", percent = percent }, nil
	elseif verb == "promote" and #words == 1 then
		return { kind = "Promote" }, nil
	elseif verb == "abort" and #words == 1 then
		return { kind = "Abort" }, nil
	end
	return nil, bad
end

function LiveConfigLogic.isAdmin(userId: number, adminUserIds: { number }): boolean
	return table.find(adminUserIds, userId) ~= nil
end

export type Actor = {
	userId: number,
	now: number,
}

local function emptyLayer(): Layer
	return { version = 0, flags = nil, overrides = nil }
end

local function stamp(envelope: Envelope, layer: Layer, actor: Actor)
	layer.version = envelope.nextVersion
	layer.editedBy = actor.userId
	layer.editedAt = actor.now
	envelope.nextVersion += 1
end

-- Ordinary edits go to the staged layer, never straight to active: every
-- tuning change reaches players through a rollout. Creating the staged
-- layer copies active, at 0%, so nothing changes until `rollout`.
local function stagedLayer(envelope: Envelope): Layer
	if envelope.staged == nil then
		envelope.staged = { percent = 0, layer = deepCopy(envelope.active or emptyLayer()) }
	end
	return (envelope.staged :: Staged).layer
end

local function editList(layer: Layer, listName: string, id: string, add: boolean)
	local flags: any = layer.flags or {}
	layer.flags = flags
	local list: { string } = flags[listName] or {}
	local index = table.find(list, id)
	if add and index == nil then
		table.insert(list, id)
		table.sort(list)
	elseif not add and index ~= nil then
		table.remove(list, index)
	end
	flags[listName] = if #list > 0 then list else nil
end

local function describeLayer(label: string, layer: Layer?): string
	if layer == nil then
		return label .. ": none"
	end
	local overrideCount = 0
	local overrides = layer.overrides
	if overrides ~= nil then
		for _ in overrides do
			overrideCount += 1
		end
	end
	local effective = LiveConfigLogic.effectiveFlags(layer.flags)
	local off = {}
	for word, flag in SWITCHES do
		if (effective :: any)[flag] == false then
			table.insert(off, word)
		end
	end
	table.sort(off)
	return string.format(
		"%s: v%d, %d override(s)%s%s",
		label,
		layer.version,
		overrideCount,
		if effective.readOnly then ", READ-ONLY" else "",
		if #off > 0 then ", off: " .. table.concat(off, ",") else ""
	)
end

function LiveConfigLogic.describe(envelope: Envelope, bucket: number, running: Resolution?): string
	local lines = { describeLayer("active", envelope.active) }
	local staged = envelope.staged
	if staged ~= nil then
		table.insert(lines, describeLayer(string.format("staged @%d%%", staged.percent), staged.layer))
	end
	if running ~= nil then
		table.insert(
			lines,
			string.format("this server: bucket %d, running %s v%d", bucket, running.source, running.version)
		)
	end
	return table.concat(lines, "\n")
end

-- Applies one admin command to a COPY of the envelope. Returns the new
-- envelope to write (nil = nothing to write) and a message for the admin.
-- A staged edit that wouldn't validate is refused here, so a broken
-- config never reaches the DataStore in the first place - resolution's
-- own checks are the second line, not the first.
function LiveConfigLogic.applyCommand(
	current: Envelope,
	command: Command,
	actor: Actor,
	context: Context
): (Envelope?, string)
	local envelope = deepCopy(current)
	local kind = command.kind

	if kind == "Status" then
		return nil, LiveConfigLogic.describe(envelope, 0, nil)
	elseif kind == "Promote" then
		local staged = envelope.staged
		if staged == nil then
			return nil, "nothing is staged"
		end
		envelope.active = staged.layer
		envelope.staged = nil
		return envelope, string.format("promoted v%d to every server", staged.layer.version)
	elseif kind == "Abort" then
		if envelope.staged == nil then
			return nil, "nothing is staged"
		end
		envelope.staged = nil
		return envelope, "staged layer discarded; every server runs active"
	elseif kind == "Rollout" then
		local staged = envelope.staged
		if staged == nil then
			return nil, "nothing is staged - make an edit first"
		end
		staged.percent = command.percent :: number
		return envelope, string.format("staged v%d now on %d%% of servers", staged.layer.version, staged.percent)
	elseif kind == "Kill" or kind == "ReadOnly" then
		-- Emergencies skip staging and hit active AND staged, so no
		-- server anywhere keeps running the thing being switched off.
		local flagName = if kind == "Kill" then SWITCHES[command.switch :: string] else "readOnly"
		local value = if kind == "Kill" then false else command.on :: boolean
		envelope.active = envelope.active or emptyLayer()
		local layers = { envelope.active :: Layer }
		if envelope.staged ~= nil then
			table.insert(layers, envelope.staged.layer)
		end
		for _, layer in layers do
			local flags: any = layer.flags or {}
			flags[flagName] = value
			layer.flags = flags
			stamp(envelope, layer, actor)
		end
		return envelope, string.format("%s = %s on every server", flagName, tostring(value))
	end

	-- Everything else is an ordinary, staged edit.
	local layer = stagedLayer(envelope)
	if kind == "Set" then
		local path = command.path :: string
		local problem = LiveConfigLogic.checkOverride(path, command.value, context)
		if problem ~= nil then
			return nil, problem
		end
		local overrides = layer.overrides or {}
		overrides[path] = command.value :: Value
		layer.overrides = overrides
	elseif kind == "Unset" then
		local overrides = layer.overrides
		local path = command.path :: string
		if overrides == nil or overrides[path] == nil then
			return nil, path .. " has no override in the staged layer"
		end
		overrides[path] = nil
		if next(overrides) == nil then
			layer.overrides = nil
		end
	elseif kind == "Disable" or kind == "Enable" then
		editList(layer, CONTENT_LISTS[command.category :: string], command.id :: string, kind == "Disable")
	elseif kind == "Flag" then
		local flags: any = layer.flags or {}
		flags[SWITCHES[command.switch :: string]] = command.on
		layer.flags = flags
	end

	local _, _, issues = LiveConfigLogic.applyLayer(layer, context)
	if #issues > 0 then
		return nil, "refused: " .. table.concat(issues, "; ")
	end
	stamp(envelope, layer, actor)
	local staged = envelope.staged :: Staged
	return envelope,
		string.format("staged v%d (on %d%% of servers - `rollout <percent>` to widen)", layer.version, staged.percent)
end

-- ===== audit log ===========================================================

export type AuditEntry = {
	at: number,
	userId: number,
	command: string,
	ok: boolean,
	message: string,
	version: number, -- envelope.nextVersion - 1 after the command
}

-- Newest last, capped from the front. Refused commands are logged too:
-- "someone tried to switch the store back on" is worth knowing.
function LiveConfigLogic.appendAudit(log: any, entry: AuditEntry, cap: number): { AuditEntry }
	local entries: { AuditEntry } = {}
	if type(log) == "table" then
		for _, existing in log do
			if type(existing) == "table" then
				table.insert(entries, existing)
			end
		end
	end
	table.insert(entries, entry)
	while #entries > cap do
		table.remove(entries, 1)
	end
	return entries
end

return LiveConfigLogic
