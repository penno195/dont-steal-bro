# Lighting & Streaming per Map (P7-5)

This builds on `perf-budget.md` (P0-6) and the wave-1 briefs
(`maps/wave1-briefs.md`). The code is in these files:

| File | Role |
|---|---|
| `src/shared/Config/LightingPresets/*.luau` | One preset per map theme. Adding one = adding a file (Ground Rule 2). |
| `src/shared/Config/Validate.luau` → `checkLightingPreset` | Readability guards; enabled maps must name a registered preset. |
| `src/server/LightingLogic.luau` | Pure: preset → property writes. Tested headlessly. |
| `src/server/Services/LightingService.luau` | `apply(presetId)` on map load, `restore()` on Cleanup. |
| `src/server/MapStreaming.luau` | Per-model streaming modes on a map clone; `streamAround` before spawn/teleport. |

**Verified against current docs (2026-09-24)**, per `CLAUDE.md`'s API
rule:
- Every Workspace streaming property except `StreamingEnabled` is
  **non-scriptable** and has to be set in Studio.
- `Lighting.Technology` is **deprecated and non-scriptable**. It is
  superseded by `LightingStyle` + `PrioritizeLightingQuality`, which
  scripts can write.
- `Player:PinStreamingForInstance` appears in the pinned type
  definitions but has **no public documentation**, so nothing here relies
  on it.

## 1. Place settings: set once in Studio

A script can't set these, so a builder has to. `MapStreaming` warns at
runtime only if `StreamingEnabled` is off, because the other properties
can't be read from a script either.

| Setting | Value | Why |
|---|---|---|
| `Workspace.StreamingEnabled` | `true` | The memory ceiling can't be met across 11 dense maps without it. |
| `StreamingMinRadius` | `64` (default) | Roblox's own guidance. It lets the engine shrink furthest on low-end devices. |
| `StreamingTargetRadius` | **`256`** (starting value) | Wave-1 footprints are 220–300 studs on the longest axis. 256 covers the whole map from its centre and most of it from any corner. Gameplay-critical content doesn't depend on this number (§2), so it can be lowered safely. Re-measure on the first gray-box (briefs §1.10 item 6). |
| `ModelStreamingBehavior` | `Improved` | Per perf-budget §2. |
| `StreamOutBehavior` | `LowMemory` | Per perf-budget §2. |
| `StreamingIntegrityMode` | `PauseOutsideLoadedArea` | A player must never interact with ground the client hasn't received. |
| `Lighting.Technology` | Leave as is | Deprecated; no preset depends on it. |
| `Lighting` children | **No `Atmosphere`, no post effects** | An Atmosphere overrides every preset's fog. A Studio Bloom/ColorCorrection would stack with the preset's own. `LightingService` warns about either at boot. |

## 2. Streaming: what must never stream out

**The rule is who reads the tag, not what the tag is.** The server
always has the entire map, because streaming only controls what reaches
*clients*. This corrects the per-tag table in `perf-budget.md` §2:

- **Server-only tags need nothing.** That covers `NavNode` (NPCs path on
  the server), `KillZone`, `PlayableBounds`, `SpawnPoint` and the four
  `Studio*` tags. Marking them Persistent would cost client memory and
  buy nothing.
- **`TaskStation` is the one tag clients read.** The HUD tracks every
  station map-wide for the nearest-objective arrow, and the station
  controller needs the anchor to launch a task. So `MapStreaming.prepare`,
  run on the clone *before* it is parented:
  - lifts each anchor into its own **Persistent** wrapper model, about
    16 tiny parts per map;
  - sets the station's dressing model to **Atomic**, so it arrives whole
    or not at all.

  Builders don't do any of this (map-kit-spec promises no scripting),
  and every consumer finds stations by tag, never by path.

**Stations at the edge of the radius.** The anchor is always present, so
the arrow and distance checks work anywhere on the map. The dressing
streams in as one Atomic unit once the player is inside the loaded
radius, which is at least 64 studs, well before they reach the 8×8 pad.

**Spawn and Studio teleports.** The server calls
`MapStreaming.streamAround(player, position)`
(`RequestStreamAroundAsync`, 3 s timeout) before it pivots the
character. If the request fails, the only cost is a short pause.

