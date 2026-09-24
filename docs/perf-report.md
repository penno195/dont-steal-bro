# Performance Report & Profiling Protocol (P8-2)

This covers the whole codebase as of P8-1. It gives prioritised findings
(§1), the two fixes already made (§2), the network (§3) and memory (§4)
analyses, the rendering cuts in order (§5), and the profiling protocol to
repeat at every milestone (§6). The budget targets it measures against are
in `perf-budget.md`.

**Premise correction.** The brief asks for proof that "a server can run 50
consecutive rounds without growth". A match server can't run two rounds:
`RoundService` makes Cleanup terminal (see `StudioTestService.luau`'s
header and `architecture.md`). The servers that actually live long are:

- the **hub**, where players leave for matches and come back, votes run,
  and leaderboards refresh for hours;
- the **practice area** on the hub, where `PowerUpService.startPickups`
  runs once at boot and pickups respawn for the rest of the server's life.

So §4 proves no growth across **50 hub player cycles plus continuous
practice respawns**. Per-round services are also checked, via Studio's
`RoundService.debugReplayState` replay, which is the only way to put one
server through repeated Race states.

**What is and isn't measured.** Nothing in this report was measured on a
device. There is no gray-box map with real geometry yet (P7-4 wrote the
briefs). The findings come from a static read of the code, and the gains
are estimates. §6 is the procedure that turns them into numbers.

## 1. Prioritised findings

Gain is the estimated effect on the low-end reference device. Cost is
implementation effort. ✅ = done in this pass.

| # | Finding | Area | Gain | Cost |
|---|---|---|---|---|
| 1 | Power-up pickups created and destroyed on every claim and respawn, unbounded on the practice area | Instance churn, network | Medium | Low ✅ |
| 2 | Vote board rebuilt up to 6 avatar labels + corners per card every second | Instance churn (client) | Low–Medium | Low ✅ |
| 3 | `Workspace.PlayerCharacterDestroyBehavior` not confirmed `Enabled`: Player/Character instances, and every connection on them, may outlive a leaving player on the hub | Memory | High on hub (long-lived) | Studio setting |
| 4 | Vote board is re-sent every second even when nothing changed | Network | Low | Low |
| 5 | `PressureValve` animates its gauge with a per-frame Lua loop | Script | Low | Low |
| 6 | `LeaderboardService.lastWrittenBest` gains one entry per player who ever writes a streak, and is never pruned | Memory | Very low | Trivial |
| 7 | Station glyph `BillboardGui` rebuilt on each marker state change | Instance churn (client) | Very low | Low |

Items 4–7 aren't worth doing before the first on-device profile says
otherwise. Item 3 is a single property check in Studio and should happen
now. It is **not scriptable**: the pinned `globalTypes.d.luau` declares
the `EnumPlayerCharacterDestroyBehavior` enum, but no script-visible
`Workspace` member uses it. So it is set in the place file, like the
streaming properties in `lighting-and-streaming.md`. Confirm the property
name and its `Enabled` value in Studio's Properties panel before relying
on it.

### Checked and found clean

- **No server per-frame work.** No service connects to `Heartbeat`,
  `Stepped` or `RenderStepped`. Every server loop is a `task.wait`
  interval loop (MovementWatch, NPCBrain, NPCService, PracticeService,
  VoteService, MatchmakingService, LeaderboardService).
- **Client per-frame work is already quantised.** Vide's `source` skips
  equal primitive writes (verified in
  `Packages/_Index/centau_vide@0.4.1/vide/src/source.luau`), and each
  `Heartbeat` driver writes a stepped value:
  - RaceHUD clock: 0.1 s
  - Results: 0.1 s
  - TaskViewBase elapsed: whole seconds
  - Results reveal: 0.25 s
  - Decision hold fraction: written only while the choice is held,
    otherwise a constant 0

  The nametag first-person check polls at 5 Hz, not per frame. The
  objective arrow is the one `RenderStepped` user, and it needs the
  camera. It re-searches stations on an interval and dedupes its writes.
