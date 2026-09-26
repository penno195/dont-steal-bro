--!strict
-- Asset pack sanitiser (P7-2). Paste this whole file into Studio's
-- Command Bar with the pack's model(s) selected, and run it.
--
-- WHY THIS EXISTS. A Script hidden inside a downloaded asset pack is the
-- single most common way a Roblox game gets backdoored: one
-- `require(<asset id>)` buried in a lamp post and a stranger can run
-- server code in a game with a public leaderboard (Ground Rule 1). This
-- script is the gate every third-party model passes through before it
-- goes anywhere near a map - map-kit-spec.md §3 steps 1-5, automated.
--
-- DRY RUN BY DEFAULT. With DRY_RUN = true (as shipped) it changes
-- nothing and prints exactly what it WOULD do. Read that report, then
-- flip DRY_RUN to false and run it again. Both modes build the same plan
-- through the same code - the dry run isn't a separate approximation,
-- it's the real run with the last step skipped.
--
-- WHAT IT TOUCHES, AND NOTHING ELSE:
--   1. Destroys every LuaSourceContainer (Script, LocalScript,
--      ModuleScript) and logs each one's full path.
--   2. Anchored = true on every part.
--   3. CanCollide / CanTouch / CanQuery set by role (see ROLES below).
--   4. CollisionFidelity = Box on chunky collidable meshes and unions.
--      Thin wall/arch-like ones (see isWallLike) go to
--      PreciseConvexDecomposition instead, because a Box collider fills
--      their openings - an archway becomes an invisible wall. They're
--      listed in the report for a human to check.
--   5. Removes every attribute and CollectionService tag.
-- It reports, but never fixes: other PreciseConvexDecomposition meshes,
-- suspected duplicate mesh uploads, and oversized textures. It never
-- touches Size, CFrame, MeshId, Material, Color, textures or any other
-- geometry/appearance property (map-kit-spec.md §3 step 6) - if an
-- art fix is needed, that's a separate pass, so a mistake in either
-- stays easy to isolate.
--
-- ROLES. Every part is either Solid (players walk on or bump into it)
-- or Decor (no gameplay role). The role comes from, in order:
--   - a `SanitiseRole` attribute ("Solid" or "Decor") on the part or its
--     nearest ancestor inside the selection - set it on a whole sub-model
--     to classify it in one go;
--   - otherwise the part's current CanCollide, i.e. the pack author's
--     own intent.
-- Solid: CanCollide on, CanQuery on, CanTouch off. Decor: all three off.
-- CanTouch is off for BOTH because only kill zones and station triggers
-- need it (spec §3 step 4), and those are added later by the builder,
-- not shipped in a pack. `SanitiseRole` is removed with every other
-- attribute on apply, which is safe: the applied CanCollide then encodes
-- the same role, so a second run infers the same answer.
--
-- REFUSES TO APPLY (dry run still reports) when the selection carries
-- one of the map contract's own tags. A raw pack never should, so either
-- this is a built map section - which stripping would wreck - or it's a
-- name collision a human needs to look at.
--
-- Undo: an applied run is a single ChangeHistory recording, so one
-- Ctrl+Z reverts all of it.
--
-- NOT SYNCED BY ROJO and never required - like the other Command Bar
-- scripts in scripts/, it only ever runs pasted. Hence the contract tag
-- list below is duplicated from map-kit-spec.md §1 rather than required
-- from plugin/MapValidator/MapCheck.luau; keep the two in step.

