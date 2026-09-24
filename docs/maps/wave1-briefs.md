# Don't Steal Bro! — Wave 1 Gray-Box Briefs (P7-4)

Level design briefs for the four launch maps: **School, Factory, Museum,
Laboratory**. Each one is a brief for building a *gray-box* (plain parts,
no art) in Studio under `ServerStorage.Maps.<id>`. It has to satisfy
`map-kit-spec.md` and be run through the P7-1 validator before anyone
starts the art pass.

**Nothing here has been built or playtested.** Every distance, count and
timing below is a design target derived from the numbers in config today.
The gray-box exists to check them. When a gray-box disagrees with this
document, trust the gray-box and update this document.

Section 1 holds the rules all four maps share. Sections 2–5 are the
per-map briefs, and they only repeat a shared rule when the map bends it.

---

## 1. Shared rules — every map plays the same game

### 1.1 The budget the layout is built from

| Input | Value today | Source |
|---|---|---|
| Base walk speed | 16 studs/s | `StatusEffects.luau` `BASE_WALK_SPEED` |
| Tasks per player | 6 | `GameConfig.tasksPerPlayer` (PLACEHOLDER) |
| Race time limit | 300 s | `GameConfig.raceDurationSeconds` (PLACEHOLDER) |
| Mean task time | ~8.5 s | `tasks-catalogue.md` target-time midpoints |
| Station arrival radius (NPC) | 6 studs | `GameConfig.npc.stationArrivalRadiusStuds` |
| Aimed/Nearest power-up range | 24 studs | `GameConfig.powerUpUseRangeStuds` |
| Streaming target radius | 200–300 (to be set from these gray-boxes) | `perf-budget.md` §2 |

**Target a clean human run of about 120 s.** Six tasks at ~8.5 s take
~50 s, which leaves ~70 s of travel over 6 legs (spawn → station 1 →
… → station 6), or **~12 s (~190 walking studs) per leg**. The margin up
to the 300 s timer is for power-ups, queuing and mistakes. If the timer
settles well below 300 s, the footprint has to shrink with it.

`TaskAssignment` gives each player the stations in a **shuffled order**,
so a leg can join any two stations on the map. The average leg is
therefore the **average walking distance between two random stations**.
On a square footprint of side *L*, the average straight-line distance
between two random points is about 0.52 *L*. Walls and stairs add roughly
35%, so the average walk is about 0.7 *L*. That gives
**L ≈ 260–280 studs**, the size every brief below is scaled to.

| Target | Value |
|---|---|
| Footprint (longest horizontal axis) | 240–300 studs |
| Mean station-to-station walk | 10–14 s |
| Longest station-to-station walk | ≤ 25 s (≤ 400 studs); never more than 2× the mean |
| Floors | 2 playable levels (plus mezzanines or catwalks); stairs and ramps only, **no lifts** |

With this footprint, the whole playable area sits inside the recommended
streaming target radius. Streaming on these maps is about unloading
dressing, not gameplay geometry, which is the outcome `perf-budget.md`
wants.

### 1.2 Task stations

- **16 stations per wave-1 map.** The spec allows 12–24. There are 36
  assignments per round (6 players × 6 tasks), so 16 stations averages
  2.25 visitors per station, against 3 with 12 stations. That means less
  accidental queuing, without growing the map past its travel budget.
  When a map is built, update `taskStationCount` in its config from the
  placeholder `12` to the real count.
- **Clear pad of 8×8 studs** around each interact anchor, reachable from
  **at least two sides**. A rival standing at a station must not block
  it. Decor may frame a station but must not wall it in.
- **Spread, not clustered.** No more than 3 stations within 40 studs of
  each other, and every zone of the map holds at least 2. A cluster
  makes the random route order meaningless, because every route passes
  through it.
- **Mix the verbs by zone.** Each zone (wing, hall, level) should mix
  task verbs (Tap / Hold / Drag / Sequence / Timing / Aim). Otherwise a
  player who is weak at drag tasks can predict which part of the map
  will cost them time.
- **Nothing within 24 studs of spawn.** Otherwise the first leg is free
  for whoever spawns nearest.
- **Tagging while the task pool is incomplete.** Only 4 task ids are
  registered today: `pressure-valve`, `vent-purge`, `fuse-rewire` and
  `code-playback`. An `AcceptedTaskIds` entry that isn't registered
  fails the boot-time assertion (map-kit-spec §1), so every station
  table below has two columns:
  - **Target**: the full thematic list, for when those tasks exist.
  - **Tag today**: the registered subset to actually type into the
    attribute.

  As tasks get registered, widen the attribute toward Target. That is a
  map edit, not a code edit.

### 1.3 Routing

- **Never one dominant route.** Every pair of stations has at least two
  routes, and the second is no more than ~25% (≈3 s) longer. In practice:
  lay each map out as **at least two overlapping loops**, never as a
  corridor with rooms hanging off it.
- **Dead ends ≤ 3 s.** A spur off a loop is fine up to ~48 studs, the
  length of a station alcove. Nothing longer.
- **At least two vertical links per level change**, at opposite ends of
  the map. A single staircase is a choke nobody chose.
- **Spawn has two exits** leading to different loops.
- **No moving floors in wave 1.** Conveyors, elevators and moving
  platforms are decoration only (non-collidable, or collidable but
  static). Anything that carries a player fights `MovementWatch`'s speed
  model and PathfindingService at once. Add them later on purpose, not
  by accident with an asset pack.

