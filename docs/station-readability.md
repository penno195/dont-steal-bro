# Station readability (P7-6)

Dense, heavily dressed maps make it hard to find your next station. This
pass solves that in three layers. Each layer does one job, so none of
them has to shout.

| Layer | Job | Where |
|---|---|---|
| World | "It's over there, and that's it", from across a room | `StationMarkerController`, `StationMarkerLogic` |
| Screen | "Turn this way", when the station is behind you or a wall | The race HUD's objective card (P6-3, `race-hud.md`), unchanged |
| State | "Is it free, is it mine, is it done?" | Shared by the world layer; server feed in `StationOccupancy` |

## 1. World layer: shaft, pad, glyph

Every station **on your route** gets a marker. No other station gets
anything. That negative space is the strongest lever here: in a room with
40 props and 3 stations, the only lights rising out of the clutter are
yours.

- **Shaft.** A `Beam` rising `beamHeight` studs (default 12) from the
  floor under the station. It is wide at the base and tapers upward, and
  it fades to fully transparent at the top. With no hard end it reads as
  light, not as a pole or a UI pin. `LightInfluence = 0`, so it holds up
  in dark corners. It is **not** `AlwaysOnTop`: walls hide it like any
  real light, and the HUD arrow covers what the walls hide. Height is
  what makes it read through clutter, because wave-1 dressing goes on
  walls and ceilings, not in walkways (`wave1-briefs.md` §1.9), so a
  shaft that clears ~4 studs rises above everything on the floor.
- **Pad.** A thin Neon disc (6 studs across) on the floor under the
  station. It marks out the station's floor space. It is the only motion
  in the system: a slow breathing tween while the station is waiting
  for you.
- **Glyph.** A small `BillboardGui`, shown only for Rival (👤) and Done
  (✓), and only within 45 studs. It is sized in studs, so it shrinks with
  distance like a sign in the world. It is never a HUD element floating
  across the map.

**Considered and rejected: `Highlight`.** It is the obvious tool, but it
draws an outline pass for every instance (with a hard cap of 31 on
screen), it reads as a UI selection box pasted onto the art, and it
colours the whole prop. That fights the art direction, which is the thing
this pass must not ruin.

**Builder note.** The pad needs a clear floor footprint. Keep roughly a
3-stud radius around a station's floor point free of floor props. This is
already implied by "dressing on walls, not walkways". The pad lands on
the first collidable surface below the anchor, so an anchor above a desk
puts its pad on the desk. That's fine: it still circles the station.

## 2. Screen layer: the objective card

The off-screen indicator already exists. It is the race HUD's objective
card: a compass arrow and a distance, pinned to the top edge in the HUD
row. It is never in the middle of the screen, and it points at your
nearest unfinished station. P7-6 doesn't change it. The world layer is
what makes the arrow's target recognisable when you arrive: follow the
arrow until you see a shaft.

## 3. State: four looks, never colour alone

Every state uses the same map tint, so the states differ in **shape and
motion** (`accessibility.md`). `tests/StationMarkerLogic.spec.luau`
asserts that no two states share a non-colour signature.

| State | Shaft | Pad | Glyph | Reads as |
|---|---|---|---|---|
| **Ready**: on your route, nobody there | Solid | Breathing | none | "Come here" |
| **Rival**: a rival (human or NPC) has an attempt open | **Dashed** | Still | 👤 | "Someone's on it" |
| **Mine**: your attempt is open | Off | Solid, still | none | You're standing in it |
| **Done**: you've completed it | Off | Faint | ✓ | Stops calling you |

Stations never lock, so Rival is information, not a wall: you can still
start the task. It tells a player that the nearest station is contested,
and that's often when a detour to another station pays off.

**Where the state comes from.** Your route and completions come from
`TaskAssignmentState` (targeted, already sent for the HUD). Who's working
where comes from a new server-written attribute on each station anchor,
`Occupants`: a sorted list of participant ids (`shared/StationOccupants.luau`).
`TaskHandlerService` writes it when a human attempt starts and ends, and
`NPCService` writes it when a bot starts and stops working. The client
finds its own id in that list, so it never has to guess whether its own
attempt is counted.

