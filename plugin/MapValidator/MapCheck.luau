--!strict
-- The map validator's rule engine (P7-1). Every check against
-- docs/map-kit-spec.md and docs/perf-budget.md lives here, as pure
-- functions over a plain-table MapSnapshot - no Instance, no Vector3, no
-- service. That split is what lets one set of rules serve three callers
-- without drifting apart: the Studio plugin (Main.server.luau), the
-- headless CI runner (scripts/validate-maps.luau, under Lune), and the
-- Jest-style spec (tests/MapCheck.spec.luau). Snapshot.luau is the only
-- thing that ever touches a real Instance tree.
--
-- The one check that can't be pure is reachability: it needs
-- PathfindingService, which only exists inside Studio. The plugin runs
-- it and passes the result in as `Context.unreachableIds`; the headless
-- runner leaves that nil and the report says the check was skipped,
-- rather than silently passing it.
--
-- Severity is the shipping gate: any "error" fails the map, "warning"
-- never does, "info" is just a number worth seeing.

local MapCheck = {}

-- ===== snapshot types ========================================================

export type Vec3 = { x: number, y: number, z: number }

-- An oriented box: a BasePart's CFrame and Size. `right`/`up`/`back` are
-- the CFrame's unit X/Y/Z axes (back = -LookVector), matching Roblox's
-- own convention so Snapshot can copy them straight across.
export type Box = { center: Vec3, right: Vec3, up: Vec3, back: Vec3, size: Vec3 }

export type Node = {
	id: number, -- index into the snapshot; the plugin maps it back to the Instance for click-to-select
	path: string, -- relative to the map root, for the report text
	className: string,
	-- Only the classes the rules ask about - Snapshot fills this from :IsA,
	-- so inheritance (MeshPart is a BasePart) is already resolved.
	isA: { [string]: boolean },
	tags: { string },
	attributes: { [string]: any },
	box: Box?, -- BaseParts only
	position: Vec3?, -- Attachments only: world position
	anchored: boolean?,
	canCollide: boolean?,
	canTouch: boolean?,
	canQuery: boolean?,
	collisionFidelity: string?, -- TriangleMeshParts only: the Enum item's Name
	meshId: string?,
	textureIds: { string },
}

export type MapSnapshot = { name: string, nodes: { Node } }

-- Only the MapDef fields the validator cross-checks - a subset of
-- Validate.MapDef, so the headless runner can hand over the real def.
export type MapDefLite = { id: string, enabledTaskIds: { string }, taskStationCount: number }

export type PowerUpLite = { id: string, rarity: string }

-- docs/perf-budget.md §1. Every number there is marked low confidence
-- until P7-4 re-baselines it on a real device, so they're overridable
-- per run rather than hard-coded into the rules.
export type Budget = {
	maxInstances: number,
	maxUniqueMeshes: number,
	maxUniqueTextures: number,
	-- map-kit-spec.md's "~1.5-2x the TaskStation count".
	minNavNodesPerStation: number,
	-- How far a TaskStation/PowerUpSpawn may sit from its nearest NavNode
	-- before it's flagged. A builder judgment call per the spec, so a
	-- warning; the reachability check is the hard gate.
	navProximityStuds: number,
	-- Grid spacing for the fall-through-gap scan. A character is ~2
	-- studs wide, so a 4-stud grid can miss a gap narrower than that - a
	-- deliberate trade against the scan cost on a 250x250 map.
	gapGridStuds: number,
}

MapCheck.DEFAULT_BUDGET = table.freeze({
	maxInstances = 12000,
	maxUniqueMeshes = 150,
	maxUniqueTextures = 100,
	minNavNodesPerStation = 1.5,
	navProximityStuds = 40,
	gapGridStuds = 4,
}) :: Budget

export type Context = {
	taskIds: { string },
	powerUps: { PowerUpLite },
	mapDef: MapDefLite?, -- nil = no config file for this map yet
	budget: Budget?,
	unreachableIds: { number }?, -- nil = reachability not checked (headless)
}

-- ===== report types ==========================================================

export type Severity = "error" | "warning" | "info"

export type Finding = {
	severity: Severity,
	category: string,
	rule: string, -- stable kebab-case id, for tests and for grepping CI logs
	message: string,
	nodeIds: { number },
	positions: { Vec3 }, -- for findings with no instance to select (gaps)
}

export type Report = {
	mapName: string,
	findings: { Finding },
	errorCount: number,
	warningCount: number,
	passed: boolean,
	summary: string,
}

-- Report order. Security first: it's the finding that matters most if
-- someone only reads the top of a long report.
MapCheck.CATEGORIES = table.freeze({
	"Security",
	"Tags",
	"Attributes",
	"Config",
	"Reachability",
	"Navigation",
	"Bounds",
	"Performance",
})

-- ===== the tag contract (map-kit-spec.md §1) =================================

type TagRule = { tag: string, class: string, min: number, max: number? }