local AssetService = game:GetService("AssetService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

-- ===== settings =============================================================

local DRY_RUN = true

-- Longest texture edge, in pixels, before a texture is flagged.
-- PROVISIONAL: perf-budget.md sets a unique-texture count (< 100) but no
-- per-texture resolution, and names texture resolution as the first
-- thing to cut on memory. 1024 is a placeholder until P7-4 re-baselines
-- on a real device - change it here, it's only ever a report threshold.
local MAX_TEXTURE_EDGE = 1024

-- perf-budget.md §1 resident budgets. A single pack is only part of a
-- map, so blowing these alone is a strong warning, not an error.
local UNIQUE_MESH_BUDGET = 150
local UNIQUE_TEXTURE_BUDGET = 100

-- map-kit-spec.md §1. Keep in step with MapCheck.luau's tag table.
local CONTRACT_TAGS = {
	"SpawnPoint",
	"TaskStation",
	"PowerUpSpawn",
	"NavNode",
	"PlayableBounds",
	"KillZone",
	"StudioAnchor",
	"StudioPodiumSlot",
	"StudioBoundary",
	"StudioSpectatorArea",
}

local ROLE_ATTRIBUTE = "SanitiseRole"

-- map-kit-spec.md §3 step 3: a collidable mesh is wall/arch-like, and
-- kept off Box, when its thinnest edge is <= WALL_MAX_THICKNESS and the
-- other two are both >= WALL_MIN_SPAN, or its name contains one of
-- WALL_NAME_HINTS (case-insensitive). Keep in step with MapCheck.luau.
local WALL_MAX_THICKNESS = 3
local WALL_MIN_SPAN = 5
local WALL_NAME_HINTS = { "arch", "frame", "door" }

-- ===== the plan ==============================================================
--
-- Every change is recorded here first, then printed, then - only when
-- DRY_RUN is false - applied. Nothing below the plan-building section
-- decides anything.

type PropChange = { inst: Instance, prop: string, from: any, to: any }

local plan = {
	destroy = {} :: { Instance },
	props = {} :: { PropChange },
	attributes = {} :: { { inst: Instance, name: string } },
	tags = {} :: { { inst: Instance, tag: string } },
}

local blocking: { string } = {} -- reasons apply is refused
local warnings: { string } = {}

local function path(inst: Instance): string
	return inst:GetFullName()
end

-- ===== selection =============================================================

-- Drop any selected instance that sits inside another selected one, so
-- nothing is planned twice.
local function selectedRoots(): { Instance }
	local raw = Selection:Get()
	local roots = {}
	for _, inst in raw do
		local nested = false
		for _, other in raw do
			if other ~= inst and inst:IsDescendantOf(other) then
				nested = true
				break
			end
		end
		if not nested then
			table.insert(roots, inst)
		end
	end
	return roots
end

local roots = selectedRoots()
if #roots == 0 then
	error("sanitise-pack: nothing selected - select the pack's model(s) first")
end

-- Every instance under the selection, roots included.
local all: { Instance } = {}
for _, root in roots do
	table.insert(all, root)
	for _, d in root:GetDescendants() do
		table.insert(all, d)
	end
end
local instancesBefore = #all

-- ===== 1. scripts ============================================================
--
-- IsA("LuaSourceContainer") rather than listing classes, so a script
-- class added to the engine later is still caught. Only the topmost
-- script of a nest is destroyed (its descendants go with it), but every
-- one - and every non-script riding inside one - is logged.

local removed: { [Instance]: true } = {}
local scriptLog: { string } = {}

for _, inst in all do
	if inst:IsA("LuaSourceContainer") and not removed[inst] then
		table.insert(plan.destroy, inst)
		removed[inst] = true
		table.insert(scriptLog, `{inst.ClassName}  {path(inst)}`)
		for _, d in inst:GetDescendants() do
			removed[d] = true
			table.insert(scriptLog, `  (inside it) {d.ClassName}  {path(d)}`)
		end
	end
end

local survivors: { Instance } = {}
for _, inst in all do
	if not removed[inst] then
		table.insert(survivors, inst)
	end
end

-- ===== 5. attributes and tags ================================================
--
-- Planned here, applied at the end - so the role lookup below still
-- reads the live SanitiseRole attributes this section marks for removal.

local contractLower: { [string]: string } = {}
for _, tag in CONTRACT_TAGS do
	contractLower[string.lower(tag)] = tag
end

local tagLog: { string } = {}
local attributeLog: { string } = {}

for _, inst in survivors do
	for _, tag in inst:GetTags() do
		local tagName = tostring(tag)
		local lower = string.lower(tagName)
		local note = ""
		if contractLower[lower] then
			table.insert(
				blocking,
				`contract tag "{tagName}" on {path(inst)} - is this a built map section, not a raw pack?`
			)
			note = "  <- CONTRACT TAG"
		else
			for key, contractName in contractLower do
				if string.find(key, lower, 1, true) or string.find(lower, key, 1, true) then
					note = `  <- resembles contract tag {contractName}`
					break
				end
			end
		end
		table.insert(plan.tags, { inst = inst, tag = tagName })
		table.insert(tagLog, `"{tagName}"  {path(inst)}{note}`)
	end
	for name in inst:GetAttributes() do
		table.insert(plan.attributes, { inst = inst, name = name })
		table.insert(attributeLog, `{name}  {path(inst)}`)
	end
end

-- ===== 2-4. parts: anchoring, roles, collision fidelity ======================

local function setProp(inst: Instance, prop: string, to: any)
	local from = (inst :: any)[prop]
	if from ~= to then
		table.insert(plan.props, { inst = inst, prop = prop, from = from, to = to })
	end
end

-- Nearest SanitiseRole at or above `part`, stopping at the selection
-- root it belongs to. nil means "fall back to CanCollide".
local rootSet: { [Instance]: true } = {}
for _, root in roots do
	rootSet[root] = true
end

local badRoleNodes: { [Instance]: true } = {} -- report each bad value once

local function roleOf(part: BasePart): "Solid" | "Decor"
	local node: Instance? = part
	while node do
		local value = node:GetAttribute(ROLE_ATTRIBUTE)
		if value == "Solid" or value == "Decor" then
			return value
		elseif value ~= nil then
			if not badRoleNodes[node] then
				badRoleNodes[node] = true
				table.insert(
					blocking,
					`{ROLE_ATTRIBUTE} = {tostring(value)} on {path(node)} - must be "Solid" or "Decor"`
				)
			end
			break
		end
		if rootSet[node] then
			break
		end
		node = node.Parent
	end
	return if part.CanCollide then "Solid" else "Decor"
end

local roleCounts = { Solid = 0, Decor = 0 }
local unanchoredLog: { string } = {}
local preciseLog: { string } = {}
local wallLog: { string } = {}

local function isWallLike(mesh: BasePart): boolean
	local s = mesh.Size
	local dims = { s.X, s.Y, s.Z }
	table.sort(dims)
	if dims[1] <= WALL_MAX_THICKNESS and dims[2] >= WALL_MIN_SPAN then
		return true
	end
	local name = string.lower(mesh.Name)
	for _, hint in WALL_NAME_HINTS do
		if string.find(name, hint, 1, true) then
			return true
		end
	end
	return false
end

-- Before/after tallies for the summary table. `after` is what the part
-- will hold once the plan is applied.
type Tally = { before: number, after: number }
local tallies: { [string]: Tally } = {}
local TALLIED = { "Anchored", "CanCollide", "CanTouch", "CanQuery" }
for _, prop in TALLIED do
	tallies[prop] = { before = 0, after = 0 }
end
tallies.BoxFidelity = { before = 0, after = 0 }

local parts: { BasePart } = {}
for _, inst in survivors do
	if inst:IsA("BasePart") and not inst:IsA("Terrain") then
		table.insert(parts, inst)
	end
end

for _, part in parts do
	local role = roleOf(part)
	roleCounts[role] += 1
	local solid = role == "Solid"
	local target = {
		Anchored = true,
		CanCollide = solid,
		CanTouch = false,
		CanQuery = solid,
	}

	if not part.Anchored then
		table.insert(unanchoredLog, path(part))
	end
	for _, prop in TALLIED do
		local tally = tallies[prop]
		if (part :: any)[prop] then
			tally.before += 1
		end
		if target[prop] then
			tally.after += 1
		end
		setProp(part, prop, target[prop])
	end

	-- MeshPart and PartOperation (unions) both inherit CollisionFidelity
	-- from TriangleMeshPart. Decor keeps its fidelity: with collision and
	-- queries off it never computes against it, and "only the listed
	-- properties" means not tidying what the task didn't ask for.
	-- Solid wall/arch-like meshes go to Precise, not Box: Box fills
	-- doorways and arches (the hub hotel's 20.8 x 12.9 x 0.6 archway
	-- union became an invisible wall).
	if part:IsA("TriangleMeshPart") then
		local mesh = part :: TriangleMeshPart
		local fidelity = mesh.CollisionFidelity
		local wallLike = solid and isWallLike(mesh)
		if fidelity == Enum.CollisionFidelity.PreciseConvexDecomposition and not wallLike then
			table.insert(preciseLog, `{role}  {path(mesh)}` .. (if solid then "  -> Box" else "  (decor, left)"))
		end
		local wasBox = fidelity == Enum.CollisionFidelity.Box
		if wasBox then
			tallies.BoxFidelity.before += 1
		end
		if wallLike then
			local s = mesh.Size
			table.insert(
				wallLog,
				string.format("%s  (%.1f x %.1f x %.1f, was %s)", path(mesh), s.X, s.Y, s.Z, fidelity.Name)
			)
			setProp(mesh, "CollisionFidelity", Enum.CollisionFidelity.PreciseConvexDecomposition)
		elseif solid then
			tallies.BoxFidelity.after += 1
			setProp(mesh, "CollisionFidelity", Enum.CollisionFidelity.Box)
		elseif wasBox then
			tallies.BoxFidelity.after += 1
		end
	end
end

-- ===== report-only: duplicate meshes ========================================
--
-- Parts sharing one MeshId already share one resident mesh - that's
-- fine. The waste is the same geometry uploaded under DIFFERENT ids
-- (packs are often assembled from re-uploads), each resident on its
-- own. There's no permission-free way to compare geometry, so identical
-- MeshSize is used as the tell: a heuristic, reported as "suspected".

local meshUses: { [string]: number } = {}
local meshBySize: { [string]: { [string]: true } } = {}

local function sizeKey(v: Vector3): string
	return string.format("%.3f,%.3f,%.3f", v.X, v.Y, v.Z)
end

for _, part in parts do
	if part:IsA("MeshPart") and part.MeshId ~= "" then
		local id = part.MeshId
		meshUses[id] = (meshUses[id] or 0) + 1
		local key = sizeKey(part.MeshSize)
		local ids = meshBySize[key] or {}
		ids[id] = true
		meshBySize[key] = ids
	end
end

local uniqueMeshes = 0
for _ in meshUses do
	uniqueMeshes += 1
end

local duplicateLog: { string } = {}
for key, ids in meshBySize do
	local list = {}
	for id in ids do
		table.insert(list, `{id} (x{meshUses[id]})`)
	end
	if #list > 1 then
		table.sort(list)
		table.insert(duplicateLog, `MeshSize {key}: {table.concat(list, ", ")}`)
	end
end
table.sort(duplicateLog)

-- ===== report-only: texture sizes ===========================================
--
-- The only engine API that reports a texture's pixel size is loading it
-- as an EditableImage. That's permission-gated - it generally only works
-- for assets the experience's creator can use, and the place may need
-- the image/mesh API setting enabled in Game Settings > Security - so a
-- failure is reported as "unreadable", never as "within budget". Each
-- unique id is loaded once and released straight away.

local textureUses: { [string]: number } = {}
local textureOrder: { string } = {}

local function noteTexture(id: string)
	if id == "" then
		return
	end
	if not textureUses[id] then
		textureUses[id] = 0
		table.insert(textureOrder, id)
	end
	textureUses[id] += 1
end

for _, inst in survivors do
	if inst:IsA("MeshPart") then
		noteTexture(inst.TextureID)
	elseif inst:IsA("SurfaceAppearance") then
		noteTexture(inst.ColorMap)
		noteTexture(inst.NormalMap)
		noteTexture(inst.MetalnessMap)
		noteTexture(inst.RoughnessMap)
	elseif inst:IsA("Decal") then -- Texture inherits from Decal
		noteTexture(inst.Texture)
	end
end

local oversizeLog: { string } = {}
local unreadableLog: { string } = {}

for _, id in textureOrder do
	local ok, result = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(id))
	end)
	if ok then
		local image = result :: EditableImage
		local size = image.Size
		image:Destroy()
		if math.max(size.X, size.Y) > MAX_TEXTURE_EDGE then
			table.insert(oversizeLog, `{size.X}x{size.Y}  {id} (x{textureUses[id]})`)
		end
	else
		table.insert(unreadableLog, `{id} (x{textureUses[id]}): {tostring(result)}`)
	end