The attribute is display-only. Attributes replicate server-to-client
only, and no server code reads it back. It reveals nothing a player
couldn't already see by looking at who is standing at a station.
`map-kit-spec.md` lists it as reserved.

## 4. Per-map control

`MapDef.stationMarker` (optional; nil = defaults):

```lua
stationMarker = {
	beam = true,        -- the shaft
	pad = true,         -- the floor disc
	beamHeight = 12,    -- 4..14 studs, checked by Validate
	tint = "#RRGGBB",   -- nil = Tokens.color.brand
},
```

`beamHeight` is capped at 14 because wave-1 floors are about 16 studs
apart. A taller shaft pokes up through the floor above and marks a spot
on the upper level where there's no station.

Wave-1 settings:

| Map | Setting | Why |
|---|---|---|
| School | defaults | Bright, neutral lighting. Violet reads against everything. |
| Factory | defaults | Warm orange palette, so violet is the complement. Dense, but the shaft clears the floor clutter. |
| Museum | defaults | Warm-neutral, calm gallery light. |
| Laboratory | `pad = false`, `tint = "#FFB86B"` | The only preset with bloom, and Neon blooms, so pads would glow as a dozen halos around the containment core (the landmark players navigate by). The shaft is warm so it can't be mistaken for the core's cool glow. |

All of these are starting values for the playtest below to confirm.

## 5. Cost

For each marked station (at most `GameConfig.tasksPerPlayer` = 6):

| Instance | Count | Draw |
|---|---|---|
| Part (Neon pad) | 1 | 1 transparent draw, 0 when `pad = false` (transparency 1 is culled) |
| Attachment | 2 | none |
| Beam | 1 | 1 transparent quad, 0 in Mine/Done |
| BillboardGui + label | 0 or 2 | 1 small draw, Rival/Done only, within 45 studs |
| Tween | 0 or 1 | engine-side, Ready only |

That's at most **~24 instances and ~12 transparent draws** a race, and
**no per-frame Lua**. Every change is driven by an event (route update,
attribute change, round state). None of the pieces collide, touch or take
queries, and none of them cast shadows. Only bloom adds real cost, on
Laboratory, and Laboratory turns the pad off.

## 6. Playtest protocol

**Who and how.** 5+ players who have never seen the map, on the
lowest-target Android phone, in portrait. Give them one instruction:
*"Finish your tasks as fast as you can."* Don't explain the markers or the
arrow. Run each wave-1 map. Run a second pass with one tester whose phone
is in greyscale mode (Android Accessibility → Colour correction →
Greyscale).

**Baseline.** A developer who knows the map runs the same route 3 times.
From telemetry, a **leg** is the time between two consecutive
`TaskCompleted` events for a player, minus the second one's
`durationSeconds`. That leaves travel plus searching. Take the
developer's median leg as the baseline.

**What to ask them to do, and what counts as failure:**

| # | Ask / observe | Fails if |
|---|---|---|
| 1 | Play the race (leg times from telemetry) | Median first-timer leg is more than **1.5×** the baseline, or any single leg is more than **3×** it |
| 2 | Watch the screen: count interactions with a station that isn't theirs (the prompt shows, the server refuses) | More than **1 per player per race** on average |
| 3 | Watch for the "lost" moment: turning in place for 3+ seconds, or going back the way they came | More than **1 per player per race** on average |
| 4 | Afterwards, show a screenshot of a dashed shaft and ask: "What did this mean?" | Fewer than **4 in 5** say "someone else is on it" or similar without prompting |
| 5 | Same, for a pad with a tick | Fewer than **4 in 5** say "done" |
| 6 | Greyscale pass: repeat 1–3 | Any threshold above missed that the colour pass met |
| 7 | "Did anything look like it didn't belong in the world?" | 2+ players point at the markers unprompted, which means an art-direction problem even if the numbers pass |
| 8 | MicroProfiler on device, 6 markers visible | Render time is up more than **0.5 ms** against markers off |

If 1 fails but 2–3 pass, players see the stations but can't pick one:
look at the arrow, not the markers. If 2–3 fail, the markers aren't
landing: try per-map `beamHeight` or `tint` before changing the system.
