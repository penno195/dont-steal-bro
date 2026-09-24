# Don't Steal Bro! — Performance Budget & Device Matrix (P0-6)

Every figure in Section 1 is a **starting target**, not a published Roblox
number — Roblox doesn't hand out hard budgets for these, and general
mobile-3D-game practice only gets you an estimate. Each row is marked with
a confidence level; low-confidence numbers must be re-baselined against a
real reference device as soon as the first gray-box map exists (P7-4), not
trusted as-is through production. Section 2's `StreamingEnabled`
properties, by contrast, are verified against Roblox's current official
docs (checked today, not recalled from training data, per `CLAUDE.md`'s
API-caution rule) — those names and defaults are high confidence.

## 1. Hard numbers

| Metric | Target (low-end device) | Confidence |
|---|---|---|
| Total instance count per map | < 12,000 descendants | Low |
| Parts/meshes in view at once | < 2,500 in camera frustum | Low |
| Unique meshes / unique textures resident | < 150 meshes / < 100 textures | Low |
| Draw calls per frame | < 180 | Low |
| Visible triangles per frame | < 300,000 | Low |
| Active particle emitters | < 25 simultaneously emitting | Medium |
| Concurrent sound instances | < 20 playing at once | Medium |
| Client memory ceiling | < 800 MB attributable to the experience | Low |
| Target frame rate | 30 fps sustained floor; 60 fps stretch on mid-tier+ | Medium |

### How to measure each, and what to cut first

**Instance count.** Studio: run `#workspace.Maps:GetDescendants()` (or the
specific map's container) in the command bar — Explorer's tree view isn't
practical to count by eye at this scale. On device: not directly countable
live; treat the Studio count as authoritative and verify indirectly
through the memory ceiling below. **Cut first:** duplicated decorative
instances — consolidate repeated dressing into unions or shared
`MeshPart`s instead of many hand-placed uniques.

**Parts/meshes in view.** Studio: the Stats window's Rendering category,
or the MicroProfiler's `Render` bucket, while standing in the map's
densest sightline. On device: watch for frame drops when panning toward
dense clusters — an empirical check, not a counted one. **Cut first:**
add LOD or occlusion for distant decoration; tighten `StreamingTargetRadius`
(§2) so far geometry isn't resident at all.

**Unique meshes/textures.** Studio: Rendering stats plus a manual audit of
imported assets. **Cut first:** reuse existing meshes instead of importing
near-duplicates from a new asset pack; atlas small repeated textures.

**Draw calls.** Studio and device both: the MicroProfiler's `Render`
bucket shows draw-call count directly — open it with **Ctrl+F6** while
testing, or via the Developer Console (**F9**) → Microprofiler tab; exact
keybind can vary by Studio version, confirm in your own install.
**Cut first:** consolidate materials and `SurfaceAppearance`s — every
unique material on visible geometry is a potential extra draw call.

**Triangle budget.** *(P8-2: `Stats.SceneTriangleCount` and
`Stats.SceneDrawcallCount` give both aggregates directly on the client.
See `perf-report.md` §6 for the snippet; that supersedes the manual
approach below.)* Studio: sum visible `MeshPart` triangle counts for
the current view (mesh info per-part; no single aggregate view is known
to be reliable — verify this against current Studio tooling before
treating it as a workflow). **Cut first:** swap high-poly asset-pack
meshes for decimated versions; this is almost always the actual fix, not
triangle-counting itself.

**Particle emitters / sound instances.** Studio: a short script counting
enabled `ParticleEmitter`s / currently-`Playing` `Sound`s is more reliable
than a visual audit once a map is dense. **Cut first for particles:** cap
simultaneous power-up VFX and prefer short-lived pooled emitters over
always-on ambient ones near task clusters. **Cut first for sound:** pool
and reuse `Sound` instances; drop ambience before gameplay SFX when near
the cap.

**Client memory ceiling.** Studio's Stats window Memory category is a
rough proxy at best — it does not reliably predict on-device memory.
On-device measurement needs either the platform's own tooling (Android
`adb shell dumpsys meminfo`, connected to a real device) or Roblox's own
in-experience device-stats overlay, if enabled in Settings — the exact
menu wording has moved across client versions, so confirm it in the
current client rather than assuming. **Cut first:** texture resolution,
almost always the single biggest line item, then mesh count, then audio.

**Frame rate.** On-device is the only measurement that matters here;
Studio's own frame rate under the editor doesn't reflect device
performance. **Cut whatever the MicroProfiler's dominant bucket says** —
`Render`, `Physics`, `Heartbeat` (your own scripts), or `Replication` —
profile before guessing which system is the actual bottleneck.

**Reference device generation:** "roughly four years old" as of any given
milestone is a rolling target, not a fixed model — at time of writing that
means an entry-level chipset tier (Helio G-series / Snapdragon 4-series
class, 3–4 GB RAM, 720p–1080p display). Pick an actual current exemplar
phone for the device lab each time this budget is re-checked rather than
locking a specific model number into this document.

## 2. `StreamingEnabled` configuration