local TAG_RULES: { TagRule } = {
	{ tag = "SpawnPoint", class = "BasePart", min = 6, max = 6 },
	{ tag = "TaskStation", class = "BasePart", min = 12, max = 24 },
	{ tag = "PowerUpSpawn", class = "BasePart", min = 8, max = 20 },
	-- The spec sets no hard floor, but a map with zero nodes strands every
	-- NPC, so one is the minimum; the per-station ratio is a warning below.
	{ tag = "NavNode", class = "Attachment", min = 1 },
	{ tag = "PlayableBounds", class = "BasePart", min = 1, max = 4 },
	{ tag = "KillZone", class = "BasePart", min = 1 },
	{ tag = "StudioAnchor", class = "BasePart", min = 1, max = 1 },
	{ tag = "StudioPodiumSlot", class = "BasePart", min = 3, max = 3 },
	{ tag = "StudioBoundary", class = "BasePart", min = 1, max = 1 },
	{ tag = "StudioSpectatorArea", class = "BasePart", min = 0, max = 1 },
}

local CONTRACT_TAGS: { [string]: boolean } = {}
local CONTRACT_TAGS_LOWER: { [string]: string } = {}
for _, rule in TAG_RULES do
	CONTRACT_TAGS[rule.tag] = true
	CONTRACT_TAGS_LOWER[string.lower(rule.tag)] = rule.tag
end
MapCheck.TAG_RULES = TAG_RULES

-- The builder's checklist: "only parts that need to detect a player
-- (kill zones, task station triggers) should have CanTouch = true".
-- PowerUpSpawn isn't here - PowerUpService spawns its own touchable
-- pickup part on top of the pad, the pad itself never needs Touched.
local CAN_TOUCH_TAGS: { [string]: boolean } = { KillZone = true, TaskStation = true }

-- Excluded from the bounds and gap geometry: they're volumes, not
-- geometry a player stands on or walks into.
local VOLUME_TAGS: { [string]: boolean } = { PlayableBounds = true, KillZone = true }

local RARITIES: { [string]: boolean } = { Common = true, Uncommon = true, Rare = true }

-- Cap on paths quoted inline in one finding's message; the full list is
-- still in nodeIds for click-to-select.
local MAX_PATHS_IN_MESSAGE = 5

-- ===== small helpers =========================================================

local function hasTag(node: Node, tag: string): boolean
	return table.find(node.tags, tag) ~= nil
end

-- "a, b,,c " -> {"a","b","c"}. Whitespace around ids is forgiven because
-- it's invisible in Studio's attribute field; empty entries are dropped.
function MapCheck.splitCsv(raw: string): { string }
	local out = {}
	for part in string.gmatch(raw, "[^,]+") do
		local trimmed = string.match(part, "^%s*(.-)%s*$") :: string
		if trimmed ~= "" then
			table.insert(out, trimmed)
		end
	end
	return out
end

local function toSet(list: { string }): { [string]: boolean }
	local set = {}
	for _, v in list do
		set[v] = true
	end
	return set
end