end

-- ===== counts ===============================================================

local instancesAfter = instancesBefore
for _ in removed do
	instancesAfter -= 1
end

if uniqueMeshes > UNIQUE_MESH_BUDGET then
	table.insert(
		warnings,
		`{uniqueMeshes} unique meshes - over the whole-map budget of {UNIQUE_MESH_BUDGET} on its own`
	)
end
if #textureOrder > UNIQUE_TEXTURE_BUDGET then
	table.insert(
		warnings,
		`{#textureOrder} unique textures - over the whole-map budget of {UNIQUE_TEXTURE_BUDGET} on its own`
	)
end
if #unanchoredLog > 0 then
	table.insert(
		warnings,
		`{#unanchoredLog} part(s) were unanchored - anchored now; if any was MEANT to move, re-check it by hand`
	)
end

-- ===== report ===============================================================

local function section(title: string, lines: { string }, emptyText: string?)
	print(`--- {title} ({#lines}) ---`)
	if #lines == 0 then
		print(`  {emptyText or "none"}`)
	end
	for _, line in lines do
		print(`  {line}`)
	end
end

print(`===== sanitise-pack: {if DRY_RUN then "DRY RUN - nothing changed" else "APPLYING"} =====`)
for _, root in roots do
	print(`  selected: {path(root)}`)