### 1.4 Power-up spawns

**12 pads per map:** 6 Common, 4 Uncommon, 2 Rare. The spec allows 8–20.
Placement should make a pickup a *choice*, not something you walk over
by accident.

- **Commons sit on the loops**, spaced out so a typical 6-leg route passes
  2–3 of them without detouring.
- **Uncommons cost a small detour** of 1–2 s off the natural line, or sit
  on the less-used of a pair of routes. This rewards the longer route and
  keeps players from all funnelling through the shorter one.
- **Rares cost a real detour** of 3–4 s. The best place for one is
  somewhere exposed and overlooked from above, so collecting it risks
  being hit by a rival on the high ground.
- **20+ studs from any station.** A pad next to a station lets players
  camp it and hit everyone who arrives at the station.
- **Covering the approach to a choke from both sides.** Place pads 30–50
  studs before each choke point, so that "arm up before the bottleneck"
  or "arm up after it" is a real decision (see 1.6).
- **`AllowedPowerUpIds` is optional.** Use it where the geometry makes an
  item dramatic, for example `slow-field` or `push-trip` on the pad
  before a narrow crossing. Leave most pads open.
- **None within 24 studs of spawn.** Otherwise someone can hit the whole
  field before the race has started.

### 1.5 Sightlines — seeing the overtake coming

A player should often *see* a rival heading for their station or closing
on the finish, not only read it off the HUD.

- **Every map has an open central volume** (courtyard, factory floor,
  rotunda, shaft) that can be **overlooked from a raised ring**:
  a gallery, catwalk, balcony or walkway. It is the place where you see
  the race.
- **Most stations (target ≥ 10 of 16) are visible from somewhere on a
  loop more than 40 studs away.** Hidden stations are fine as long as
  they are the exception.
- **Railings and glass, not walls,** along raised rings. They keep
  sightlines open and still stop people falling off.
- **Sightlines ≤ ~120 studs.** Past that, a character on a phone screen is
  a few pixels and the sightline stops carrying information.

### 1.6 Choke points — dramatic, not oppressive

**2–3 deliberate chokes per map.** Each one:

- is **10–12 studs wide**, so two avatars fit side by side with room to
  sidestep, and **≤ 40 studs long** (≤ 2.5 s to cross);
- has an **alternative route no more than ~4 s longer**, so a slow-field
  sitting on a choke is a detour, not a wall;
- **is never at the spawn exit and never the only route to any station**;
- is **overlooked by a sightline**, so everyone can see griefing happen
  there. Being visible is what makes it dramatic.

`slow-field`'s zone radius isn't set in config yet (`SlowField.luau` has
only a duration). These briefs assume it is **≤ 12 studs**, so it can
fill the width of a choke but not both routes around it. If P5 tuning
sets it larger, the choke widths here have to grow with it.

**No ledges into kill zones on routes.** Every raised walkway, bridge and
balcony on a route is railed. `push-trip` knockback next to an unrailed
drop would turn a 1 s stagger into a respawn. That is the oppressive
kind of griefing, so wave 1 doesn't build it at all. Whether to
experiment with it later is for playtest data to decide.

### 1.7 NavNode graph

**~28–32 nodes per map.** The spec asks for ~1.5–2× the station count,
which is 24–32 for 16 stations. Place them by rule, not by eye:

1. **One node per station**, inside the 6-stud arrival radius, on the pad
   side facing the nearest loop.
2. **One node per power-up pad.**
3. **One node at every junction** where a loop branches or two loops
   meet.
4. **One node at the top and bottom of every staircase or ramp**, plus
   a node at every doorway narrower than 12 studs.
5. **Both routes around every choke get nodes.** If NPCs only know the
   choke route, all 5 bots jam it and look scripted.
6. **Edges connect only along clear walking lines.** An edge that passes
   through a wall is a guaranteed recompute. List edges in both
   directions in `ConnectedNodeIds`.
7. **One connected component.** The P7-1 validator checks this; build it
   right the first time.

NPCs recompute only when blocked (`architecture.md`), so a graph that
follows the loops yields bots that race like players. If
`gave up pathing ... teleporting` appears in the output, it is a map bug
(`npc-notes.md` §3 step 8).

### 1.8 Spawn, Studio, bounds, kill zones

- **Spawn:** 6 `SpawnPoint` pads in a shallow arc, 6 studs apart, all
  facing into the map. Two exits (1.3).
- **Decision Studio:** a **sealed room that cannot be reached on foot
  during the race**. Players get there by teleport only. It needs at
  least 60×60 studs of floor. `StudioBoundary` `Radius` = 12 studs with
  3 `StudioPodiumSlot`s inside it, and the spectator perimeter sits
  outside the boundary. Give it its own `PlayableBounds` part (the spec
  allows up to 4 for disjoint pockets). Each map themes its Studio as a
  place that stages a reveal. It has to read as *the room where the
  stealing happens*, not a side room.
- **`PlayableBounds`:** one part for the race area, one for the Studio.
- **`KillZone`:** a world-floor catch-all under the whole map, plus one
  under any gap a player could reach (P7-1 flags gaps without one).

### 1.9 Readability on a phone