- **UI lists reuse rows.** Every dynamic list is keyed through Vide's
  `indexes`/`values` (RaceHUD tasks and effects, DecisionStudio seats and
  payoff rows, Results, Leaderboards, Store, Toast), not rebuilt from a
  `derive`. One caveat: a source holding a **non-frozen table**
  propagates on every write, even an identical one. Keep store tables
  frozen or replace them only on real change.
- **Connections are scoped.** Every server `:Connect` is either a
  service-lifetime connection made at init, or made on a Player or
  Character (see finding 3). The pickup `Touched` connection used to be
  per spawn, but is now per part (§2).
- **Lighting and cosmetics were already costed.** P7-5 set shadows and
  bloom per preset. Cosmetic particle emitters run at `Rate = 6`.

## 2. Implemented

### 2.1 Pickup reuse — `PowerUpService.luau`

**Before:** each spawn was `Instance.new("Part")` plus a new `Touched`
connection, and each claim was a `:Destroy()`. On the server, that
replicates a full instance create and destroy to every client each
time.

**Now:** `pickupParts` holds **one part per spawn point** for as long as
that point exists:

- `spawnAt` shows it: `Transparency = 0`, `CanTouch` and `CanQuery` on.
- `hideLivePickup` hides it again with all three reversed, so a hidden
  pickup can't be claimed or raycast.
- `Touched` is connected once, and reads `livePickups[point]` at touch
  time.
- `startPickups` destroys parts whose spawn point is no longer in the
  set, so a new map or the practice area doesn't leave orphans.

**Why not a conventional pool** (unparent and reuse): a server part
leaving and re-entering Workspace replicates as a full destroy and
create, which saves nothing. A property toggle sends only the changed
fields.

**Invariants kept:**

- The claim path is unchanged apart from the rename: the P8-1
  reach re-check and `live.claimed` guard are untouched.
- No client reads pickup parts. `grep PowerUpPickup src` finds only this
  service.
- The part name still carries the def id.

### 2.2 Vote board avatar slots — `VoteBoardController.luau`

`buildCard` now creates `MAX_AVATARS` avatar `ImageLabel`s once, hidden.
`renderVotes` toggles `Visible` and writes `Image` only when it changed.
The `UIListLayout` skips hidden children, so visible faces still pack to
the left. Before this, each one-second board send destroyed and recreated
every avatar and its `UICorner`, and re-assigned thumbnails, which could
flicker.

### 2.3 Tests

Both changes are instance lifecycle code, and there's no pure logic to
extract, so neither is headlessly testable under Lune. The existing
suite still passes (972/972), along with `luau-lsp analyze`, `selene`
and `stylua --check` on the changed files. The behavioural check is
Studio scenario S5 in §6: claim-and-respawn on the practice area with
`Stats.InstanceCount` watched.

## 3. Network

- **Countdowns derive from a shared clock, confirmed.** Every timed
  broadcast carries an absolute deadline, not a tick:
  - `RoundState { state, endsAt }`
  - `DecisionPhaseChanged { phase, endsAt }`

  Clients compute remaining time from `Clock.now()`. No remote fires
  per second to drive a timer.
- **Event-driven broadcasts only.** These fire on a real event:
  - `TaskProgress` and `TaskQualificationResult`
  - `StatusEffectsVisual`
  - the Decision events
  - `NPCRoster`
  - `NPCChatBubble`, throttled by NPCBrain's interval
  - `TitleState`
  - `LeaderboardState` and `PeriodBoardState`, on the leaderboard's
    jittered refresh

  `TaskProgress` sends the whole progress table. At 6 racers that is a
  few hundred bytes per completion, not worth a delta scheme.
- **Replicated property churn is negligible.** Server-side `SetAttribute`
  appears only in CosmeticService (on equip) and StationOccupancy.
- **The one periodic send** is VoteService's `sendBoard` each
  `pollSeconds` (1 s) during a vote, whether or not the counts changed
  (finding 4). The fix: send only when the record's counts or voters
  differ from the last send, and let the client run its own timer from
  the vote deadline.
