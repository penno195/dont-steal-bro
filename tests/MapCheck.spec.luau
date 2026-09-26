--!strict
-- Covers plugin/MapValidator/MapCheck.luau (P7-1): the map validator's
-- pure rule engine. Every case starts from one hand-built snapshot that
-- satisfies the whole map-kit-spec.md contract with zero findings above
-- "info", then breaks exactly one thing - so each test proves both that
-- the rule fires and that the baseline isn't already tripping it.
-- Snapshot.luau (the Instance reader) is exercised end to end by
-- scripts/validate-maps.luau against a real place file instead.

local TestRunner = require("./TestRunner")
local MapCheck = require("../plugin/MapValidator/MapCheck")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

type Node = MapCheck.Node
type Vec3 = MapCheck.Vec3

-- ===== fixture ===============================================================

local function v(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

local function box(center: Vec3, size: Vec3): MapCheck.Box
	return { center = center, right = v(1, 0, 0), up = v(0, 1, 0), back = v(0, 0, 1), size = size }
end

type PartOpts = {
	tags: { string }?,
	attributes: { [string]: any }?,
	collide: boolean?,
	touch: boolean?,
	anchored: boolean?,
	fidelity: string?,
	className: string?,
}

type Fixture = {
	nodes: { Node },
	part: (self: Fixture, name: string, center: Vec3, size: Vec3, opts: PartOpts?) -> Node,
	attachment: (self: Fixture, name: string, pos: Vec3, tags: { string }, attributes: { [string]: any }) -> Node,
	other: (self: Fixture, name: string, className: string, isA: { [string]: boolean }) -> Node,
	snapshot: (self: Fixture) -> MapCheck.MapSnapshot,
	find: (self: Fixture, name: string) -> Node,
}

local function newFixture(): Fixture
	local f = { nodes = {} } :: Fixture

	local function push(node: Node): Node
		node.id = #f.nodes + 1
		table.insert(f.nodes, node)
		return node
	end

	function f.part(_self, name, center, size, opts)
		local o: PartOpts = opts or {}
		local isA: { [string]: boolean } = { BasePart = true }
		if o.fidelity then
			isA.TriangleMeshPart = true
			isA.MeshPart = true
		end
		return push({
			id = 0,
			path = "Test." .. name,
			className = o.className or (if o.fidelity then "MeshPart" else "Part"),
			isA = isA,
			tags = o.tags or {},
			attributes = o.attributes or {},
			box = box(center, size),
			anchored = if o.anchored == nil then true else o.anchored,
			canCollide = o.collide == true,
			canTouch = o.touch == true,
			canQuery = o.collide == true,
			collisionFidelity = o.fidelity,
			textureIds = {},
		})
	end

	function f.attachment(_self, name, pos, tags, attributes)
		return push({
			id = 0,
			path = "Test." .. name,
			className = "Attachment",
			isA = { Attachment = true },
			tags = tags,
			attributes = attributes,
			position = pos,
			textureIds = {},
		})
	end

	function f.other(_self, name, className, isA)
		return push({
			id = 0,
			path = "Test." .. name,
			className = className,
			isA = isA,
			tags = {},
			attributes = {},
			textureIds = {},
		})
	end

	function f.snapshot(self)
		return { name = "Test", nodes = self.nodes }
	end

	function f.find(self, name)
		for _, node in self.nodes do
			if node.path == "Test." .. name then
				return node
			end
		end
		error("no fixture node " .. name)
	end

	return f
end

-- A 200x200 floor inside a 210x210 PlayableBounds, a world-floor
-- KillZone under all of it, and every contract tag at a legal count.
-- Floor is split into two slabs so tests can open a hole between them.
local function validMap(): Fixture
	local f = newFixture()
	f:part("FloorWest", v(-50, 0, 0), v(100, 1, 200), { collide = true })
	f:part("FloorEast", v(50, 0, 0), v(100, 1, 200), { collide = true })
	f:part("Bounds", v(0, 20, 0), v(210, 60, 210), { tags = { "PlayableBounds" } })
	f:part("KillFloor", v(0, -30, 0), v(240, 2, 240), { tags = { "KillZone" }, touch = true })

	for i = 1, 6 do
		f:part("Spawn" .. i, v(i * 5, 2, 0), v(2, 1, 2), { tags = { "SpawnPoint" }, attributes = { SpawnIndex = i } })
	end
	for i = 1, 12 do
		f:part("Station" .. i, v(-66 + i * 10, 2, 20), v(2, 2, 2), {
			tags = { "TaskStation" },
			touch = true,
			attributes = { StationId = "s" .. i, AcceptedTaskIds = "pressure-valve" },
		})
	end
	for i = 1, 8 do
		f:part("Pad" .. i, v(-45 + i * 10, 1, -20), v(2, 1, 2), {
			tags = { "PowerUpSpawn" },
			attributes = { Rarity = "Common" },
		})
	end

	-- 18 nodes on a line, each linked both ways to its neighbours.
	local count = 18
	for i = 1, count do
		local links = {}
		if i > 1 then
			table.insert(links, "n" .. (i - 1))
		end
		if i < count then
			table.insert(links, "n" .. (i + 1))
		end
		f:attachment(
			"Nav" .. i,
			v(-90 + i * 10, 1, 0),
			{ "NavNode" },
			{ NodeId = "n" .. i, ConnectedNodeIds = table.concat(links, ",") }
		)
	end

	f:part("Anchor", v(0, 1, 60), v(4, 1, 4), { tags = { "StudioAnchor" } })
	for i = 1, 3 do
		f:part("Slot" .. i, v(-10 + i * 5, 1, 60), v(3, 1, 3), {
			tags = { "StudioPodiumSlot" },
			attributes = { SlotIndex = i },
		})
	end
	f:part("Boundary", v(0, 1, 60), v(1, 1, 1), { tags = { "StudioBoundary" }, attributes = { Radius = 12 } })
	return f
end

local function context(): MapCheck.Context
	return {
		taskIds = { "pressure-valve", "vent-purge" },
		powerUps = { { id = "freeze", rarity = "Common" }, { id = "blind", rarity = "Rare" } },
		mapDef = { id = "Test", enabledTaskIds = { "pressure-valve" }, taskStationCount = 12 },
		unreachableIds = {},
	}
end

local function run(f: Fixture, ctx: MapCheck.Context?): MapCheck.Report
	return MapCheck.run(f:snapshot(), ctx or context())
end

local function finding(report: MapCheck.Report, rule: string): MapCheck.Finding?
	for _, f in report.findings do
		if f.rule == rule then
			return f
		end
	end
	return nil
end

local function expectRule(report: MapCheck.Report, rule: string, severity: MapCheck.Severity)
	local f = finding(report, rule)
	if f == nil then
		error(string.format("expected rule %s, got: %s", rule, MapCheck.formatText(report)))
	end
	expect((f :: MapCheck.Finding).severity):toBe(severity)
end

-- ===== tests =================================================================

describe("MapCheck baseline", function()
	it("passes a contract-conformant map with no errors or warnings", function()
		local report = run(validMap())
		if report.errorCount + report.warningCount > 0 then
			error(MapCheck.formatText(report))
		end
		expect(report.passed):toBe(true)
		expect(string.sub(report.summary, 1, 4)):toBe("PASS")
	end)

	it("splits comma-separated ids, trimming blanks", function()
		local ids = MapCheck.splitCsv(" a, b,,c ,")
		expect(#ids):toBe(3)
		expect(ids[1]):toBe("a")
		expect(ids[3]):toBe("c")
	end)
end)

describe("MapCheck security", function()
	it("fails on any script inside the map and points at it", function()
		local f = validMap()
		local bad = f:other("Backdoor", "Script", { LuaSourceContainer = true })
		local report = run(f)
		expectRule(report, "script-in-map", "error")
		expect((finding(report, "script-in-map") :: MapCheck.Finding).nodeIds[1]):toBe(bad.id)
		expect(report.passed):toBe(false)
		-- Security sorts to the top of the report.
		expect(report.findings[1].category):toBe("Security")
	end)
end)

describe("MapCheck tags", function()
	it("fails when a tag's count is out of range", function()
		local f = validMap()
		table.remove(f:find("Spawn6").tags)
		expectRule(run(f), "tag-count", "error")
	end)

	it("fails a tag on the wrong class", function()
		local f = validMap()
		f:part("BadNav", v(0, 1, 0), v(1, 1, 1), { tags = { "NavNode" }, attributes = { NodeId = "x" } })
		expectRule(run(f), "tag-class", "error")
	end)

	it("warns on a tag that only differs from the contract by case", function()
		local f = validMap()
		f:part("PackSpawn", v(0, 1, 0), v(1, 1, 1), { tags = { "spawnpoint" } })
		local report = run(f)
		expectRule(report, "tag-case-mismatch", "warning")
		expect(report.passed):toBe(true)
	end)
end)

describe("MapCheck attributes", function()
	it("fails a duplicate SpawnIndex", function()
		local f = validMap()
		f:find("Spawn6").attributes.SpawnIndex = 1
		expectRule(run(f), "attr-duplicate", "error")
	end)

	it("fails a non-integer or out-of-range index", function()
		local f = validMap()
		f:find("Spawn5").attributes.SpawnIndex = 2.5
		f:find("Spawn6").attributes.SpawnIndex = 7
		local report = run(f)
		expectRule(report, "attr-type", "error")
		expectRule(report, "attr-range", "error")
	end)

	it("treats an empty string attribute as missing", function()
		local f = validMap()
		f:find("Station1").attributes.StationId = ""
		expectRule(run(f), "attr-missing", "error")
	end)

	it("fails a Rarity outside the enum", function()
		local f = validMap()
		f:find("Pad1").attributes.Rarity = "common"
		expectRule(run(f), "attr-enum", "error")
	end)

	it("fails a StudioBoundary Radius outside 8-30", function()
		local f = validMap()
		f:find("Boundary").attributes.Radius = 40
		expectRule(run(f), "attr-range", "error")
	end)
end)

describe("MapCheck config cross-checks", function()
	it("fails a station naming an unregistered task", function()
		local f = validMap()
		f:find("Station1").attributes.AcceptedTaskIds = "pressure-valve,no-such-task"
		expectRule(run(f), "unknown-task-id", "error")
	end)

	it("fails a station whose only task the map disables, warns on a partial one", function()
		local f = validMap()
		f:find("Station1").attributes.AcceptedTaskIds = "vent-purge"
		f:find("Station2").attributes.AcceptedTaskIds = "pressure-valve, vent-purge"
		local report = run(f)
		expectRule(report, "station-never-runs", "error")
		expectRule(report, "station-task-disabled", "warning")
	end)

	it("fails a pad whose AllowedPowerUpIds can't match its Rarity", function()
		local f = validMap()
		f:find("Pad1").attributes.AllowedPowerUpIds = "blind"
		f:find("Pad2").attributes.AllowedPowerUpIds = "freeze,blind"
		f:find("Pad3").attributes.AllowedPowerUpIds = "no-such-item"
		local report = run(f)
		expectRule(report, "spawn-rolls-nothing", "error")
		expectRule(report, "powerup-rarity-mismatch", "warning")
		expectRule(report, "unknown-powerup-id", "error")
	end)

	it("fails a pad whose Rarity has no registered power-up", function()
		local f = validMap()
		f:find("Pad1").attributes.Rarity = "Uncommon"
		expectRule(run(f), "rarity-has-no-powerups", "error")
	end)

	it("fails when the declared taskStationCount drifts from the real count", function()
		local ctx = context()
		local def = ctx.mapDef :: MapCheck.MapDefLite
		def.taskStationCount = 14
		expectRule(run(validMap(), ctx), "station-count-mismatch", "error")
	end)

	it("only warns when the map has no MapDef yet", function()
		local ctx = context()
		ctx.mapDef = nil
		local report = run(validMap(), ctx)
		expectRule(report, "no-mapdef", "warning")
		expect(report.passed):toBe(true)
	end)
end)

describe("MapCheck reachability", function()
	it("marks the check skipped, not passed, when no pathfinding result is given", function()
		local ctx = context()
		ctx.unreachableIds = nil
		local report = run(validMap(), ctx)
		expectRule(report, "reachability-skipped", "info")
		expect(report.passed):toBe(true)
	end)

	it("fails on each unreachable station", function()
		local f = validMap()
		local ctx = context()
		ctx.unreachableIds = { f:find("Station3").id }
		expectRule(run(f, ctx), "unreachable", "error")
	end)

	it("probes every spawn against every station and power-up pad", function()
		local starts, targets = MapCheck.reachabilityProbes(validMap():snapshot())
		expect(#starts):toBe(6)
		expect(#targets):toBe(12 + 8)
	end)

	it("probes a trigger at its centre and a solid pad above its top face", function()
		local f = newFixture()
		local trigger = f:part("Trigger", v(0, 2, 0), v(4, 4, 4))
		local pad = f:part("Pad", v(0, 1, 0), v(4, 2, 4), { collide = true })
		local tilted = f:part("Tilted", v(0, 1, 0), v(2, 6, 2), { collide = true })
		-- Laid on its side: its 6-stud axis now points along world X,
		-- so its world-Y half-extent is 1, not 3.
		local b = tilted.box :: MapCheck.Box
		b.right, b.up = v(0, -1, 0), v(1, 0, 0)

		expect((MapCheck.probePoint(trigger) :: Vec3).y):toBeCloseTo(2)
		expect((MapCheck.probePoint(pad) :: Vec3).y):toBeCloseTo(1 + 1 + 3)
		expect((MapCheck.probePoint(tilted) :: Vec3).y):toBeCloseTo(1 + 1 + 3)
	end)
end)

describe("MapCheck navigation", function()
	it("fails an edge to a NodeId that doesn't exist", function()
		local f = validMap()
		f:find("Nav1").attributes.ConnectedNodeIds = "n2,ghost"
		expectRule(run(f), "nav-dangling-edge", "error")
	end)

	it("fails an orphaned node", function()
		local f = validMap()
		f:attachment("Lonely", v(0, 1, 5), { "NavNode" }, { NodeId = "lonely" })
		expectRule(run(f), "nav-orphan", "error")
	end)

	it("fails a graph split into two components", function()
		local f = validMap()
		-- Cut the line between n9 and n10 in both directions.
		f:find("Nav9").attributes.ConnectedNodeIds = "n8"
		f:find("Nav10").attributes.ConnectedNodeIds = "n11"
		expectRule(run(f), "nav-disconnected", "error")
	end)

	it("fails a one-way edge that strands NPCs past it", function()
		local f = validMap()
		-- n10 can still be entered from n9 but no longer leads back.
		f:find("Nav10").attributes.ConnectedNodeIds = "n11"
		expectRule(run(f), "nav-one-way", "error")
	end)

	it("warns on a station far from every NavNode", function()
		local f = validMap()
		f:part("FarStation", v(95, 2, 95), v(2, 2, 2), {
			tags = { "TaskStation" },
			touch = true,
			attributes = { StationId = "far", AcceptedTaskIds = "pressure-valve" },
		})
		local ctx = context();
		(ctx.mapDef :: MapCheck.MapDefLite).taskStationCount = 13
		expectRule(run(f, ctx), "nav-coverage", "warning")
	end)
end)

describe("MapCheck bounds", function()
	it("fails collidable geometry outside every PlayableBounds, warns on decor", function()
		local f = validMap()
		f:part("SecretLedge", v(300, 5, 0), v(10, 1, 10), { collide = true })
		f:part("Skybox", v(0, 5, 300), v(10, 1, 10))
		local report = run(f)
		expectRule(report, "solid-outside-bounds", "error")
		expectRule(report, "decor-outside-bounds", "warning")
	end)

	it("fails a hole in the floor with no KillZone beneath it", function()
		local f = validMap()
		f:find("FloorEast").box = box(v(70, 0, 0), v(60, 1, 200)) -- opens x = 0..40
		f:find("KillFloor").box = box(v(-80, -30, 0), v(40, 2, 240)) -- only under the west edge
		local gap = finding(run(f), "gap-without-killzone")
		expect(gap ~= nil):toBe(true)
		expect(#(gap :: MapCheck.Finding).positions > 0):toBe(true)
	end)

	it("accepts the same hole when a KillZone sits under it", function()
		local f = validMap()
		f:find("FloorEast").box = box(v(70, 0, 0), v(60, 1, 200))
		expect(finding(run(f), "gap-without-killzone")):toBe(nil)
	end)
end)

describe("MapCheck performance", function()
	it("fails a map over the instance budget", function()
		local ctx = context()
		local budget = table.clone(MapCheck.DEFAULT_BUDGET)
		budget.maxInstances = 10
		ctx.budget = budget
		expectRule(run(validMap(), ctx), "instance-budget", "error")
	end)

	it("warns on unanchored parts, stray CanTouch and precise collision", function()
		local f = validMap()
		f:part("Crate", v(0, 2, -40), v(2, 2, 2), { collide = true, anchored = false })
		f:part("Poster", v(0, 4, -40), v(2, 2, 0.2), { touch = true })
		f:part("Rock", v(10, 2, -40), v(4, 4, 4), { collide = true, fidelity = "PreciseConvexDecomposition" })
		f:part("Pipe", v(20, 2, -40), v(4, 4, 4), { collide = true, fidelity = "Hull" })
		local report = run(f)
		expectRule(report, "unanchored", "warning")
		expectRule(report, "stray-can-touch", "warning")
		expectRule(report, "precise-collision", "warning")
		expectRule(report, "collision-not-box", "warning")
		expect(report.passed):toBe(true)
	end)

	it("exempts thin wall/arch-like meshes from the Box rules", function()
		local f = validMap()
		-- The hub hotel archway: Box filled the opening.
		f:part("Wall", v(10, 7, -40), v(20.8, 12.9, 0.6), { collide = true, fidelity = "PreciseConvexDecomposition" })
		f:part("DoorFrame", v(20, 2, -40), v(4, 4, 4), { collide = true, fidelity = "Default" })
		local report = run(f)
		expect(finding(report, "precise-collision")):toBe(nil)
		expect(finding(report, "collision-not-box")):toBe(nil)
		expectRule(report, "wall-precise-collision", "info")
	end)

	it("counts unique meshes and textures once each", function()
		local f = validMap()
		local a = f:part("MeshA", v(0, 2, -50), v(2, 2, 2), { collide = true, fidelity = "Box" })
		local b = f:part("MeshB", v(5, 2, -50), v(2, 2, 2), { collide = true, fidelity = "Box" })
		a.meshId, b.meshId = "rbxassetid://1", "rbxassetid://1"
		a.textureIds, b.textureIds = { "rbxassetid://2" }, { "rbxassetid://2", "rbxassetid://3" }
		local totals = finding(run(f), "totals") :: MapCheck.Finding
		expect(string.find(totals.message, "1 unique meshes, 2 unique textures", 1, true) ~= nil):toBe(true)
	end)
end)