The target is portrait orientation on a cheap Android phone. Portrait
narrows the horizontal field of view a lot and leaves vertical room.

- **Landmarks are tall.** Each map has one hero landmark visible from
  nearly everywhere, plus one distinct secondary landmark per zone.
  Tall silhouettes read in portrait; wide ones get cropped.
- **Distinct silhouettes, not colours.** Zones must differ in *shape*:
  ceiling height, roof profile, one unmistakable prop. They must still
  read correctly for a colour-blind player (`accessibility.md`), and
  colour can only be a second cue.
- **Stations read against the dressing.** Keep station props physically
  chunkier than the clutter around them and clear the 8×8 pad
  (1.2). P7-6's highlight layer is on top of this, not a substitute
  for it.
- **Dense but readable** means dressing goes **on walls and ceilings,
  not in walkways**. Floor clutter slows movement, confuses pathfinding
  and hides players. Keep walkways clear and pile the dressing around
  the edges.

### 1.10 What every gray-box must prove before art starts

Nobody spends a day on art until the gray-box passes all of these:

1. **P7-1 validator is clean.** Zero errors, and every warning read and
   either fixed or explained.
2. **Travel budget holds.** Walk 10 random station pairs by hand at base
   speed. The mean is 10–14 s and none is over 25 s. Then run 5 rounds of
   6 NPCs in Studio test mode: clean bot finish times of ~100–160 s,
   with no `gave up pathing` warnings.
3. **Two routes, no long dead ends.** For each choke, block it with a
   part and confirm every station is still reachable within ~4 s extra.
4. **Phone test in portrait.** On a real phone (or the Studio device
   emulator in portrait at the lowest tier), a first-time tester finds 6
   assigned stations with the HUD's nearest-objective indicator but
   **no map**, and names the hero landmark from 3 random spots.
5. **Density placeholder.** Fill the gray-box with plain blocks at the
   density the art will reach (walls and ceilings, per 1.9), then check
   the instance count and draw calls against `perf-budget.md` §1 on the
   reference low-end device. If the gray-box already blows the budget,
   the art will too.
6. **Streaming radius measured.** Record the footprint and the draw calls
   at a trial `StreamingTargetRadius`, and feed that into P7-5
   (`perf-budget.md` §2 deliberately leaves the number to this step).
7. **Studio round-trip.** Finish a round and confirm the teleport into
   the Studio seats 3 qualifiers on the podium slots and keeps 4th–6th
   outside the boundary.

---

## 2. School

> *"Detention for anyone caught stealing. So, everyone."*

**Concept.** A two-storey school built around a central courtyard. It is
the most familiar space in the set, which makes it the **onboarding map**:
simple loops, gentle vertical changes, and the most forgiving
sightlines.

### Footprint and verticality

- **~260 × 200 studs**, 2 floors (ground + upper, ~16 studs apart).
- The four wings form a hollow rectangle around a **~90 × 70 courtyard**.
  - **South:** entrance hall, admin office.
  - **West:** gym and locker rooms. The gym is double height and fills
    both floors.
  - **North:** cafeteria and kitchen downstairs, library upstairs.
  - **East:** science lab and computer lab.
- **Hero landmark:** a **clock tower** over the entrance, visible from the
  courtyard and every upper window.
- **Zone landmarks:**
  - gym: arched barrel roof;
  - cafeteria: tall serving-hatch chimney;
  - science wing: rooftop weather station mast.
- **Vertical links (4):** main stair (SW corner), back stair (NE corner),
  an outdoor fire-escape stair on the east wall, and a wide ramp from the
  courtyard up to the library terrace.

### Flow

```
                 N  [Cafeteria/Kitchen]  (Library terrace above)
                  +-------------------------------+
                  | K1                        K2  |
  [Gym/           |      +---------------+        |  [Science/
   Lockers]   W   |  G1  |   COURTYARD   |  E1    |   Computer]  E
  (double         |      |  (ramp to N   |        |  fire escape
   height)        |  G2  |   terrace)    |  E2    |  on east wall
                  |      +------+ +------+        |
                  | S1        gate       S2       |
                  +--------- Entrance hall -------+
                         S  [SPAWN: front lawn]
```

- **Loop A (ground ring):** the corridor around the courtyard, through all
  four wings. Safe and slightly long.
- **Loop B (upper gallery ring):** the upper corridor with **glass
  railings overlooking the courtyard**. This is the sightline loop.
- **Cut-through:** across the courtyard, fast and exposed, overlooked
  from the whole upper ring.
- **Spawn:** the front lawn, with two exits: the main entrance doors
  (Loop A) and the courtyard side gate (cut-through).

### Task stations (16)

