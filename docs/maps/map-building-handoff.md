# Map-building handoff: Don't Steal Bro!

**Who this is for:** an AI assistant (ChatGPT or similar) helping the
project owner build the game's level maps by hand in Roblox Studio. You
can't see the repository. This file is your full context. If you need a
detail that isn't here, ask the owner to paste the named file rather
than guessing.

**How to use it:** read all of it once. Then, for the map being built,
ask the owner to paste that map's section from
`docs/maps/wave1-briefs.md` (wave 1 maps only; wave 2 and 3 have no
brief yet, see §8).

---

## 1. The game in one paragraph

*Don't Steal Bro!* is a Roblox competitive party game for 6 players. They
race around a themed map completing short mini-tasks at **task stations**
(like the tasks in *Among Us*), while griefing each other with
**power-ups** picked up from pads on the floor. The first 3 to finish
their 6 tasks **qualify** and are teleported to the **Decision Studio**, a
sealed room on the same map, where they each secretly choose **Steal** or
**Share** (a prisoner's dilemma) to decide who progresses and with what
reward. The metagame is a win streak that resets to zero on any loss.
It's designed **mobile-first**: one thumb, portrait orientation, cheap
Android phone.

## 2. What already exists in the repo

The code is written and CI-tested. **No real map has been built yet.**
That's the job now.

- **Design (phase 0):** the design questions are resolved, plus a
  15-task catalogue, 10 power-ups with counters, the payoff table, the
  **map kit contract** (the rules in §4 below), a performance budget and
  a threat model.
- **Foundation (1):** a Rojo project with every code file in `--!strict`
  Luau, typed remotes, config files checked when the server boots, and
  player data on ProfileStore.
- **Core loop (2):** the round state machine, task assignment and
  qualification, 4 working mini-tasks, power-ups, status effects and
  movement anti-cheat.
- **Decision Studio and NPCs (3):** Steal/Share resolution, Studio phase
  logic, proximity chat, podium staging, NPC bots that fill empty seats
  (they walk the map using your NavNodes), and handling for disconnects.
- **Progression (4):** streaks, bounty, titles, all-time, daily and weekly
  leaderboards, the store, cosmetics and telemetry.
- **Hub (5):** matchmaking, reserved-server teleports, map voting, the hub
  and a practice area.
- **UI (6):** the HUD, task views, the Studio reveal, the menus, and
  accessibility.
- **Map tooling (7), which matters most to you:**
  - a **Map Validator** Studio plugin;
  - an **asset-pack sanitiser** script;
  - a config file for each of the 11 maps;
  - gray-box layout briefs for the 4 wave-1 maps;
  - lighting presets for each map and the streaming setup;
  - station readability markers.
- **Polish and launch (8–9):** a security audit, perf pooling, audio,
  the playtest protocol, live-ops switches, the store page and a
  live-ops roadmap.

**Place layout:** one experience with two places. The **Hub** place has
the lobby, store, leaderboards, voting and the queue. The **Match** place
runs one 6-player round per reserved server. **All maps live in the Match
place, under `ServerStorage.Maps`.** A match server clones exactly one map
in while the loading screen shows.

**Rojo never syncs maps.** Code comes from the repo. The `.rbxl` place
file is the source of truth for map content. That means maps are built
entirely by hand in Studio, with tags and attributes. **Map building
involves no scripting at all, and a map must never contain a script.**

### 2.1 What the code reads today, and what's contract-only

The map loader and matchmaking read these tags today: `TaskStation`,
`SpawnPoint`, `PowerUpSpawn` and `NavNode`, plus their attributes. The
other tags (`PlayableBounds`, `KillZone` and the four `Studio*` tags) are
in the contract and **the validator enforces them**, but the runtime code
that uses them hasn't been written yet. Build them exactly to the
contract anyway. The code will be written against the contract, not
against your map.

## 3. Where a map lives and how it's named

- Every map is one `Model` directly under **`ServerStorage.Maps`**.
- **The Model's `Name` must equal the map's config `id` exactly.** The
  server matches on it at boot, and a mismatch fails loudly. The 11 ids:

| Wave | Model name (`id`) | Display name |
|---|---|---|
| 1 (launch) | `School`, `Factory`, `Museum`, `Laboratory` | same |
| 2 | `Bunker`, `Prison`, `Mall`, `ConstructionSite` | Construction Site |
| 3 | `SpaceStation`, `AircraftCarrier`, `DesertedIsland` | Space Station, Aircraft Carrier, Deserted Island |

- Build a map in `Workspace` while you work, then move it into
  `ServerStorage.Maps` when it's ready. The validator handles both.
- Each map has **two areas inside the one Model:** the race arena, and a
  sealed **Decision Studio** room that can't be reached on foot. Players
  only get there by teleport.
- `ServerStorage.Maps.GrayBoxTest` is a throwaway test map made by a
  script. Leave it alone, but look at it: it's a working example of every
  tag below.

## 4. The contract: tags and attributes

Everything is set through Studio's **Tag Editor** (in the Model tab) and
the **Attributes** section of the Properties window. Tag names and
attribute names are case-sensitive and must match exactly.

| Tag | Put it on | Count | Required attributes |
|---|---|---|---|
| `SpawnPoint` | BasePart | **exactly 6** | `SpawnIndex`: integer 1–6, unique |
| `TaskStation` | BasePart (the interact anchor only) | **12–24** (wave 1: 16) | `StationId`: string, unique in the map. `AcceptedTaskIds`: string, comma-separated task ids |
| `PowerUpSpawn` | BasePart | **8–20** (wave 1: 12) | `Rarity`: `"Common"`, `"Uncommon"` or `"Rare"` exactly. Optional: `AllowedPowerUpIds`, a comma-separated string |
| `NavNode` | **Attachment** (not a part) | about 1.5–2× the station count (wave 1: 28–32) | `NodeId`: string, unique. `ConnectedNodeIds`: comma-separated `NodeId`s |
| `PlayableBounds` | BasePart | 1–4 (normally 2: arena + Studio) | none. The part's size is the volume |
| `KillZone` | BasePart | 1 or more | none. The part's size is the volume |
| `StudioAnchor` | BasePart | **exactly 1** | none. Where finalists land |
| `StudioPodiumSlot` | BasePart | **exactly 3** | `SlotIndex`: integer 1–3, unique |
| `StudioBoundary` | BasePart | **exactly 1** | `Radius`: number of studs, 8–30 (wave 1 uses 12) |
| `StudioSpectatorArea` | BasePart | 0 or 1 | none. Optional perimeter for 4th–6th place |

Notes on these tags:

- **One contract tag per instance.** The validator warns if an instance
  has more than one.
- **`Occupants` is reserved.** The server writes it on stations at
  runtime. Never create it.
- **TaskStation:** tag only the small interact anchor part. The machine,
  desk or console around it is ordinary untagged dressing. Put the anchor
  and its dressing together in their own Model: the loader sets that
  dressing to stream in as one piece, and makes the anchor always loaded.
- **`AcceptedTaskIds` today:** only four task ids are registered, which
  are `pressure-valve`, `vent-purge`, `fuse-rewire` and `code-playback`.
  An unregistered id is a **hard error** at boot and in the validator.
  **`vent-purge` is registered but has no handler or task screen yet**:
  a station offering it opens nothing, so don't use it until it ships.
  Give each station 1–3 of the other three. When more tasks ship, stations get
  widened, and that's a map edit, not a code edit.
- **NavNode:** an Attachment has to sit inside a part. Put it in an
  anchored floor part, or in an invisible, non-colliding, anchored helper
  part. **List each edge in both directions** (if A lists B, B lists A).
  Every station and power-up pad needs a node within about 40 studs, and
  the graph must be **one connected piece**.
- **Studio:** the 3 podium slots sit inside the `StudioBoundary` radius,
  measured from the boundary part's centre. The spectator space is
  outside it.
- **KillZone:** always put one **world-floor catch-all** under the whole
  map, plus one under any gap a player could fall through.

### 4.1 Per-map theming of the four current tasks

Each station's prop should look like its theme. When a station accepts
several tasks, pick a prop that plausibly fits all of them.

| Map | `pressure-valve` | `vent-purge` | `fuse-rewire` | `code-playback` |
|---|---|---|---|---|
| School | Jammed fire-alarm hammer | Chem-lab fume extractor | Boiler-room fuse box | Locker override keypad |
| Factory | Steam relief valve | Exhaust scrubber fan | Main distribution panel | Safety-interlock keypad |
| Museum | Burst sprinkler valve | HVAC purge switch | Climate-control fuse panel | Archive room keypad |
| Laboratory | Coolant pressure bleed | Biohazard containment vent | Equipment fuse rack | Cold-storage keypad |
| Mall | Fire-suppression valve | Food-court grease extractor | Escalator fuse panel | Stockroom keypad |
| Construction Site | Jackhammer air valve | Dust extraction fan | Site power fuse box | Site-office safe keypad |
| Space Station | O2 scrubber vent | Airlock decon purge | Power distribution node | Airlock override keypad |
| Bunker | Blast-door pressure equalizer | NBC filtration override | Backup power fuse rack | Vault keypad |
| Aircraft Carrier | Boiler steam valve | Engine-room smoke extractor | Damage-control fuse panel | Weapons-locker keypad |
| Prison | Cell-block klaxon silencer | Tear-gas ventilation override | Cell-block fuse box | Control-room keypad |
| Deserted Island | Geyser vent stone | Smoke-signal bellows | Salvaged battery bank | Carved rune lock |

## 5. Layout rules every map shares

These come from the wave-1 briefs, and they're **design targets to test
with a gray-box, not settled facts**. If the gray-box disagrees, the
gray-box wins.

### 5.1 Size and travel budget

- Walk speed is 16 studs/s. Each player does 6 tasks. The race timer is
  300 s. The target is a **clean human run of about 120 s**.
- **The footprint is 240–300 studs on the longest horizontal axis.**
- The mean walk between two random stations is **10–14 s**, and the
  longest is **≤ 25 s (≤ 400 studs)**. Players get their stations in a
  random order, so any two stations can be consecutive.
- **2 playable levels,** plus mezzanines or catwalks, joined by stairs
  and ramps only. **No lifts, and no moving floors or conveyors that
  carry players** (they break anti-cheat and pathfinding). Floors are
  about 16 studs apart.

### 5.2 Stations

- **An 8×8 stud clear pad** around each anchor, reachable from **at least
  2 sides**. A rival standing there must not block it.
- **No more than 3 stations within 40 studs of each other.** Every zone
  has at least 2.
- **None within 24 studs of spawn.**
- Mix task types within each zone.

### 5.3 Routes

- Build **at least two overlapping loops**, never a corridor with rooms
  hanging off it. Every pair of stations has 2 routes, and the second is
  at most about 25% longer.
- Dead ends are **≤ 48 studs** (station alcoves at most).
- Every level change has **2+ vertical links at opposite ends** of the
  map. **Spawn has 2 exits** leading to different loops.

### 5.4 Power-up pads (12 per wave-1 map: 6 Common, 4 Uncommon, 2 Rare)

- **Commons** sit on the loops, so a typical route passes 2–3 of them.
- **Uncommons** cost a 1–2 s detour.
- **Rares** cost a 3–4 s detour, somewhere exposed and overlooked from
  above.
- Keep pads **≥ 20 studs from any station**, and **none within 24 studs
  of spawn**.
- Place pads **30–50 studs before each choke point, on both sides**.

### 5.5 Sightlines and choke points

- Every map needs one **open central volume** (a courtyard, floor or
  atrium) overlooked by a **raised ring** (gallery or catwalk) with
  **railings or glass, not walls**.
- **At least 10 of 16 stations** can be seen from a loop more than 40
  studs away. Sightlines are **≤ 120 studs**.
- **2–3 deliberate chokes,** each **10–12 studs wide** and **≤ 40 studs
  long**. Each has an alternative route at most about 4 s longer. A choke
  is never at a spawn exit, never the only route to a station, and always
  overlooked.
- **Every raised walkway, bridge and balcony on a route has railings.**
  There are no unrailed drops next to routes, because the knockback
  power-ups would turn a stagger into a respawn.

### 5.6 NavNodes (about 28–32)

Place one node:

- per station, within 6 studs, on the side of the pad facing the loop;
- per power-up pad;
- at every junction;
- at the top and bottom of every stair or ramp;
- at every doorway narrower than 12 studs.

Both routes around every choke need nodes. Only draw an edge between two
nodes when there's a **clear straight walking line** between them.

### 5.7 Spawn, Studio, bounds

- **Spawn:** 6 pads in a shallow arc, 6 studs apart, facing into the map.
- **Studio:** a sealed room, **at least 60×60 studs of floor**, themed as
  *the room where the stealing happens*. Boundary radius 12, with 3
  podium slots inside and the spectator perimeter outside. It gets its
  own `PlayableBounds` part.

### 5.8 Readability on a phone (portrait)

- Each map has **one tall hero landmark** visible from nearly everywhere,
  plus one distinct landmark per zone. Tall shapes read in portrait, and
  wide ones get cropped.
- **Zones differ in shape, not just colour** (ceiling height, roof
  profile, one unmistakable prop). The game has to work for colour-blind
  players.
- Station props are **chunkier than the clutter** around them.
- **Dressing goes on walls and ceilings, never in walkways.**
- The game draws a light shaft and floor disc over every station
  automatically (4–14 studs tall), so keep the space above anchors clear.
  The shaft is capped below the floor above.

## 6. Build hygiene: asset packs, physics, performance

### 6.1 Every model from a third-party asset pack

Run `scripts/sanitise-pack.luau` (dry run first). It automates steps 1–5
below. If you do it by hand, go in this order:

1. **Delete every Script, LocalScript and ModuleScript.** Asset-pack
   scripts are the most common way Roblox games get backdoored. A script
   anywhere in a map is a **validator error**.
2. **Anchor everything** unless it's intentionally moving, and flag any
   part that moves.
3. **Collision:**
   - Walkable and bumpable geometry gets `CollisionFidelity = Box`.
     Never use `PreciseConvexDecomposition` on chunky solids — but thin
     walls, arches and door frames (thinnest side ≤ 3 studs, other two
     ≥ 5, or named arch/frame/door) get `PreciseConvexDecomposition`
     instead of `Box`, or the box fills the doorway
     (map-kit-spec.md §3 step 3).
   - Pure decor gets `CanCollide = false`, `CanTouch = false` and
     `CanQuery = false`.
4. **Only turn on `CanTouch` where something needs it** (kill zones,
   triggers).
5. **Strip the pack's own tags and attributes** before adding the
   contract's. A pack tag like `"Spawn"` confuses the validator.
6. Don't edit geometry or materials during this pass. That's a separate
   art pass.

### 6.2 Performance budget (low-end phone; numbers are low-confidence until measured)

| Metric | Budget |
|---|---|
| Instances in the map | < 12,000 descendants |
| Unique meshes / textures | < 150 / < 100 |
| Parts in view at once | < 2,500 |
| Draw calls per frame | < 180 |
| Visible triangles per frame | < 300,000 |
| Emitting particle emitters | < 25 |
| Frame rate | 30 fps floor |

The validator checks instances, meshes and textures. The rest are
measured on a device.

### 6.3 Place settings and lighting (set once, not per map)

- **Workspace settings:**
  - `StreamingEnabled = true`, `StreamingMinRadius = 64`,
    `StreamingTargetRadius = 256`
  - `ModelStreamingBehavior = Improved`, `StreamOutBehavior = LowMemory`
  - `StreamingIntegrityMode = PauseOutsideLoadedArea`
- **Don't put any `Atmosphere`, Bloom or ColorCorrection under
  `Lighting`.** Lighting is applied per map by code from a preset
  (`LightingPresets/<Map>.luau`). Wave 1 has real presets, and waves 2
  and 3 have placeholders to be written when the map is built.
- Presets keep fog starting at ≥ 120 studs and keep ambient light bright
  enough that no station sits in black shade. Design for that. Don't
  light a map with in-map fog or dark corners.
- **Streaming is automatic.** Builders set no streaming properties on map
  parts.

## 7. The map's config file (in the repo, done by the owner or Claude)

Each map already has `src/shared/Config/Maps/<Id>.luau`. When the map is
built, these fields get updated in code, not in Studio:

- **`taskStationCount`:** change the placeholder 12 to the real built
  count, which must be 12–24. The validator checks that it matches the
  number of tagged stations.
- **`enabledTaskIds`:** the task ids this map may use.
- **`thumbnailAssetId`, `musicTrackId`:** real asset ids.
- **`enabled`:** set to `true` only once the map is built, validated and
  shipping. The server refuses to boot if an enabled map has no Model
  in `ServerStorage.Maps`.
- **`npcDifficultyModifier`** (0.5–2.0) and **`stationMarker`** (optional
  tint and shaft settings): tuning, done after playtests.

## 8. Workflow for one map

1. **Brief.** For wave 1, use the map's section of
   `docs/maps/wave1-briefs.md`. It lays out the footprint, flow, 16
   station positions, 12 pads, chokes, nodes, Studio theme and asset
   categories. **Waves 2 and 3 have no brief yet.** Write one first,
   following §5 and the same headings: *Footprint and verticality, Flow,
   Task stations (16), Power-ups (12), Sightlines, Choke points (3),
   NavNodes, Decision Studio, Asset-pack categories, Map-specific
   gray-box proofs*.
2. **Gray-box.** Build it from plain grey parts in `Workspace`, in a Model
   named with the map id. Tag everything per §4. Include the Studio
   room.
3. **Validate.** Run the **Map Validator** plugin (the *Don't Steal Bro!*
   toolbar), using *Validate selected*. It checks:
   - scripts, tag counts and classes;
   - attributes and their types and enums;
   - task and power-up ids against config;
   - NavNode graph connectivity and proximity;
   - fall-through gaps not covered by a kill zone;
   - the perf budgets;
   - **reachability**, pathing from every spawn to every station and pad
     with the same agent NPCs use (radius 2, height 5, can jump).

   **Clear anything else in Workspace** (the hub, other maps) first,
   because it contaminates the reachability check. Fix every **error**,
   and read and justify every **warning**. Clicking a finding selects
   the offending parts.
4. **Test a round.** In `GameConfig.studioTest.mapId`, set the map's id
   (a code edit). Then press Play in Studio. A round runs on that map
   with NPC bots. A copy of the map already in Workspace is played as-is,
   so live edits count. Only one round runs per Play session.
5. **Prove the gray-box before any art.** It must pass all of these:
   - the validator is clean;
   - 10 random station pairs walked by hand average 10–14 s, none over
     25 s;
   - 5 rounds of 6 NPCs finish cleanly in about 100–160 s, with **no
     `gave up pathing` warning** in Output (that warning means a map
     bug);
   - blocking each choke still leaves every station reachable within
     about 4 s extra;
   - a portrait phone test: a first-timer finds their 6 stations without
     a map, and names the landmark from 3 random spots;
   - a density placeholder: fill in blocks at art density and check the
     budgets;
   - record the footprint and draw calls for the streaming radius;
   - a round trip to the Studio: 3 qualifiers are seated on the podiums,
     and 4th–6th stay outside the boundary.
6. **Art pass.** Dress it with sanitised asset packs: walls and ceilings,
   not walkways. Revalidate after every major batch.
7. **Move it into `ServerStorage.Maps`,** update the config (§7), and
   validate all maps.

## 9. How to help, and what not to do

**Do:**

- Give concrete, stud-level layouts:
  - coordinates or a grid plan;
  - lists of stations, pads and nodes with ids;
  - `ConnectedNodeIds` edge lists;
  - Studio build steps.
- Check your own numbers against §5 before presenting them.
- Use consistent ids, for example `StationId = "school-s01"` and
  `NodeId = "school-n01"`.
- For a Studio **Command Bar** helper (say, bulk-tagging selected parts),
  keep it to a one-shot snippet that is **never left inside the map**,
  and use only `CollectionService:AddTag` and `Instance:SetAttribute`.

**Don't:**

- invent new tags or attributes, or rename the existing ones;
- put a Script of any kind in a map;
- use a task id outside the four registered ones;
- add lifts, moving floors or unrailed drops beside routes;
- add lighting effects inside the map;
- assume a Roblox API from memory. Roblox APIs change, so if a step
  depends on an exact property or method name, say so and have the owner
  confirm it in Studio.

**Stop and ask the owner** before anything that would change the game
rather than the map: task balance, power-up behaviour, round timers,
the Studio rules.