end

section("scripts removed", scriptLog, "none - clean")
section("tags removed", tagLog)
section("attributes removed", attributeLog)
section("unanchored parts (review: was it meant to move?)", unanchoredLog)
section("PreciseConvexDecomposition meshes", preciseLog)
section("wall/arch-like meshes -> PreciseConvexDecomposition, not Box (check openings stay walkable)", wallLog)
section("suspected duplicate mesh uploads (same MeshSize, different MeshId)", duplicateLog)
section(`textures over {MAX_TEXTURE_EDGE}px`, oversizeLog)
section("textures whose size couldn't be read", unreadableLog)

print("--- before -> after ---")
print(`  instances         {instancesBefore} -> {instancesAfter}  (delta {instancesAfter - instancesBefore})`)
print(`  parts             {#parts}  (Solid {roleCounts.Solid}, Decor {roleCounts.Decor})`)
for _, prop in TALLIED do
	local t = tallies[prop]
	print(`  {prop} = true   {t.before} -> {t.after}`)
end
print(`  Box fidelity      {tallies.BoxFidelity.before} -> {tallies.BoxFidelity.after}`)
print(`  unique meshes     {uniqueMeshes}   unique textures  {#textureOrder}`)
print(`  property writes   {#plan.props}`)

section("warnings", warnings)
section("BLOCKING - apply refused until fixed", blocking)