| StationId | Location | Target `AcceptedTaskIds` | Tag today |
|---|---|---|---|
| `sch-01` | Entrance hall, fire-alarm panel | `alarm-killswitch,breaker-sequence` | — see note |
| `sch-02` | Admin office, PA desk | `morse-relay,code-playback` | `code-playback` |
| `sch-03` | Locker bank, south corridor | `lock-tumbler,code-playback` | `code-playback` |
| `sch-04` | Gym floor, ball launcher | `turret-calibration,crate-winch` | — see note |
| `sch-05` | Gym equipment cage | `crate-winch,lock-tumbler` | — see note |
| `sch-06` | Locker room, showers boiler | `pressure-valve,vent-purge` | `pressure-valve,vent-purge` |
| `sch-07` | Cafeteria tray return | `conveyor-sort,breaker-sequence` | — see note |
| `sch-08` | Kitchen extractor hood | `vent-purge,pressure-valve` | `vent-purge,pressure-valve` |
| `sch-09` | Library returns desk (upper) | `conveyor-sort,code-playback` | `code-playback` |
| `sch-10` | Library AV room (upper) | `cable-splice,fuse-rewire` | `fuse-rewire` |
| `sch-11` | Computer lab (upper east) | `code-playback,cable-splice` | `code-playback` |
| `sch-12` | Science lab fume cupboard | `vent-purge,reactor-sync` | `vent-purge` |
| `sch-13` | Science prep room fuse board | `fuse-rewire,breaker-sequence` | `fuse-rewire` |
| `sch-14` | Courtyard weather station | `sensor-sweep,turret-calibration` | — see note |
| `sch-15` | Janitor's closet (upper south) | `breaker-sequence,fuse-rewire` | `fuse-rewire` |
| `sch-16` | Basement-stair boiler hatch (off courtyard) | `pressure-valve,reactor-sync` | `pressure-valve` |

*Stations marked "see note" have no registered task in their Target
list yet. Until one is registered, tag them with the closest registered
stand-in: `pressure-valve` for Tap/Hold stations, `fuse-rewire` for Drag,
`code-playback` for Sequence/Aim. Put the real Target list in a comment
on the part.* The same rule applies to all four maps.

Split: 10 ground floor, 6 upper floor. The courtyard has 2 (`sch-14`,
`sch-16`) so the cut-through route leads somewhere as well as through.

### Power-ups (12)

- **Commons (6):** two on Loop A (south and north corridors), two on Loop
  B (east and west galleries), one at each end of the courtyard
  cut-through.
- **Uncommons (4):**
  - the fire-escape landing (east);
  - the library terrace top;
  - in the gym on the far side from the doors;
  - the courtyard gate, set with `AllowedPowerUpIds = "slow-field"` to
    arm the cut-through choke.
- **Rares (2):**
  - the **centre of the courtyard**, fully exposed to the upper gallery;
  - the **gym stage** at the back of the gym, a 3–4 s detour.

### Sightlines

- The **upper gallery overlooks the courtyard** and, through the
  classroom windows, 9 of the ground-floor stations. This is School's
  main sightline.
- The **main corridor** runs the full 200 studs along the south wing.
  At ~120 studs, the practical limit, doors break it into readable
  sections.
- **Library terrace:** looks down the courtyard ramp. You can see who is
  coming up behind you.

### Choke points (3)

1. **Courtyard gate** (south), 10 wide. The alternative is the entrance
   hall, +3 s.
2. **Top of the courtyard ramp.** The alternative is the back stair, +3 s.
3. **Cafeteria serving-line doorway**, the north wing's middle. The
   alternative is the courtyard, +2 s.

The main SW stair is deliberately **not** a choke. It is 14 studs wide,
because it is the first vertical link most new players find.

### NavNodes (~30)

- 16 station nodes and 12 pad nodes. Some are shared where a pad sits on
  a junction.
- 8 ring corners (4 ground, 4 upper).
- 8 stair ends (4 links × top and bottom).
- 2 nodes at the courtyard gate and 2 at the ramp.
- The courtyard cut-through gets its own chain, so bots use it as well as
  the ring.

### Decision Studio

The **auditorium stage**, behind the gym, sealed by a fire curtain
during the race. The podium slots sit on the stage and the spectator
perimeter is the front seating rows. It works as a reveal space, with
spotlights and a curtain.

### Asset-pack categories

1. **School interior:** desks, lockers, blackboards, lab benches, cafeteria
   tables.
2. **Signage and educational clutter** for the walls: posters, trophy
   cases, noticeboards, flags.
3. **Campus exterior:** brick building shell, clock tower, fencing, bike
   racks, courtyard trees.

### Map-specific gray-box proofs

- The courtyard cut-through is chosen **sometimes but not always** across
  5 NPC rounds. If every bot takes it, the ring is too long. If none
  does, the courtyard stations are not pulling players in.
- New testers find the second floor within their first 2 legs without
  being told. If they don't, the SW stair isn't visible enough from the
  entrance hall.

---

## 3. Factory

> Working heavy industry: a live production line, catwalks overhead and a
> loading yard outside.

**Concept.** The loudest and most mechanical map. Its identity comes from
**a production line that splits the floor in two**, so every crossing is
a decision.

### Footprint and verticality

- **~280 × 220 studs.**
  - The factory floor is ~200 × 140 under one roof.
  - A loading yard (~80 × 220) runs along the east side.
- **2 levels:** the floor, plus a **catwalk ring ~18 studs up** around
  the inside walls, with one catwalk span crossing over the line.
- **Hero landmark:** a **chimney stack** rising from the furnace (NW),
  visible through the skylights and from anywhere in the yard.
- **Zone landmarks:**
  - furnace: orange glow and a tall hood;
  - **gantry crane** spanning the south bay;
  - paint booth: a sealed glass box;
  - control room: a raised glass box on stilts.
- **Vertical links (4):** stairs at the NW and SE corners, a ladder-style
  stair at the NE corner (normal stairs, just styled as a ladder), and a
  ramp from the yard up to the dock platform.

