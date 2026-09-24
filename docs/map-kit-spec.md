# Don't Steal Bro! — Map Kit Contract (P0-5)

All 11 maps are built by hand in Studio from asset packs and live in
`ServerStorage.Maps` — never synced by Rojo, per `CLAUDE.md`. This document
is the contract every one of them must satisfy so the same game code can
run on any of them. It assumes no scripting knowledge: everything below is
done through Studio's **Tag Editor** (Model tab → Tag Editor) and the
**Attributes** section of the Properties window. A validator plugin and an
asset-pack sanitiser (later tasks) will check this contract automatically —
this document is what they'll check against, and what you can already
build correctly today without either tool existing yet.

## 1. CollectionService tag contract

| Tag | Instance class | Count |
|---|---|---|
| `SpawnPoint` | BasePart | exactly 6 |
| `TaskStation` | BasePart | 12–24 |
| `PowerUpSpawn` | BasePart | 8–20 |
| `NavNode` | Attachment | ~1.5–2× the `TaskStation` count, no hard cap |
| `PlayableBounds` | BasePart | 1–4 |
| `KillZone` | BasePart | 1+, no hard cap |
| `StudioAnchor` | BasePart | exactly 1 |
| `StudioPodiumSlot` | BasePart | exactly 3 |
| `StudioBoundary` | BasePart | exactly 1 |
| `StudioSpectatorArea` | BasePart | 0–1 (optional) |

The last four exist for `design-decisions.md` Q3: all up to 6 finalists
teleport into the Studio together, the 3 qualifiers stand fixed on podium
slots inside a proximity boundary, and 4th–6th place can watch from the
perimeter but can't cross in. That mechanic only works if every map
defines these four tags consistently.

### `SpawnPoint`

Race-start position for one of the 6 finalists.

- **Attributes:** `SpawnIndex` (integer, 1–6, unique across the map).
- **Count:** exactly 6.
- **What breaks if missing:** `RoundService` assigns each finalist a spawn
  by index at round start. Fewer than 6 means a player has no valid
  position — they either fall through the world or two players spawn
  stacked on top of each other. The validator (P7-1) rejects the map
  outright below 6; it isn't a soft warning.

### `TaskStation`

The interactable anchor for one mini-task from `tasks-catalogue.md`. The
surrounding decorative geometry (workbench, machine, prop) is ordinary
untagged map dressing — only the interact point itself carries the tag.

- **Attributes:**
  - `StationId` (string) — unique per-map id for this specific station
    instance, used for analytics and debugging (distinct from the task
    id it runs).
  - `AcceptedTaskIds` (string, comma-separated) — one or more task ids
    from the catalogue (e.g. `"pressure-valve,vent-purge"`) this station
    is allowed to run. Multiple ids let `TaskService` vary which task
    appears here across rounds for replay variety.
- **Count:** 12–24. The floor of 12 matches the level-design brief's
  minimum for laying out 6 players' personal task lists without
  bottlenecking everyone into the same 3–4 stations; the ceiling is a
  soft one pending the real numeric budget from P0-6.
- **What breaks if missing:** below 12, personal task lists can't be laid
  out without heavy queuing (which reads as griefing rather than
  design). If `AcceptedTaskIds` references an id the config registry
  doesn't recognize, `TaskService` can't roll a challenge there — this
  fails a boot-time assertion (per Ground Rule 2, a bad config should
  fail loudly, not silently no-op) and P7-1's validator flags it as a
  hard error, not a warning.

### `PowerUpSpawn`

A field pickup location for one of the 10 power-ups in `powerups.md`.

- **Attributes:**
  - `Rarity` (string enum: `"Common"` / `"Uncommon"` / `"Rare"`) —
    matches a power-up's own rarity field; governs which items are
    eligible to roll here.
  - `AllowedPowerUpIds` (string, comma-separated, **optional**, default
    empty) — restricts this pad to specific power-up ids if a level
    designer wants a thematic fit (e.g. a `slow-field` pad next to a
    narrow corridor). Empty means any power-up matching `Rarity` is
    eligible.
- **Count:** 8–20.
- **What breaks if missing:** below 8, `PowerUpService` can't maintain
  reasonable pickup density across the map's footprint, and pickups
  cluster unfairly near whoever spawns closest. `Rarity` with an invalid
  value (not one of the three) fails validation — it's an enum, not free
  text, specifically so a typo can't silently spawn nothing there.

### `NavNode`

One waypoint in the coarse graph NPCs path across — per `architecture.md`'s
NPC deep dive, NPCs walk via `PathfindingService` using these as coarse
waypoints and recompute only when blocked, never per frame.