-- ===== apply ================================================================

if DRY_RUN then
	print("===== dry run complete - set DRY_RUN = false and re-run to apply =====")
	return
end

if #blocking > 0 then
	error(`sanitise-pack: refused to apply - {#blocking} blocking issue(s) above. Nothing changed.`)
end

local recording = ChangeHistoryService:TryBeginRecording("SanitisePack", "Sanitise asset pack")
if not recording then
	error("sanitise-pack: couldn't start an undo recording (another one in progress?). Nothing changed.")
end

local ok, err = pcall(function()
	-- Properties, attributes and tags first, while every instance is
	-- still in place; scripts last.
	for _, change in plan.props do
		(change.inst :: any)[change.prop] = change.to
	end
	for _, a in plan.attributes do
		a.inst:SetAttribute(a.name, nil)
	end
	for _, t in plan.tags do
		t.inst:RemoveTag(t.tag)
	end
	for _, inst in plan.destroy do
		inst:Destroy()
	end
end)

if ok then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	print("===== applied - one Ctrl+Z undoes all of it =====")
else
	-- Cancel rolls back whatever part of the plan had already landed, so
	-- a failure halfway leaves the pack exactly as it was.
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
	error(`sanitise-pack: apply failed and was rolled back: {tostring(err)}`)
end