- **Could the client derive anything it's sent?** Nothing material.
  Station positions, map defs and power-up defs already come from
  replicated config or the map, not remotes.

## 4. Memory across long-lived servers

### Per-player state: cleared on `PlayerRemoving`

These services all clear their per-player tables in a `PlayerRemoving`
handler:

- DataService, NetGuard, MovementWatch, MatchmakingService,
  MatchTeleportService
- ParticipantService, RoundService, PowerUpService, StatusEffects
- TaskHandlerService, TitleService, VoteService, StoreService
- CosmeticService

### Per-round state: reset at the start of each round

- **PowerUpService:** `startPickups` resets live pickups, respawn
  timers and `racerStates`, and now prunes stale parts.
- **TaskHandlerService:** has the same idempotent reset, for Studio
  replay.

### What can still grow, and its bound

| Source | Bound | Action |
|---|---|---|
| Player/Character instances + their connections (ParticipantService, StatusEffects, CosmeticService connect on `CharacterAdded` and `Died`) | Unbounded on the hub unless the engine destroys them on leave | Finding 3: enable the destroy behaviour, then verify with S6 |
| `LeaderboardService.lastWrittenBest` | One number per streak-writer, for server life | Finding 6: clear on `PlayerRemoving` (a returning player just rewrites once) |
| `LeaderboardService.nameCache` | Users who have appeared on a board. Entries are TTL-refreshed, never removed | Acceptable: board membership is small |
| `VoteBoardController.avatarCache` (client) | Users that client has seen vote | Acceptable: tens of strings per session |

### The claim

With finding 3 applied, a hub server's growth over 50 player cycles
should be flat within noise. Nothing else keyed by player or by round
survives the player or the round. S6 in §6 is the procedure that
confirms this.

## 5. Rendering: what to cut first on mobile

Ranked by likely cost on a fill-rate-bound, low-end GPU. Cut from the
top, and only after §6 shows `Render` as the dominant MicroProfiler
bucket.

1. **Global shadows.** They're on in 3 of the 4 presets (Factory,
   Museum, School). `Stats.ShadowsDrawcallCount` shows their draw calls
   separately from the scene's, so S4 measures the cost directly
   rather than guessing it. Setting a preset's
   `globalShadows = false` is a one-line change per map config.
2. **Full-screen translucent UI.** This covers the status-effect
   screen-edge overlays, the full-bleed `RaceHUDEdges` layer, and modal
   scrims. Anything translucent that spans the screen is overdraw on
   every pixel it covers. Where an edge treatment is built as a
   full-screen gradient, thin strips along the edges do the same job
   for far fewer pixels.
3. **Bloom.** Where a preset defines it (`bloom` in the lighting
   config), it adds a full-screen post pass.
4. **Station beams.** One additive `Beam` per station, so it's overdraw
   at every station in view. Hide beams beyond glyph distance.
5. **Other players' cosmetic trails.** Six trails at once. Show only
   your own on the lowest quality level.
6. **Neon pickups.** Cheap alone, but they feed bloom. Irrelevant once
   bloom is cut.

## 6. Profiling protocol

Repeat this at **every milestone**, in this order, and record the numbers
in the table at the end. Server-side soak checks come first because they
need no device. Device numbers come last because they are the gate.

### Tools

- **Studio command bar:** the snippets below.
- **Studio MicroProfiler:** Ctrl+F6, or View → MicroProfiler. The
  keybind can vary by Studio version.
- **On the device:** the Developer Console. On mobile, it opens from the
  in-experience menu or the `/console` chat command; confirm the current
  path in the live client, because it has moved before. Its
  MicroProfiler, Memory and Network tabs are the source of truth.
- **Android memory:** `adb shell dumpsys meminfo com.roblox.client`
  (or the current package name) as an outside check on the in-game
  Memory tab.

### Snippets

These use `Stats` members verified in the pinned `globalTypes.d.luau`.
Run them in the command bar, or in a temporary LocalScript for
client-only fields.