Verified against Roblox's current streaming documentation
([create.roblox.com/docs/workspace/streaming](https://create.roblox.com/docs/workspace/streaming)).

| Property | Recommendation | Why |
|---|---|---|
| `Workspace.StreamingEnabled` | `true` | Required baseline — the memory ceiling in §1 isn't achievable across 11 dense maps without it. |
| `Workspace.StreamingMinRadius` | Keep the default, `64` | Roblox's own guidance: the default maximizes how much the engine can scale down for low-end devices — no reason to raise it for a 6-player map. |
| `Workspace.StreamingTargetRadius` | Tighten well below the default `1024`: **`256`** as the starting value (P7-5) | A compact 6-player race map doesn't need a 1024-stud buffer. 256 comes from the wave-1 footprints (220–300 studs); re-measure it on the first gray-box. See `lighting-and-streaming.md` §1. |
| `Workspace.ModelStreamingBehavior` | `Improved` over `Legacy` | The newer nonatomic-model streaming behavior; verify the specific differences against current docs before relying on this beyond "prefer the improved one." |
| `Workspace.StreamOutBehavior` | Keep the default, `LowMemory` | Given the tight memory ceiling in §1, unloading proactively is the safer default over `Opportunistic`'s smoother-but-heavier tradeoff — worth an A/B test once there's real telemetry, not a settled decision. |
| `Workspace.StreamingIntegrityMode` | `PauseOutsideLoadedArea` | This is the actual "pause mode" the brief asked for. Matters for more than smoothness here — a player interacting with a `TaskStation` in a not-yet-loaded region is a correctness bug (Ground Rule 1), not just visual pop-in, since the server must never let gameplay proceed against content the client hasn't actually received. |
| `Workspace.PredictiveStreamingMode` | `Enabled` | Reduces stutter for fast, unpredictable movement across a themed map — reasonable default-on, worth A/B testing against battery/CPU cost on the reference low-end device specifically. |

### Per-instance `ModelStreamingMode`, mapped to `map-kit-spec.md`'s tags

> **Superseded by P7-5** (`lighting-and-streaming.md` §2). The server
> always holds the whole map, because streaming only affects clients. So
> only tags that *clients* read need a streaming mode, and today that is
> just `TaskStation`: its anchor is Persistent and its dressing Atomic.
> `MapStreaming.prepare` applies this at load. The rows below that mark
> server-only tags (`NavNode`, `KillZone`, `SpawnPoint`, `Studio*`)
> Persistent would spend client memory for nothing. The table is kept
> for history.

The original P0-6 proposal:

| Tag (from `map-kit-spec.md`) | `ModelStreamingMode` | Why |
|---|---|---|
| `SpawnPoint`, `StudioAnchor`, `StudioPodiumSlot`, `StudioBoundary` | `Persistent` | Small, lightweight, always needed the instant a round transitions state — never a reason to stream these out. |
| `NavNode` | `Persistent` | The NPC pathing graph must be fully available immediately, or NPC fill (Q2) breaks the moment a node streams out from under an in-progress route. |
| `TaskStation`, `PowerUpSpawn` interact anchors | `Persistent` | The interact point itself is tiny; keeping it persistent avoids a player standing on an anchor that hasn't loaded. |
| Large decorative geometry surrounding a `TaskStation` (the furniture/machine model dressing it) | `Atomic` | Too heavy to be `Persistent` everywhere on the map at once, but must load as one indivisible unit — a half-rendered task station reads as a bug, not atmosphere. |
| `KillZone`, `PlayableBounds` | `Persistent` | These back anti-exploit and fall-recovery checks (Ground Rule 1) — they must exist for the whole round regardless of camera distance. |

Everything else (ordinary background dressing with no gameplay tag) stays
on the `Nonatomic` default — that's the entire point of `StreamingEnabled`
paying for itself on a dense map.

## 3. Device test matrix

| Device | What it catches |
|---|---|
| **Reference low-end** (current ~4-year-old entry chipset tier, 3–4 GB RAM) | The actual pass/fail gate for every number in §1 — if this device doesn't hold 30fps and the memory ceiling, nothing else in this matrix matters yet. Required at **every** milestone from the first gray-box map onward; perf regressions compound silently if this isn't checked continuously. |
| **Mid-tier current** (2–3 year old mid-range chipset, 6–8 GB RAM) | Whether the 60fps stretch target lands and whether the game feels good for the likely median player, not just the survivable floor. |
| **Small-screen device** | UI legibility and true one-thumb reachability — directly tests Ground Rule 3, not raw performance. A layout that only works on a 6.7" screen has failed this constraint even if it renders at 60fps. |
| **High-refresh-rate device** (90/120 Hz, common on mid-range Android now) | Whether the game correctly caps to its target rather than assuming 60Hz, and whether round timers and task-timing windows stay consistent across refresh rates — this is the practical test of the architecture rule that every timer derives from a server timestamp, never per-frame state. |
| **Older iOS device** (if shipping iOS, similar ~4-year-old tier) | Cross-platform memory/thermal behavior — Roblox's iOS and Android clients don't necessarily perform identically on comparable hardware, and this is the only way to catch a platform-specific regression before players do. |

The reference low-end device is checked continuously; the other four are
required at each content-wave gate (per the build plan's wave structure)
and before any public playtest or launch milestone — not necessarily on
every individual task.

## Sources checked

- [Instance streaming — Roblox Creator Hub](https://create.roblox.com/docs/workspace/streaming)
- Roblox DevForum threads on `StreamingMinRadius`/`StreamingTargetRadius` behavior and current mobile Developer Console access, checked to confirm the on-device profiling limitations noted above rather than assuming a gesture or shortcut still works.