### Flow

```
      [Furnace/Chimney]         [Control room, raised]
   +-----------------------------------------+-----------+
   | F1                 NORTH HALF         F2 |  YARD     |
   |                                          |  Y1       |
   |  bridge-W ====== PRODUCTION LINE ====== bridge-E  |
   |          tunnel-mid (under line)         |  Y2       |
   | F3                 SOUTH HALF         F4 |           |
   | [Gantry crane bay]        [Paint booth]  | dock ramp |
   +-----------------------------------------+-----------+
      catwalk ring above the whole floor; one span over the line
                         [SPAWN: SW, staff entrance]
```

- **Line crossings (3 on the floor + 1 above):** the west bridge, the east
  bridge, a tunnel under the middle of the line, and the catwalk span
  over it. This is where the 2-route rule gets its variety: every
  north–south leg can pick one of 4 crossings.
- **Catwalk ring:** a longer route, but it overlooks the whole floor.
- **Yard loop:** out through the big dock doors, along the yard and back
  in through the side door. The long route, with the fewest people on it.
- **Spawn:** the staff entrance (SW), with two exits: onto the south half
  of the floor, and up the SW-adjacent stair to the catwalk.

### Task stations (16)

| StationId | Location | Target `AcceptedTaskIds` | Tag today |
|---|---|---|---|
| `fac-01` | Furnace control | `reactor-sync,pressure-valve` | `pressure-valve` |
| `fac-02` | Boiler manifold (NW) | `pressure-valve,vent-purge` | `pressure-valve,vent-purge` |
| `fac-03` | Line start, sorting gate | `conveyor-sort,breaker-sequence` | — note |
| `fac-04` | Line end, QA scanner | `sensor-sweep,conveyor-sort` | — note |
| `fac-05` | Robot arm cell | `turret-calibration,code-playback` | `code-playback` |
| `fac-06` | Paint booth extractor | `vent-purge,airlock-cycle` | `vent-purge` |
| `fac-07` | Paint booth airlock door | `airlock-cycle,pressure-valve` | `pressure-valve` |
| `fac-08` | Gantry crane controls | `crate-winch,alarm-killswitch` | — note |
| `fac-09` | Tool cage | `lock-tumbler,cable-splice` | — note |
| `fac-10` | Main distribution board | `breaker-sequence,fuse-rewire` | `fuse-rewire` |
| `fac-11` | Control room console (raised) | `code-playback,breaker-sequence` | `code-playback` |
| `fac-12` | Catwalk junction box (over line) | `cable-splice,fuse-rewire` | `fuse-rewire` |
| `fac-13` | Dock crate winch (yard) | `crate-winch,conveyor-sort` | — note |
| `fac-14` | Yard generator | `fuse-rewire,reactor-sync` | `fuse-rewire` |
| `fac-15` | Foreman's radio shack (yard) | `morse-relay,code-playback` | `code-playback` |
| `fac-16` | Emergency stop post (floor centre) | `alarm-killswitch,breaker-sequence` | — note |

Split:
- 5 north half, 5 south half, 3 raised (catwalk and control room),
  3 yard.
- Every leg between halves forces a line crossing, which is what the map
  is built around.

### Power-ups (12)

- **Commons (6):** one at the approach to each of the 3 floor crossings on
  the south side, one on the north side of the tunnel, and two in the
  yard.
- **Uncommons (4):**
  - two on the catwalk ring, at opposite corners;
  - the control room steps;
  - the dock platform, set with `AllowedPowerUpIds = "push-trip"`.
- **Rares (2):**
  - the **middle of the catwalk span over the line**, exposed from the
    entire floor;
  - the **far end of the yard**, the longest detour on the map.

### Sightlines

- The **catwalk ring sees the whole floor.** Of every map, this is the
  strongest "I can see who is about to beat me".
- The **raised control room** looks both ways along the line.
- The floor itself is broken up by machines, so sightlines at ground level
  are deliberately short. Being on the floor is fast; being high up
  shows you the race.

### Choke points (3)

1. **Tunnel under the line**, 10 wide and 30 long. The alternatives are
   either bridge, +2–3 s.
2. **East bridge**, 10 wide. The alternatives are the tunnel or the west
   bridge.
3. **Dock doors**, the only floor-to-yard opening on the east side apart
   from the side door. The alternative is the side door, +3 s.

The catwalk span is **not** a choke. It is 12 wide and railed, and it is
a sightline and a Rare location, not a bottleneck.

### NavNodes (~32)

- 16 station nodes and 12 pad nodes, with some shared.
- 8 nodes are the 4 crossings × each side.
- 8 stair ends.
- 4 nodes carry the yard loop.

Every north–south pair must have graph paths through **at least two**
crossings. Otherwise bots will all queue at one.

### Decision Studio

The **test bay**: a sealed shed behind the paint booth with a
turntable-style podium under hanging work lights. Spectators stand
behind the safety line painted around the boundary.

### Asset-pack categories

1. **Industrial machinery:** presses, robot arms, furnaces, boilers,
   conveyors used as static decoration.
2. **Structural metalwork:** catwalks, railings, stairs, gantry crane,
   pipes and ducting for the walls and ceilings.
3. **Logistics clutter:** crates, pallets, barrels, forklifts, containers
   for the yard and dock.