```lua
-- Server or client: one sample line.
local S = game:GetService("Stats")
print(string.format(
	"mem %.1fMB lua %.1fMB signals %.1fMB instances %.2fMB inst# %d recv %.1fkbps",
	S:GetTotalMemoryUsageMb(),
	S:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.LuaHeap),
	S:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.Signals),
	S:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.Instances),
	S.InstanceCount, S.DataReceiveKbps))
```

```lua
-- Client only (render stats are 0 on the server): one sample line.
local S = game:GetService("Stats")
print(string.format(
	"draws scene %d shadow %d ui %d | tris scene %d | frame %.1fms cpu %.1fms gpu %.1fms",
	S.SceneDrawcallCount, S.ShadowsDrawcallCount, S.UI2DDrawcallCount,
	S.SceneTriangleCount, S.FrameTime * 1000,
	S.RenderCPUFrameTime * 1000, S.RenderGPUFrameTime * 1000))
```

Check the units before trusting them. The pinned types give no units:
`FrameTime` is assumed to be in seconds, hence `* 1000`. If the printed
numbers are implausible, compare against the MicroProfiler once and
correct the snippet.

`SceneTriangleCount` is the aggregate triangle count that `perf-budget.md`
said wasn't known to exist. It does exist, so use it for the 300k row.

### Scenarios, in order

| # | Where | Setup | Record |
|---|---|---|---|
| S1 | Studio, server | Start a local server with 2 players. Take a sample, idle 60 s, take another | Baseline memory and instance count |
| S2 | Studio, server | Studio test round (`StudioTestService`) to Cleanup | Peak `DataSendKbps` during Race. It should stay flat with no per-second spikes (§3) |
| S3 | Studio, server | `RoundService.debugReplayState` Race × 50 on one session, sampling after each | Instance count and `LuaHeap`: flat after round 2 |
| S4 | Studio, client | Stand in the densest sightline of each gray-box map | Draw calls, shadow draw calls, triangles against the budget |
| S5 | Studio, server | Practice area: claim the same pickup 50 times | `InstanceCount` unchanged across claims (verifies §2.1) |
| S6 | Studio, Team Test or local server | 50 join/leave cycles: a local server with 2–3 clients, leaving and rejoining | `Signals` and `Instances` memory: flat within ~1 MB after cycle 5 (verifies finding 3) |
| S7 | **Device**, low-end reference | Full 6-player round with NPC fill, on a gray-box map | MicroProfiler dominant bucket at the busiest moment (power-ups flying, 2+ status effects). Frame time p50 and worst over 60 s. Memory tab total |
| S8 | **Device**, low-end | Decision Studio through the reveal | Frame time during the reveal sequence, the one moment that must not hitch |
| S9 | **Device**, low-end | 10 minutes in the hub, then 10 minutes in practice | Memory at 0, 5 and 10 minutes, and `dumpsys meminfo` at the end: no upward trend |

### Pass criteria

These are the gates in `perf-budget.md` §1:

- 30 fps sustained floor in S7 and S8
- draw calls < 180 and triangles < 300k in S4
- client memory < 800 MB in S9
- no upward trend in S3, S5, S6 and S9

A failure goes to the MicroProfiler's dominant bucket first, then to the
relevant §5 cut.

### Recording template

Copy this per milestone into this file's history section, or the
milestone's issue.

```
Milestone:            Date:            Build (commit):
Device (model/chip/RAM):
S1 mem/inst:          S2 peak send kbps:
S3 inst r2 → r50:     LuaHeap r2 → r50:
S4 map: draws/shadow draws/tris (one line per map)
S5 inst before/after 50 claims:
S6 Signals/Instances c5 → c50:
S7 fps p50/worst, dominant bucket, memory:
S8 reveal frame time worst:
S9 memory 0/5/10 min, dumpsys PSS:
Notes / regressions vs last milestone:
```

## History

No device measurements yet. The first row is due at the first gray-box
map (P7-4).