- **Attributes:**
  - `NodeId` (string, unique per map).
  - `ConnectedNodeIds` (string, comma-separated `NodeId`s) — the edges
    out of this node. This is what lets the validator check graph
    connectivity and report orphaned nodes, rather than inferring edges
    from proximity.
- **Count:** no hard minimum count, but every `TaskStation` and
  `PowerUpSpawn` must have at least one `NavNode` within reasonable
  walking proximity (a builder judgment call today; the validator will
  automate this as a reachability check), and the graph must be a single
  connected component — no orphaned nodes.
- **What breaks if missing:** NPCs can't path around the map at all,
  which breaks Q2's NPC-backfill mechanic on that specific map — an
  NPC-filled Studio seat simply never gets there. A disconnected graph
  (some nodes reachable, some not) strands NPCs at the boundary between
  components, where they'll repeatedly report "blocked" and stall in
  place rather than finishing their route.

### `PlayableBounds`

Defines the volume considered "in play" for anti-exploit and
out-of-bounds checks.

- **Attributes:** none required — the part's own size and position
  define the bounding volume.
- **Count:** 1–4. One is the target for most maps; more than one is only
  for maps with genuinely disjoint playable pockets (e.g. an island
  group connected by bridges you'd rather bound separately).
- **What breaks if missing:** the server has nothing to check a player's
  position against, so a teleport/fling exploit that puts a player
  outside the intended map geometry goes completely undetected — this is
  a security gap, not just a polish one, per Ground Rule 1.

### `KillZone`

A volume that returns a fallen player to safety — under gaps, off ledges,
below the map floor.

- **Attributes:** none required — geometry defines the volume.
- **Count:** 1 or more, no hard cap; every map needs at least a
  world-floor catch-all.
- **What breaks if missing:** a player who falls through a gap has no
  server-authoritative recovery, so they either get stuck permanently
  below the map (a support ticket, not just a bad experience) or — worse
  — a player deliberately dives off geometry to escape hazards or stall
  the round with no consequence. This is exactly what P7-1's "gaps a
  player could fall through that are not over a kill zone" check exists
  to catch.

### `StudioAnchor`

The single teleport-destination reference point for the Decision Studio
phase — where the group of up to 6 finalists lands.

- **Attributes:** none required — position and orientation only.
- **Count:** exactly 1.
- **What breaks if missing:** `RoundService` has nowhere to send players
  once qualification resolves. Every round on that map hard-fails at the
  `Qualified → DecisionStudio` transition.

### `StudioPodiumSlot`

One of the 3 fixed positions the current qualifiers stand on.

- **Attributes:** `SlotIndex` (integer, 1–3, unique across the map's 3
  instances).
- **Count:** exactly 3.
- **What breaks if missing:** fewer than 3 means the game can't seat all
  3 qualifiers at distinct positions — either two players clip into the
  same spot, or the 4th-place-promotion path (Q3) has no slot to move an
  alternate into when a podium player disconnects.

### `StudioBoundary`

The proximity-circle boundary separating the podium interior (qualifiers
only) from the spectator perimeter (4th–6th place).

- **Attributes:** `Radius` (number, studs, 8–30) — the boundary check
  uses this rather than inferring a shape from the part's mesh, so it
  stays robust regardless of how the part is visually dressed.
- **Count:** exactly 1.
- **What breaks if missing:** this tag is the entire mechanism Q3 was
  designed around — without it, there's no geometry to gate access
  against, and the game collapses back into the original problem Q3
  solved (a promoted 4th-place finisher needing a risky re-teleport
  instead of a simple access-flag flip).

### `StudioSpectatorArea` (optional)

Marks the walkable perimeter for non-qualifiers, if a level designer wants
to constrain it explicitly rather than defaulting to "anywhere inside
`PlayableBounds` but outside `StudioBoundary`."

- **Attributes:** none required.
- **Count:** 0 or 1.
- **What breaks if missing:** nothing — this is a convenience tag for
  designers who want tighter control over where spectators can wander;
  its absence just means the default (bounds minus boundary) applies.

## 2. Per-map config module shape

One file per map in `src/shared/Config/Maps/<MapName>.luau`, matching this
`--!strict` type. `waveNumber` and `enabled` gate content-wave rollout
(ship 4 maps, not 11, at launch per the build plan); `enabledTaskIds` lets
a map exclude specific tasks from its rotation without touching any other
map's file, per Ground Rule 2.

```lua
--!strict
export type MapDef = {
	id: string,
	displayName: string,
	description: string, -- one line, in the game's voice
	thumbnailAssetId: string, -- "rbxassetid://..."
	lightingPreset: string, -- key into the lighting preset table (P7-5)
	musicTrackId: string, -- "rbxassetid://..."
	enabledTaskIds: { string }, -- subset of tasks-catalogue.md ids
	npcDifficultyModifier: number, -- 0.5–2.0, 1.0 = baseline
	waveNumber: 1 | 2 | 3,
	enabled: boolean, -- false = built but not yet live
	taskStationCount: number, -- 12–24; see note below
}
```

**`taskStationCount` (added by P1-4).** The map author's own DECLARED
`TaskStation` count, not something introspected from real geometry — maps
are hand-built in Studio and never synced by Rojo (`CLAUDE.md`), so
`ConfigValidator` (P1-4) has no access to the live `.rbxl` to count tags
itself. It exists so boot-time validation can assert this document's own
rule — every map has at least as many stations as `GameConfig.
tasksPerPlayer` — against a number, rather than skipping the check
entirely until P7-1's Studio validator plugin can inspect the real tag
count. Keep it honest: update it by hand whenever the actual station
count in Studio changes. P7-1 checking the two numbers actually match is
future work, not covered yet.

A registry module collects every `MapDef` and asserts at boot that every
`enabled = true` map has a matching built model in `ServerStorage.Maps` —
a config referencing a map nobody built should fail loudly at server
start, not at the moment a round tries to load it.

## 3. Builder's checklist

Run through this for **every** model pulled from a third-party asset pack
before it goes into a map, in order:

1. **Strip scripts.** Delete every `Script`, `LocalScript`, and
   `ModuleScript` inside the model, with no exceptions. A script shipped
   inside a downloaded asset pack is the single most common way a Roblox
   game gets backdoored — this is a security step, not tidiness (Ground
   Rule 1). `scripts/sanitise-pack.luau` (P7-2) automates steps 1–5 and
   logs every script it removes — run it on every pack, dry run first.
   Doing this step by hand is only the fallback.

2. **Anchor everything.** Every part should be `Anchored = true` unless
   it has a specific, intentional reason to move (and if it does, flag
   it for review — unanchored parts are a recurring source of physics
   bugs in dense maps).

3. **Set collision fidelity by role.**
   - Floors, walls, and anything players walk on or bump into:
     `CollisionFidelity = Box` on the collision mesh. Never leave a mesh
     on `PreciseConvexDecomposition` — it's the most expensive collision
     type and almost never needed for level geometry.
   - Pure decoration (a poster, a light fixture, background clutter):
     `CanCollide = false`, `CanTouch = false`, `CanQuery = false`. Decor
     has no gameplay role and shouldn't cost a physics check.

4. **Set `CanTouch`/`CanQuery` deliberately, not by default.** Only parts
   that need to detect a player (kill zones, task station triggers)
   should have `CanTouch = true`. Leaving it on by default across a whole
   asset pack is a common, invisible performance cost in a dense map.

5. **Remove attributes and tags the pack shipped with.** Asset packs
   sometimes carry their own attributes or tags from whatever tool
   exported them. Clear these before adding this contract's tags — a
   stray tag that happens to match one of this document's names (e.g. a
   pack's own `"Spawn"` tag) will confuse the validator.

6. **Never touch geometry or materials while doing 1–5.** These are
   property changes only. If a model needs its actual geometry fixed,
   that's a separate art pass, not part of this checklist — mixing the
   two makes mistakes hard to isolate and undo.

7. **Streaming.** Exact `StreamingEnabled` numbers are P0-6/P7-5's job,
   not this document's — but the rule that already applies today: every
   instance carrying a tag from Section 1 (`SpawnPoint`, `TaskStation`,
   `PowerUpSpawn`, `NavNode`, `StudioAnchor`/`StudioPodiumSlot`/
   `StudioBoundary`, `KillZone` boundaries) must never be allowed to
   stream out from under a player mid-round. If you're not sure whether
   a piece of gameplay-critical geometry counts, mark it `Persistent` and
   flag it for the streaming pass to confirm rather than guessing.
   **Update (P7-5):** the streaming pass is done, and builders set
   nothing. The map loader makes `TaskStation` anchors Persistent and
   their dressing Atomic automatically. The other tags are read only by
   the server, which always has the whole map. See
   `lighting-and-streaming.md` §2.

8. **Performance numbers are out of scope here.** Poly count, texture
   size, and draw call budgets are P0-6's job. This checklist gets a
   model *structurally* correct; it doesn't yet tell you whether your map
   is fast enough — that check comes later, and the validator plugin
   (P7-1) will run both together once it exists.