**Outrunning the stream.** Under `PauseOutsideLoadedArea`, the client
freezes with Roblox's loading indicator until the region arrives, then
play resumes. The player never falls through missing floor. At 16
studs/s against a 256-stud radius this should only happen on a device
under memory pressure that has shrunk towards the 64-stud minimum. If
playtests show pauses, lower `StreamingTargetRadius` rather than raise
it: a smaller radius means less memory pressure, so the engine is less
likely to fall to the minimum.

## 3. Lighting presets

Each preset sets **every** Lighting property in
`LightingLogic.LIGHTING_PROPERTIES`, so no value from the previous map
can carry over. Post effects are created by `LightingService` and
destroyed on restore; they are never edited in place.

**Readability guards** (`Validate.luau`) are design limits, stricter than
the engine's:
- fog starts ≥ 120 studs, the longest designed sightline (briefs §1.5);
- the brightest ambient channel is ≥ 64, so a shaded station is never
  black;
- colour grading stays within ±0.3;
- bloom threshold is ≥ 1, so only Neon and light sources bloom.

| Preset | Style | Shadows | Fog (start→end) | Colour correction | Bloom |
|---|---|---|---|---|---|
| School | Soft, 14:00 | on | 400→2000 (horizon) | none | none |
| Factory | Realistic, 16:30 | on | 150→700 (dust haze) | warm tint, +0.1 contrast | none |
| Museum | Soft, 12:00 | on | 500→2500 (horizon) | none | none |
| Laboratory | Realistic, 00:00 | **off** | 140→500 (shaft depth) | cool tint, +0.15 contrast | **on** (0.4, threshold 1.2) |

### Cost of each effect on mobile

These are relative costs from how each effect renders. **They have not
been measured on a device**, so treat them with the same confidence as
perf-budget §1.

| Effect | Relative cost | Where it's used |
|---|---|---|
| Fog | ~free: a blend in shading that already runs | Everywhere. Theme at no cost. |
| Ambient / OutdoorAmbient / env scales | ~free: shading terms, no extra pass | Everywhere. |
| `GlobalShadows` | **High**: an extra pass over shadow-casting geometry, which counts against the 180 draw-call budget | School, Factory, Museum each earn it through depth (courtyard, catwalks, dome light pool). The Lab is underground, so the sun adds nothing and shadows are dropped. |
| ColorCorrection | Low: one full-screen pass | Factory, Lab only, where the tint carries the theme. School and Museum gain nothing from it and drop it. |
| Bloom | **Highest post effect**: several full-screen blur passes | Lab only. The glowing core is the hero landmark players navigate by. Factory's furnace uses Neon + a PointLight instead. |
| Atmosphere | Medium; also overrides fog | Not used. |

## 4. The two settings most likely to break the budget on low-end Android

1. **`StreamingTargetRadius`.** At 256 it can keep nearly a whole dense
   map's dressing resident, which pushes the 800 MB memory ceiling and
   the draw-call budget together. Gameplay doesn't depend on it (§2), so
   it is the safest large cut. **First cut if memory is the problem:
   drop to 192.**
2. **`GlobalShadows` on Factory.** Factory is the densest map, with the
   most shadow casters under one roof. The shadow pass is the biggest
   per-frame lighting cost. **First cut if frame rate is the problem:
   turn Factory's shadows off.** Then Lab bloom, then School/Museum
   shadows.

Profile before cutting (perf-budget §1: cut what the MicroProfiler's
dominant bucket says). The list above is the order to try when that
bucket is `Render`.

## 5. Follow-ups

- **The real map loader** (it doesn't exist yet; `StudioTestService` is
  the stand-in) must:
  - call `MapStreaming.prepare(clone)` before parenting the map;
  - call `LightingService.apply(def.lightingPreset)`;
  - call `streamAround` before the Decision Studio teleport.

  `LightingService` restores the lighting on Cleanup by itself.
- **Wave 2/3 maps** keep placeholder preset names. They get a preset
  file when they're built; the validator only requires one once
  `enabled = true`.
- **Re-baseline** the radius and the cost column on the reference device
  once the first gray-box exists.