### Map-specific gray-box proofs

- **Crossing usage is spread out.** Across 5 NPC rounds, no single
  crossing takes more than ~40% of north–south traffic.
- **The line reads as a barrier at phone field of view.** A tester never
  tries to walk through the line, because it is visibly solid.
- **Static decorative conveyors stay non-carrying.** Stand on one and
  check `MovementWatch` flags nothing. Then delete any that the asset
  pack shipped with a script or with velocity set
  (`scripts/sanitise-pack.luau` catches the scripts).

---

## 4. Museum

> A grand natural-history-and-everything museum with a rotunda at its
> heart.

**Concept.** The **hub-and-ring** map. The central rotunda is the
obvious fast route between any two galleries, and it is also where
everyone can see you. The gallery ring around it is safer and longer.
The map's rhythm comes from that trade-off.

### Footprint and verticality

- **~260 × 260 studs**, the squarest map.
  - A **circular rotunda (~70 studs across)** sits in the centre, under a
    dome.
  - Four galleries surround it: **Egypt (N), Space (E), Natural History
    (S), Modern Art (W)**.
  - Each gallery connects both to the rotunda and to its two neighbours,
    through corner rooms.
- **2 floors:**
  - the ground floor holds the galleries;
  - the upper floor holds a **balcony ring inside the dome** plus four
    upper corner rooms.
- **Hero landmark:** a **dinosaur skeleton** under the dome. It is an
  unmistakable silhouette, tall enough to be seen from every gallery
  doorway.
- **Zone landmarks:**
  - Egypt: pyramid entrance;
  - Space: hanging rocket;
  - Natural History: a whale skeleton on the ceiling;
  - Modern Art: a giant abstract sculpture with an angular silhouette.
- **Vertical links (4):** two **grand staircases** that curve up the
  inside of the rotunda (N and S), plus back stairs in the NE and SW
  corner rooms.

### Flow

```
            [Egypt N]
     NW +-------------+ NE (back stair)
        |    \   /    |
 [Modern|   ROTUNDA   |Space E]
  Art W]|  (dino, dome,|
        |  balcony    |
        |  ring above)|
     SW +-------------+ SE
   (back stair)  [Natural History S]
            [SPAWN: main steps, S]
```

- **Hub route:** gallery → rotunda → gallery. Short, and exposed from the
  balcony ring overhead.
- **Ring route:** gallery → corner room → gallery. About 25% longer, and
  enclosed.
- **Balcony ring:** upper floor. A third route and the sightline loop.
- **Spawn:** the main entrance steps (S), with two exits: into Natural
  History (ring) and through the lobby straight into the rotunda (hub).

This is the map where "never one dominant route" is most at risk. The
hub will look dominant, and it stays viable only because **griefing it
costs so little**. The gray-box has to show that the ring gets used (see
proofs).

### Task stations (16)

| StationId | Location | Target `AcceptedTaskIds` | Tag today |
|---|---|---|---|
| `mus-01` | Egypt, sarcophagus display case | `lock-tumbler,code-playback` | `code-playback` |
| `mus-02` | Egypt, tomb fumigation vent | `vent-purge,pressure-valve` | `vent-purge,pressure-valve` |
| `mus-03` | Space, planetarium projector | `turret-calibration,reactor-sync` | — note |
| `mus-04` | Space, orrery | `reactor-sync,airlock-cycle` | — note |
| `mus-05` | Space, capsule hatch exhibit | `airlock-cycle,pressure-valve` | `pressure-valve` |
| `mus-06` | Natural History, laser security grid | `sensor-sweep,alarm-killswitch` | — note |
| `mus-07` | Natural History, specimen hoist | `crate-winch,conveyor-sort` | — note |
| `mus-08` | Modern Art, interactive light piece | `fuse-rewire,cable-splice` | `fuse-rewire` |
| `mus-09` | Modern Art, alarm panel | `alarm-killswitch,breaker-sequence` | — note |
| `mus-10` | Rotunda, climate-control column | `pressure-valve,vent-purge` | `pressure-valve,vent-purge` |
| `mus-11` | NE corner room, telegraph exhibit | `morse-relay,code-playback` | `code-playback` |
| `mus-12` | SW corner room, archive sorting | `conveyor-sort,lock-tumbler` | — note |
| `mus-13` | Upper NW, security office | `code-playback,sensor-sweep` | `code-playback` |
| `mus-14` | Upper SE, restoration workshop | `cable-splice,fuse-rewire` | `fuse-rewire` |
| `mus-15` | Balcony, dome spotlight rig | `turret-calibration,breaker-sequence` | — note |
| `mus-16` | Lobby, vault keypad | `code-playback,lock-tumbler` | `code-playback` |

Split:
- Galleries hold 9 (2–3 each), corner rooms 2, the rotunda 1, the upper
  floor 3, the lobby 1.
- Only **one** station is in the rotunda itself, so the hub is a route,
  not a destination.

### Power-ups (12)

- **Commons (6):** one in each of the 4 galleries along the ring path, and
  two in the lobby and on the spawn side.
- **Uncommons (4):**
  - the NE and SW corner rooms (the ring route gets the better
    pickups);
  - the tops of both grand staircases.
- **Rares (2):**
  - **at the dinosaur's feet**, dead centre of the rotunda, overlooked
    from the entire balcony;
  - the **upper NE corner room**, the longest detour.