local function sub(a: Vec3, b: Vec3): Vec3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function dot(a: Vec3, b: Vec3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

local function distance(a: Vec3, b: Vec3): number
	local d = sub(a, b)
	return math.sqrt(dot(d, d))
end

-- Tiny slack so a part sitting exactly on a bounds face isn't "outside"
-- through float error.
local EPSILON = 1e-3

function MapCheck.pointInBox(point: Vec3, box: Box): boolean
	local d = sub(point, box.center)
	return math.abs(dot(d, box.right)) <= box.size.x / 2 + EPSILON
		and math.abs(dot(d, box.up)) <= box.size.y / 2 + EPSILON
		and math.abs(dot(d, box.back)) <= box.size.z / 2 + EPSILON
end

-- Same test with the box's own vertical axis ignored: "is this XZ column
-- over the box's footprint". Assumes the bounds part is only yawed,
-- which is the only sane way to place a bounding volume.
local function columnInBox(x: number, z: number, box: Box): boolean
	local d = { x = x - box.center.x, y = 0, z = z - box.center.z }
	return math.abs(dot(d, box.right)) <= box.size.x / 2 + EPSILON
		and math.abs(dot(d, box.back)) <= box.size.z / 2 + EPSILON
end

function MapCheck.corners(box: Box): { Vec3 }
	local out = {}
	local hx, hy, hz = box.size.x / 2, box.size.y / 2, box.size.z / 2
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local ox, oy, oz = sx * hx, sy * hy, sz * hz
				table.insert(out, {
					x = box.center.x + box.right.x * ox + box.up.x * oy + box.back.x * oz,
					y = box.center.y + box.right.y * ox + box.up.y * oy + box.back.y * oz,
					z = box.center.z + box.right.z * ox + box.up.z * oy + box.back.z * oz,
				})
			end
		end
	end
	return out
end

type Aabb = { minX: number, maxX: number, minZ: number, maxZ: number }

-- World-space XZ extent of an oriented box. Conservative for rotated
-- parts (the AABB of a 45-degree plank is wider than the plank), which
-- can only hide a gap, never invent one.
local function aabbXZ(box: Box): Aabb
	local hx = math.abs(box.right.x) * box.size.x / 2
		+ math.abs(box.up.x) * box.size.y / 2
		+ math.abs(box.back.x) * box.size.z / 2
	local hz = math.abs(box.right.z) * box.size.x / 2
		+ math.abs(box.up.z) * box.size.y / 2
		+ math.abs(box.back.z) * box.size.z / 2
	return {
		minX = box.center.x - hx,
		maxX = box.center.x + hx,
		minZ = box.center.z - hz,
		maxZ = box.center.z + hz,
	}
end

-- ===== the checker ===========================================================

type Collector = {
	findings: { Finding },
	add: (
		self: Collector,
		severity: Severity,
		category: string,
		rule: string,
		message: string,
		nodes: { Node }?,
		positions: { Vec3 }?
	) -> (),
}

local function newCollector(): Collector
	local collector = { findings = {} } :: Collector
	function collector.add(self, severity, category, rule, message, nodes, positions)
		local ids = {}
		local paths = {}
		local list: { Node } = nodes or {}
		for i, node in list do
			table.insert(ids, node.id)
			if i <= MAX_PATHS_IN_MESSAGE then
				table.insert(paths, node.path)
			end
		end
		local text = message
		if #paths > 0 then
			local more = if #ids > #paths then string.format(" (+%d more)", #ids - #paths) else ""
			text = string.format("%s: %s%s", message, table.concat(paths, ", "), more)
		end
		table.insert(self.findings, {
			severity = severity,
			category = category,
			rule = rule,
			message = text,
			nodeIds = ids,
			positions = positions or {},
		})
	end
	return collector
end

type Tagged = { [string]: { Node } }

local function collectTagged(snapshot: MapSnapshot): Tagged
	local tagged: Tagged = {}
	for _, rule in TAG_RULES do
		tagged[rule.tag] = {}
	end
	for _, node in snapshot.nodes do
		for _, tag in node.tags do
			local list = tagged[tag]
			if list then
				table.insert(list, node)
			end
		end
	end
	return tagged
end

-- ----- Security --------------------------------------------------------------

-- Any script at all. Maps are assembled from third-party asset packs and
-- a script riding along inside one is the main backdoor route into a
-- Roblox game; map geometry has no legitimate reason to carry code (all
-- behaviour lives in src/, keyed off tags). No allow-list, deliberately.
local function checkSecurity(c: Collector, snapshot: MapSnapshot)
	local scripts = {}
	for _, node in snapshot.nodes do
		if node.isA.LuaSourceContainer then
			table.insert(scripts, node)
		end
	end
	if #scripts > 0 then
		c:add("error", "Security", "script-in-map", string.format("%d script(s) inside the map", #scripts), scripts)
	end
end

-- ----- Tags ------------------------------------------------------------------

local function checkTags(c: Collector, snapshot: MapSnapshot, tagged: Tagged)
	for _, rule in TAG_RULES do
		local list = tagged[rule.tag]
		local count = #list
		if count < rule.min or (rule.max ~= nil and count > rule.max) then
			local range = if rule.max == nil
				then string.format("at least %d", rule.min)
				elseif rule.min == rule.max then string.format("exactly %d", rule.min)
				else string.format("%d-%d", rule.min, rule.max :: number)
			c:add(
				"error",
				"Tags",
				"tag-count",
				string.format("%s: found %d, need %s", rule.tag, count, range),
				if count > 0 then list else nil
			)
		end

		local wrongClass = {}
		for _, node in list do
			if not node.isA[rule.class] then
				table.insert(wrongClass, node)
			end
		end
		if #wrongClass > 0 then
			c:add("error", "Tags", "tag-class", string.format("%s must be on a %s", rule.tag, rule.class), wrongClass)
		end
	end

	local multiTagged, lookalikes = {}, {}
	for _, node in snapshot.nodes do
		local contractCount = 0
		local lookalike = false
		for _, tag in node.tags do
			if CONTRACT_TAGS[tag] then
				contractCount += 1
			elseif CONTRACT_TAGS_LOWER[string.lower(tag)] then
				lookalike = true
			end
		end
		if contractCount > 1 then
			table.insert(multiTagged, node)
		end
		if lookalike then
			table.insert(lookalikes, node)
		end
	end
	if #multiTagged > 0 then
		c:add("warning", "Tags", "multiple-contract-tags", "Instances carrying more than one contract tag", multiTagged)
	end
	-- Builder's checklist step 5: a pack's own "spawnpoint" tag differs
	-- from ours only by case, so it's silently ignored at runtime.
	if #lookalikes > 0 then
		c:add(
			"warning",
			"Tags",
			"tag-case-mismatch",
			"Tags that match a contract tag except for case (tags are case-sensitive)",
			lookalikes
		)
	end
end

-- ----- Attributes ------------------------------------------------------------

type AttrKind = "string" | "integer" | "number"

-- Returns the value if it's present and the right type, else records the
-- node under the right failure bucket and returns nil.
local function readAttr(node: Node, name: string, kind: AttrKind, missing: { Node }, wrongType: { Node }): any
	local value = node.attributes[name]
	if value == nil then
		table.insert(missing, node)
		return nil
	end
	local ok = if kind == "string"
		then type(value) == "string"
		elseif kind == "integer" then type(value) == "number" and value == math.floor(value)
		else type(value) == "number"
	if not ok then
		table.insert(wrongType, node)
		return nil
	end
	return value
end

-- One attribute, checked across every instance of a tag: presence, type,
-- optional range, optional uniqueness. Empty strings count as missing -
-- Studio's attribute field makes "added but never filled in" easy.
local function checkAttribute(
	c: Collector,
	nodes: { Node },
	tag: string,
	name: string,
	kind: AttrKind,
	range: { min: number, max: number }?,
	unique: boolean
): { [Node]: any }
	local missing, wrongType, outOfRange = {}, {}, {}
	local values: { [Node]: any } = {}
	local seen: { [any]: { Node } } = {}

	for _, node in nodes do
		local value = readAttr(node, name, kind, missing, wrongType)
		if value == nil then
			continue
		end
		if kind == "string" and value == "" then
			table.insert(missing, node)
			continue
		end
		if range and (value < range.min or value > range.max) then
			table.insert(outOfRange, node)
			continue
		end
		values[node] = value
		if unique then
			seen[value] = seen[value] or {}
			table.insert(seen[value], node)
		end
	end

	local label = string.format("%s.%s", tag, name)
	if #missing > 0 then
		c:add("error", "Attributes", "attr-missing", label .. " is missing or empty", missing)
	end
	if #wrongType > 0 then
		c:add("error", "Attributes", "attr-type", string.format("%s must be a %s", label, kind), wrongType)
	end
	if #outOfRange > 0 and range then
		c:add(
			"error",
			"Attributes",
			"attr-range",
			string.format("%s must be %s-%s", label, tostring(range.min), tostring(range.max)),
			outOfRange
		)
	end
	for value, dupes in seen do
		if #dupes > 1 then
			c:add(
				"error",
				"Attributes",
				"attr-duplicate",
				string.format("%s %q is used more than once", label, tostring(value)),
				dupes
			)
		end
	end
	return values
end

local function checkTaskStations(c: Collector, stations: { Node }, ctx: Context)
	checkAttribute(c, stations, "TaskStation", "StationId", "string", nil, true)
	local accepted = checkAttribute(c, stations, "TaskStation", "AcceptedTaskIds", "string", nil, false)

	local registered = toSet(ctx.taskIds)
	local enabled = if ctx.mapDef then toSet(ctx.mapDef.enabledTaskIds) else nil
	local unknown: { [string]: { Node } } = {}
	local neverRuns, partlyDisabled = {}, {}

	for _, node in stations do
		local raw = accepted[node]
		if raw == nil then
			continue
		end
		local ids = MapCheck.splitCsv(raw)
		local runnable = 0
		for _, id in ids do
			if not registered[id] then
				unknown[id] = unknown[id] or {}
				table.insert(unknown[id], node)
			elseif enabled == nil or enabled[id] then
				runnable += 1
			end
		end
		if runnable == 0 then
			table.insert(neverRuns, node)
		elseif enabled and runnable < #ids then
			table.insert(partlyDisabled, node)
		end
	end

	-- A hard error, not a warning: TaskService can't roll a challenge on
	-- an unknown id and fails its boot assertion (map-kit-spec.md).
	for id, nodes in unknown do
		c:add(
			"error",
			"Config",
			"unknown-task-id",
			string.format("AcceptedTaskIds references %q, which isn't a registered task", id),
			nodes
		)
	end
	if #neverRuns > 0 then
		c:add(
			"error",
			"Config",
			"station-never-runs",
			"TaskStations with no registered task that this map enables",
			neverRuns
		)
	end
	if #partlyDisabled > 0 then
		c:add(
			"warning",
			"Config",
			"station-task-disabled",
			"TaskStations listing tasks this map's enabledTaskIds excludes",
			partlyDisabled
		)
	end
end

local function checkPowerUpSpawns(c: Collector, spawns: { Node }, ctx: Context)
	local rarityOf: { [string]: string } = {}
	local anyOfRarity: { [string]: boolean } = {}
	for _, def in ctx.powerUps do
		rarityOf[def.id] = def.rarity
		anyOfRarity[def.rarity] = true
	end

	local missing, wrongType, badEnum, noneOfRarity = {}, {}, {}, {}
	local unknown: { [string]: { Node } } = {}
	local rollsNothing, mismatched = {}, {}

	for _, node in spawns do
		local rarity = readAttr(node, "Rarity", "string", missing, wrongType)
		if rarity == nil then
			continue
		end
		-- An enum, not free text, precisely so a typo can't silently spawn
		-- nothing here (map-kit-spec.md).
		if not RARITIES[rarity] then
			table.insert(badEnum, node)
			continue
		end
		if not anyOfRarity[rarity] then
			table.insert(noneOfRarity, node)
		end

		-- Optional: absent and "" both mean "anything of this rarity".
		local allowedRaw = node.attributes.AllowedPowerUpIds
		if allowedRaw == nil or allowedRaw == "" then
			continue
		end
		if type(allowedRaw) ~= "string" then
			table.insert(wrongType, node)
			continue
		end
		-- The pool is AllowedPowerUpIds intersected with Rarity, so an id of
		-- the wrong rarity is dead weight and an all-wrong list is an empty
		-- pool: PowerUpService skips the pad with a warn() every rotation.
		local eligible, wrongRarity = 0, false
		for _, id in MapCheck.splitCsv(allowedRaw) do
			if rarityOf[id] == nil then
				unknown[id] = unknown[id] or {}
				table.insert(unknown[id], node)
			elseif rarityOf[id] == rarity then
				eligible += 1
			else
				wrongRarity = true
			end
		end
		if eligible == 0 then
			table.insert(rollsNothing, node)
		elseif wrongRarity then
			table.insert(mismatched, node)
		end
	end

	if #missing > 0 then
		c:add("error", "Attributes", "attr-missing", "PowerUpSpawn.Rarity is missing", missing)
	end
	if #wrongType > 0 then
		c:add(
			"error",
			"Attributes",
			"attr-type",
			"PowerUpSpawn.Rarity and AllowedPowerUpIds must be strings",
			wrongType
		)
	end
	if #badEnum > 0 then
		c:add("error", "Attributes", "attr-enum", "PowerUpSpawn.Rarity must be Common, Uncommon or Rare", badEnum)
	end
	if #noneOfRarity > 0 then
		c:add(
			"error",
			"Config",
			"rarity-has-no-powerups",
			"PowerUpSpawns whose Rarity has no registered power-up",
			noneOfRarity
		)
	end
	for id, nodes in unknown do
		c:add(
			"error",
			"Config",
			"unknown-powerup-id",
			string.format("AllowedPowerUpIds references %q, which isn't a registered power-up", id),
			nodes
		)
	end
	if #rollsNothing > 0 then
		c:add(
			"error",
			"Config",
			"spawn-rolls-nothing",
			"PowerUpSpawns whose AllowedPowerUpIds has no id matching the pad's Rarity",
			rollsNothing
		)
	end
	if #mismatched > 0 then
		c:add(
			"warning",
			"Config",
			"powerup-rarity-mismatch",
			"AllowedPowerUpIds lists power-ups of a different Rarity than the pad (never rolled)",
			mismatched
		)
	end
end

local function checkAttributes(c: Collector, tagged: Tagged, ctx: Context)
	checkAttribute(c, tagged.SpawnPoint, "SpawnPoint", "SpawnIndex", "integer", { min = 1, max = 6 }, true)
	checkTaskStations(c, tagged.TaskStation, ctx)
	checkPowerUpSpawns(c, tagged.PowerUpSpawn, ctx)
	checkAttribute(c, tagged.StudioPodiumSlot, "StudioPodiumSlot", "SlotIndex", "integer", { min = 1, max = 3 }, true)
	checkAttribute(c, tagged.StudioBoundary, "StudioBoundary", "Radius", "number", { min = 8, max = 30 }, false)
	-- NavNode's two attributes are checked with the graph, below.
end

-- ----- Config (MapDef cross-checks) -----------------------------------------

local function checkMapDef(c: Collector, snapshot: MapSnapshot, tagged: Tagged, ctx: Context)
	local def = ctx.mapDef
	if def == nil then
		-- A warning: building a map before its config file exists is the
		-- normal order of work. Config/Maps/init's own boot assertion is
		-- what stops an enabled def pointing at a map nobody built.
		c:add(
			"warning",
			"Config",
			"no-mapdef",
			string.format("No MapDef in Config/Maps for %q; config cross-checks skipped", snapshot.name)
		)
		return
	end
	-- map-kit-spec.md §2: taskStationCount is declared by hand because
	-- ConfigValidator can't see the .rbxl. This is the check that keeps
	-- the declared number honest.
	local actual = #tagged.TaskStation
	if def.taskStationCount ~= actual then
		c:add(
			"error",
			"Config",
			"station-count-mismatch",
			string.format(
				"MapDef %q declares taskStationCount = %d but the map has %d TaskStations",
				def.id,
				def.taskStationCount,
				actual
			)
		)
	end
end

-- ----- Navigation ------------------------------------------------------------

-- Nodes reachable from `start` along directed edges.
local function reachFrom(start: string, edges: { [string]: { string } }): { [string]: boolean }
	local seen = { [start] = true }
	local queue = { start }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		local targets: { string } = edges[current] or {}
		for _, nextId in targets do
			if not seen[nextId] then
				seen[nextId] = true
				table.insert(queue, nextId)
			end
		end
	end
	return seen
end

local function checkNavigation(c: Collector, tagged: Tagged, budget: Budget)
	local navNodes = tagged.NavNode
	local nodeIds = checkAttribute(c, navNodes, "NavNode", "NodeId", "string", nil, true)

	-- NodeId -> Node, first one wins on a duplicate (already reported).
	local byId: { [string]: Node } = {}
	local order: { string } = {}
	for _, node in navNodes do
		local id = nodeIds[node]
		if id and byId[id] == nil then
			byId[id] = node
			table.insert(order, id)
		end
	end

	local forward: { [string]: { string } } = {}
	local backward: { [string]: { string } } = {}
	local dangling: { [string]: { Node } } = {}
	local badType, selfLoops = {}, {}
	for _, id in order do
		forward[id] = forward[id] or {}
		backward[id] = backward[id] or {}
	end
	for _, id in order do
		local node = byId[id]
		local raw = node.attributes.ConnectedNodeIds
		if raw == nil then
			continue -- no edges; the orphan check below reports it
		end
		if type(raw) ~= "string" then
			table.insert(badType, node)
			continue
		end
		for _, target in MapCheck.splitCsv(raw) do
			if target == id then
				table.insert(selfLoops, node)
			elseif byId[target] == nil then
				dangling[target] = dangling[target] or {}
				table.insert(dangling[target], node)
			else
				table.insert(forward[id], target)
				table.insert(backward[target], id)
			end
		end
	end

	if #badType > 0 then
		c:add("error", "Attributes", "attr-type", "NavNode.ConnectedNodeIds must be a string", badType)
	end
	for target, nodes in dangling do
		c:add(
			"error",
			"Navigation",
			"nav-dangling-edge",
			string.format("ConnectedNodeIds references %q, which isn't any NavNode's NodeId", target),
			nodes
		)
	end
	if #selfLoops > 0 then
		c:add("warning", "Navigation", "nav-self-edge", "NavNodes listing themselves as connected", selfLoops)
	end

	local orphans = {}
	for _, id in order do
		if #forward[id] == 0 and #backward[id] == 0 then
			table.insert(orphans, byId[id])
		end
	end
	if #orphans > 0 and #order > 1 then
		c:add("error", "Navigation", "nav-orphan", "Orphaned NavNodes with no edges in or out", orphans)
	end

	-- NPCLogic.findNodePath walks edges as listed (directed BFS), so the
	-- real requirement is strong connectivity: every node can reach, and
	-- be reached from, every other. Checked against the first node in
	-- both directions; orphans are left out so they aren't reported twice.
	if #order > 1 then
		local root = order[1]
		local out = reachFrom(root, forward)
		local back = reachFrom(root, backward)
		local cantReach, cantReturn = {}, {}
		for _, id in order do
			local node = byId[id]
			if table.find(orphans, node) then
				continue
			end
			if not out[id] then
				table.insert(cantReach, node)
			elseif not back[id] then
				table.insert(cantReturn, node)
			end
		end
		if #cantReach > 0 then
			c:add(
				"error",
				"Navigation",
				"nav-disconnected",
				string.format("NavNodes an NPC can't reach from %q along ConnectedNodeIds", root),
				cantReach
			)
		end
		if #cantReturn > 0 then
			c:add(
				"error",
				"Navigation",
				"nav-one-way",
				string.format("NavNodes an NPC can reach but never leave back towards %q (one-way edges)", root),
				cantReturn
			)
		end
	end

	local stations = #tagged.TaskStation
	if stations > 0 and #navNodes < stations * budget.minNavNodesPerStation then
		c:add(
			"warning",
			"Navigation",
			"nav-sparse",
			string.format(
				"%d NavNodes for %d TaskStations; map-kit-spec.md suggests at least %d",
				#navNodes,
				stations,
				math.ceil(stations * budget.minNavNodesPerStation)
			)
		)
	end

	local farFromNav = {}
	for _, tag in { "TaskStation", "PowerUpSpawn" } do
		for _, target in tagged[tag] do
			local box = target.box
			if box == nil then
				continue
			end
			local near = false
			for _, nav in navNodes do
				if nav.position and distance(nav.position, box.center) <= budget.navProximityStuds then
					near = true
					break
				end
			end
			if not near then
				table.insert(farFromNav, target)
			end
		end
	end
	if #farFromNav > 0 and #navNodes > 0 then
		c:add(
			"warning",
			"Navigation",
			"nav-coverage",
			string.format("Stations/pads with no NavNode within %d studs", budget.navProximityStuds),
			farFromNav
		)
	end
end

-- ----- Reachability ----------------------------------------------------------

local function checkReachability(c: Collector, snapshot: MapSnapshot, ctx: Context)
	local unreachable = ctx.unreachableIds
	if unreachable == nil then
		c:add(
			"info",
			"Reachability",
			"reachability-skipped",
			"Spawn-to-station reachability not checked (needs PathfindingService: run the Studio plugin)"
		)
		return
	end
	if #unreachable > 0 then
		local nodes = {}
		for _, id in unreachable do
			local node = snapshot.nodes[id]
			if node then
				table.insert(nodes, node)
			end
		end
		c:add(
			"error",
			"Reachability",
			"unreachable",
			"TaskStations/PowerUpSpawns with no walkable path from at least one SpawnPoint",
			nodes
		)
	end
end

-- ----- Bounds ----------------------------------------------------------------

local function isVolume(node: Node): boolean
	for _, tag in node.tags do
		if VOLUME_TAGS[tag] then
			return true
		end
	end
	return false
end

local function checkOutOfBounds(c: Collector, snapshot: MapSnapshot, bounds: { Box })
	local outsideSolid, outsideDecor, straddling = {}, {}, {}
	for _, node in snapshot.nodes do
		local box = node.box
		if box == nil or isVolume(node) then
			continue
		end
		local centreIn = false
		for _, b in bounds do
			if MapCheck.pointInBox(box.center, b) then
				centreIn = true
				break
			end
		end
		if not centreIn then
			table.insert(if node.canCollide then outsideSolid else outsideDecor, node)
			continue
		end
		if not node.canCollide then
			continue
		end
		for _, corner in MapCheck.corners(box) do
			local cornerIn = false
			for _, b in bounds do
				if MapCheck.pointInBox(corner, b) then
					cornerIn = true
					break
				end
			end
			if not cornerIn then
				table.insert(straddling, node)
				break
			end
		end
	end
	-- Solid geometry outside bounds is somewhere a player can stand that
	-- the server's out-of-bounds check treats as an exploit - an honest
	-- player gets flagged. Decor outside is just backdrop.
	if #outsideSolid > 0 then
		c:add("error", "Bounds", "solid-outside-bounds", "Collidable parts outside every PlayableBounds", outsideSolid)
	end
	if #outsideDecor > 0 then
		c:add(
			"warning",
			"Bounds",
			"decor-outside-bounds",
			"Non-collidable parts outside every PlayableBounds",
			outsideDecor
		)
	end
	if #straddling > 0 then
		c:add(
			"warning",
			"Bounds",
			"solid-straddles-bounds",
			"Collidable parts that stick out past PlayableBounds",
			straddling
		)
	end
end

-- Walks a grid over each PlayableBounds footprint and asks, per XZ
-- column: is there any collidable geometry under here, and if not, is
-- there a KillZone? A column with neither is a hole a player falls
-- through into nothing. Column-based on purpose - a hole in an upper
-- floor above a solid lower floor is a drop, not a gap. The known blind
-- spot is a ceiling over a hole, which reads as covered.
local function checkGaps(c: Collector, snapshot: MapSnapshot, bounds: { Box }, budget: Budget)
	local step = budget.gapGridStuds
	-- Spatial hash on XZ so each sample only tests nearby parts.
	local CELL = 32
	type Entry = { aabb: Aabb, kill: boolean }
	local cells: { [string]: { Entry } } = {}
	local function key(ix: number, iz: number): string
		return ix .. ":" .. iz
	end
	for _, node in snapshot.nodes do
		local box = node.box
		if box == nil or hasTag(node, "PlayableBounds") then
			continue
		end
		local kill = hasTag(node, "KillZone")
		if not kill and not node.canCollide then
			continue
		end
		local a = aabbXZ(box)
		local entry: Entry = { aabb = a, kill = kill }
		for ix = math.floor(a.minX / CELL), math.floor(a.maxX / CELL) do
			for iz = math.floor(a.minZ / CELL), math.floor(a.maxZ / CELL) do
				local k = key(ix, iz)
				cells[k] = cells[k] or {}
				table.insert(cells[k], entry)
			end
		end
	end

	local gapCells: { [string]: Vec3 } = {}
	for _, b in bounds do
		local a = aabbXZ(b)
		local y = b.center.y
		for gx = math.floor(a.minX / step), math.ceil(a.maxX / step) do
			for gz = math.floor(a.minZ / step), math.ceil(a.maxZ / step) do
				local x, z = gx * step, gz * step
				if not columnInBox(x, z, b) then
					continue
				end
				local covered = false
				local nearby: { Entry } = cells[key(math.floor(x / CELL), math.floor(z / CELL))] or {}
				for _, entry in nearby do
					local e = entry.aabb
					if x >= e.minX and x <= e.maxX and z >= e.minZ and z <= e.maxZ then
						covered = true
						break
					end
				end
				if not covered then
					gapCells[key(gx, gz)] = { x = x, y = y, z = z }
				end
			end
		end
	end

	-- Flood-fill adjacent gap cells into holes so a 40x40 hole is one
	-- entry, not a hundred.
	local holes: { Vec3 } = {}
	local visited: { [string]: boolean } = {}
	for k, _ in gapCells do
		if visited[k] then
			continue
		end
		visited[k] = true
		local stack = { k }
		local sx, sy, sz, n = 0, 0, 0, 0
		while #stack > 0 do
			local current = table.remove(stack) :: string
			local p = gapCells[current]
			sx, sy, sz, n = sx + p.x, sy + p.y, sz + p.z, n + 1
			local gx = math.round(p.x / step)
			local gz = math.round(p.z / step)
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local nk = key(gx + d[1], gz + d[2])
				if gapCells[nk] and not visited[nk] then
					visited[nk] = true
					table.insert(stack, nk)
				end
			end
		end
		table.insert(holes, { x = sx / n, y = sy / n, z = sz / n })
	end

	if #holes > 0 then
		table.sort(holes, function(p, q)
			return if p.x ~= q.x then p.x < q.x else p.z < q.z
		end)
		local where = {}
		for i = 1, math.min(#holes, MAX_PATHS_IN_MESSAGE) do
			table.insert(where, string.format("(%d, %d)", math.round(holes[i].x), math.round(holes[i].z)))
		end
		c:add(
			"error",
			"Bounds",
			"gap-without-killzone",
			string.format(
				"%d hole(s) with no floor and no KillZone under them, centred near X,Z %s%s",
				#holes,
				table.concat(where, ", "),
				if #holes > #where then " ..." else ""
			),
			nil,
			holes
		)
	end
end

local function checkBounds(c: Collector, snapshot: MapSnapshot, tagged: Tagged, budget: Budget)
	local bounds = {}
	for _, node in tagged.PlayableBounds do
		if node.box then
			table.insert(bounds, node.box)
		end
	end
	if #bounds == 0 then
		return -- tag-count already failed the map; nothing to measure against
	end
	checkOutOfBounds(c, snapshot, bounds)
	checkGaps(c, snapshot, bounds, budget)
end

-- ----- Performance -----------------------------------------------------------

local function checkPerformance(c: Collector, snapshot: MapSnapshot, budget: Budget)
	local parts, meshParts = 0, 0
	local meshes, textures = {}, {}
	local meshCount, textureCount = 0, 0
	local unanchored, stray, decorQuery, preciseMesh, softMesh = {}, {}, {}, {}, {}

	for _, node in snapshot.nodes do
		if node.meshId and node.meshId ~= "" and not meshes[node.meshId] then
			meshes[node.meshId] = true
			meshCount += 1
		end
		for _, tex in node.textureIds do
			if tex ~= "" and not textures[tex] then
				textures[tex] = true
				textureCount += 1
			end
		end
		if not node.isA.BasePart then
			continue
		end
		parts += 1
		if node.isA.MeshPart then
			meshParts += 1
		end

		local canTouchAllowed = false
		local tagged = false
		for _, tag in node.tags do
			tagged = tagged or CONTRACT_TAGS[tag] == true
			canTouchAllowed = canTouchAllowed or CAN_TOUCH_TAGS[tag] == true
		end
		if node.anchored == false then
			table.insert(unanchored, node)
		end
		if node.canTouch and not canTouchAllowed then
			table.insert(stray, node)
		end
		-- CanQuery is only flagged on decor (non-collidable, untagged):
		-- walls need it for camera and raycast queries.
		if node.canQuery and not node.canCollide and not tagged then
			table.insert(decorQuery, node)
		end
		if node.canCollide and node.collisionFidelity then
			if node.collisionFidelity == "PreciseConvexDecomposition" then
				table.insert(preciseMesh, node)
			elseif node.collisionFidelity ~= "Box" then
				table.insert(softMesh, node)
			end
		end
	end

	local function overBudget(rule: string, label: string, count: number, max: number)
		if count > max then
			c:add("error", "Performance", rule, string.format("%s: %d, budget %d", label, count, max))
		end
	end
	overBudget("instance-budget", "Instance count", #snapshot.nodes, budget.maxInstances)
	overBudget("mesh-budget", "Unique meshes", meshCount, budget.maxUniqueMeshes)
	overBudget("texture-budget", "Unique textures", textureCount, budget.maxUniqueTextures)

	-- perf-budget.md has no whole-map part budget (its part figure is per
	-- camera frustum, which can't be measured statically), so the totals
	-- are reported as numbers only.
	c:add(
		"info",
		"Performance",
		"totals",
		string.format(
			"%d instances, %d parts (%d MeshParts), %d unique meshes, %d unique textures",
			#snapshot.nodes,
			parts,
			meshParts,
			meshCount,
			textureCount
		)
	)

	if #unanchored > 0 then
		c:add(
			"warning",
			"Performance",
			"unanchored",
			"Unanchored parts (anchor, or confirm they must move)",
			unanchored
		)
	end
	if #stray > 0 then
		c:add(
			"warning",
			"Performance",
			"stray-can-touch",
			"CanTouch on parts that aren't a KillZone or TaskStation",
			stray
		)
	end
	if #decorQuery > 0 then
		c:add("warning", "Performance", "decor-can-query", "CanQuery on non-collidable decor", decorQuery)
	end
	if #preciseMesh > 0 then
		c:add(
			"warning",
			"Performance",
			"precise-collision",
			"Collidable meshes on PreciseConvexDecomposition (the most expensive fidelity)",
			preciseMesh
		)
	end
	if #softMesh > 0 then
		c:add("warning", "Performance", "collision-not-box", "Collidable meshes not on CollisionFidelity Box", softMesh)
	end
end

-- ===== entry points ==========================================================

function MapCheck.run(snapshot: MapSnapshot, ctx: Context): Report
	local budget = ctx.budget or MapCheck.DEFAULT_BUDGET
	local c = newCollector()
	local tagged = collectTagged(snapshot)

	checkSecurity(c, snapshot)
	checkTags(c, snapshot, tagged)
	checkAttributes(c, tagged, ctx)
	checkMapDef(c, snapshot, tagged, ctx)
	checkReachability(c, snapshot, ctx)
	checkNavigation(c, tagged, budget)
	checkBounds(c, snapshot, tagged, budget)
	checkPerformance(c, snapshot, budget)

	-- Stable order: category, then severity, then rule, then message -
	-- the plain `unknown` maps above iterate in hash order, and a report
	-- whose lines shuffle between runs is useless to diff in CI.
	local categoryRank: { [string]: number } = {}
	for i, name in MapCheck.CATEGORIES do
		categoryRank[name] = i
	end
	local severityRank = { error = 1, warning = 2, info = 3 }
	table.sort(c.findings, function(a, b)
		if a.category ~= b.category then
			return categoryRank[a.category] < categoryRank[b.category]
		elseif a.severity ~= b.severity then
			return severityRank[a.severity] < severityRank[b.severity]
		elseif a.rule ~= b.rule then
			return a.rule < b.rule
		end
		return a.message < b.message
	end)

	local errors, warnings = 0, 0
	for _, f in c.findings do
		if f.severity == "error" then
			errors += 1
		elseif f.severity == "warning" then
			warnings += 1
		end
	end
	local passed = errors == 0
	return {
		mapName = snapshot.name,
		findings = c.findings,
		errorCount = errors,
		warningCount = warnings,
		passed = passed,
		summary = string.format(
			"%s %s - %d error(s), %d warning(s)",
			if passed then "PASS" else "FAIL",
			snapshot.name,
			errors,
			warnings
		),
	}
end

-- Plain-text rendering for the Output window and CI logs. The plugin's
-- widget renders the same Report as a clickable list instead.
function MapCheck.formatText(report: Report): string
	local lines = { report.summary }
	local lastCategory = ""
	for _, f in report.findings do
		if f.category ~= lastCategory then
			table.insert(lines, string.format("  [%s]", f.category))
			lastCategory = f.category
		end
		table.insert(lines, string.format("    %-7s %s (%s)", string.upper(f.severity), f.message, f.rule))
	end
	return table.concat(lines, "\n")
end

return MapCheck