### Sightlines

- The **balcony ring sees the whole rotunda floor** and down into all
  four gallery doorways. That is the fight to control.
- **Long gallery axes** of about 100 studs, from each gallery's far wall
  to the dinosaur, give a view of whoever is crossing the hub.
- The corner rooms are enclosed on purpose. Their safety is paid for by
  the longer route.

### Choke points (3)

1. **Rotunda doorways, N and S**, 12 wide. The alternative is the ring
   through the corner rooms, +3 s.
2. **Top landing of the N grand staircase.** The alternative is the S
   staircase or the NE back stair.
3. **SW corner-room doorway**, 10 wide. The alternative is the rotunda,
   which is faster but exposed.

### NavNodes (~30)

- 16 station nodes and 12 pad nodes, with some shared.
- 4 rotunda doorway nodes.
- 4 corner-room nodes, one per room.
- 8 stair ends.
- 4 balcony-ring nodes.

The graph must hold **both** the hub edges and the ring edges between
every pair of galleries. Without the ring edges, all 5 bots will cross
the rotunda, and the hub will look like the only route.

### Decision Studio

The **special-exhibitions vault**, sealed behind a round vault door off
the lobby. The podium stands on a lit plinth under glass-case-style
lighting, and the spectators stand at the velvet rope. It fits the
"steal" theme best of all four maps: it looks like a heist.

### Asset-pack categories

1. **Exhibits:** skeletons, statues, display cases, artefacts, the rocket
   and capsule, framed art.
2. **Classical architecture:** columns, dome, grand staircases, arches,
   balustrades.
3. **Museum fittings:** benches, velvet ropes, signage, information
   plaques, security cameras.

### Map-specific gray-box proofs

- **The ring is used.** Across 5 NPC rounds and at least 3 human
  playtests, ≥ 30% of gallery-to-gallery legs go via the corner rooms.
  If the hub takes everything, make it longer (a wider rotunda) or add
  risk to it. Do **not** shorten the ring by adding shortcuts.
- **The dinosaur reads in portrait.** From the far end of each gallery,
  the dinosaur is visible and identifiable on a phone.
- **Nobody gets lost in the corner rooms.** They look alike, so each one
  needs a distinct prop silhouette before the art pass, not during it.

---

## 5. Laboratory

> A sunken research facility built around a glowing containment shaft.

**Concept.** The **vertical** map, and the one that looks most like a sci-fi
thriller. Every level wraps around an open shaft with a containment core
inside. The main verb here is looking **up and down**, where the other
maps look across.

### Footprint and verticality

- **~220 × 220 studs**, the smallest footprint. That pays for the extra
  stair travel.
- **2 full levels** plus a **lower reactor gallery**:
  - **Upper level** (entry, offices, comms);
  - **Main level** (labs, specimens);
  - **Reactor gallery** (a ring around the bottom of the shaft,
    ~16 studs below the main level).
- **The shaft:** ~60 studs across, open through all three levels.
  - Every level has a **railed ring walkway** around it.
  - The upper and main levels each have **two railed bridges**
    crossing it (N–S on one level, E–W on the other).
- **Hero landmark:** the **containment core**, a tall glowing cylinder
  rising through the shaft. It is visible from any ring, and its glow
  sets the map's lighting.
- **Zone landmarks:**
  - clean room: a white glass box;
  - specimen bay: tall cryo tanks;
  - comms: a radio mast through the roof;
  - server hall: rows of tall racks.
- **Vertical links (5):**
  - two stairs at opposite corners (NW and SE) linking all three
    levels;
  - a **spiral ramp around the core** inside the shaft, linking the main
    level and the reactor gallery;
  - one stair between the upper and main levels at NE;
  - one between the main level and the reactor gallery at SW.

  Every level change has ≥ 2 links.

### Flow

```
 UPPER:   [Entry/Spawn]---ring---[Comms]        bridge E-W over shaft
               |                    |
 MAIN:    [Clean room]---ring---[Specimen bay]  bridge N-S over shaft
               |      \ spiral /    |
 REACTOR:       [ring around core base]
          stairs NW (all levels), SE (all levels), NE (U-M), SW (M-R)
```

- **Rings:** each level's ring walkway around the shaft is the default
  loop.
- **Bridges:** cross the shaft and cut about 40% off going around.
  Exposed from every ring above and below.
- **Spiral ramp:** a slow but scenic route down to the reactor gallery,
  overlooked the whole way.
- **Spawn:** the entry airlock hall on the upper level, with two exits:
  onto the upper ring, and straight down the NW stair.

### Task stations (16)

| StationId | Location | Target `AcceptedTaskIds` | Tag today |
|---|---|---|---|
| `lab-01` | Upper, entry decon airlock | `airlock-cycle,vent-purge` | `vent-purge` |
| `lab-02` | Upper, comms room | `morse-relay,code-playback` | `code-playback` |
| `lab-03` | Upper, security office | `sensor-sweep,code-playback` | `code-playback` |
| `lab-04` | Upper, director's safe | `lock-tumbler,code-playback` | `code-playback` |
| `lab-05` | Upper, server hall | `cable-splice,breaker-sequence` | — note |
| `lab-06` | Main, clean room airlock | `airlock-cycle,pressure-valve` | `pressure-valve` |
| `lab-07` | Main, clean room fume hood | `vent-purge,reactor-sync` | `vent-purge` |
| `lab-08` | Main, specimen cryo tank | `pressure-valve,reactor-sync` | `pressure-valve` |
| `lab-09` | Main, specimen hoist | `crate-winch,conveyor-sort` | — note |
| `lab-10` | Main, sample sorter | `conveyor-sort,sensor-sweep` | — note |
| `lab-11` | Main, laser optics bench | `turret-calibration,fuse-rewire` | `fuse-rewire` |
| `lab-12` | Main bridge, midspan junction box | `fuse-rewire,cable-splice` | `fuse-rewire` |
| `lab-13` | Reactor, core sync console | `reactor-sync,breaker-sequence` | — note |
| `lab-14` | Reactor, coolant valves | `pressure-valve,vent-purge` | `pressure-valve,vent-purge` |
| `lab-15` | Reactor, containment alarm | `alarm-killswitch,breaker-sequence` | — note |
| `lab-16` | Reactor, power bus | `breaker-sequence,fuse-rewire` | `fuse-rewire` |

Split:
- 5 upper level, 7 main level (including one on a bridge), 4 reactor
  gallery.
- The reactor gallery is the smallest level with the most stations per
  stud, so it is where the race comes together.

### Power-ups (12)

- **Commons (6):** two per level on the rings, spaced opposite each other.
- **Uncommons (4):**
  - two at the ends of the upper bridge;
  - the top of the spiral ramp;
  - the SW stair landing, set with `AllowedPowerUpIds = "slow-field"`.
- **Rares (2):**
  - **midspan on the main-level bridge**, visible from all three rings;
  - the **bottom of the spiral**, at the core's base, the longest descent
    on the map.

### Sightlines

- **The shaft is the sightline.** From any ring you see the rings above
  and below, the bridges, and the spiral. It gives the most complete view
  of the race of any map, and that is why the footprint can stay small.
- **Glass-walled labs** on the main level face the shaft, so a rival at a
  lab station is visible from across it.
- **Railings are glass or thin bar, never solid.** A solid parapet would
  hide exactly what this map is for.

### Choke points (3)

1. **Upper E–W bridge**, 10 wide and 60 long. This is longer than the
   40-stud rule in 1.6 **on purpose**. It is the map's showpiece gamble
   and has to be overlooked on all sides. The alternative is the upper
   ring, +3 s.
2. **Spiral ramp entrance**, main level. The alternative is the SW stair,
   +2 s.
3. **SE stair, main-to-reactor landing.** The alternatives are the SW
   stair or the spiral.

If playtests show the bridge exception is oppressive, split the bridge
with a widened midspan platform before touching anything else.

### NavNodes (~32)

- 16 station nodes and 12 pad nodes, with some shared.
- 4 ring quadrant nodes per level (12).
- 10 stair ends, for 5 links.
- 4 bridge ends.
- 3 nodes along the spiral.

Put the spiral in the graph as a chain, not as one long edge. Pathfinding
around a curve with one straight edge cuts through the core.

### Decision Studio

The **observation chamber**: a sealed dome with a one-way glass window
onto the containment core. The podium slots sit on a raised test
platform, and the spectators stand behind the observation rail. It is
the only Studio that looks back onto its own map's hero landmark.

### Asset-pack categories

1. **Sci-fi lab equipment:** consoles, cryo tanks, fume hoods, optics
   benches, server racks.
2. **Sci-fi structure:** modular walls, glass panels, bridges, railings,
   the shaft and core, airlock doors (static).
3. **Hazard and signage:** warning stripes, hazard decals, pipes, cable
   runs, emissive strip lights.

### Map-specific gray-box proofs

- **Vertical travel stays in budget.** Station pairs on opposite levels
  (upper ↔ reactor) are the worst case, and the longest must still be
  ≤ 25 s. If it isn't, add a third upper-to-reactor link before
  shrinking anything else.
- **Nobody falls into the shaft.** With `push-trip` used on bridges and
  rings, no player leaves the walkway (1.6: all railed). The shaft's
  kill zone must still exist (P7-1 checks for it), but it should never
  fire in normal play.
- **Level is readable at a glance.** A tester dropped on a random level
  can tell which one it is within 2 s. The three levels need different
  ceiling heights and lighting as well as different signs, because a
  sign isn't readable at phone resolution.
- **Emissive and glow cost.** The core and the strip lights are this
  map's identity and its biggest risk to performance. Measure their cost
  in the density placeholder (1.10 item 5) before the art pass relies on
  them.

---

## 6. Follow-ups this document creates

- **`taskStationCount`:** update each wave-1 map config from the
  placeholder `12` to the real built count (16 per this brief) at the
  moment the map is built, as map-kit-spec §2 requires. `enabled` stays
  `false` until the map exists in `ServerStorage.Maps` (the `bed0fbf`
  fix).
- **`slow-field` radius:** it needs a config value (1.6 assumes ≤ 12
  studs). Choke widths depend on it.
- **Streaming radius:** the first built gray-box sets
  `StreamingTargetRadius` for P7-5 (1.10 item 6).
- **Widening `AcceptedTaskIds`:** every "— note" station above is waiting
  for its tasks to be registered. Widening its attribute is a map edit,
  and the P7-1 validator catches any typo.
