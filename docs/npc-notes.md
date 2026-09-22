# NPC fill — cost, fairness and the Studio checklist (P3-5)

Companion to `src/server/Services/NPCService.luau` (the implementation —
its own header comment is the canonical version of the design) and
`src/server/NPCLogic.luau` (the fairness and routing math, unit-tested in
`tests/NPCLogic.spec.luau`). This document answers the two questions the
task itself asked for — *what do 5 NPCs actually cost a server, and which
knob do I turn first*, and *where can NPC presence distort the streak
leaderboard* — plus the Studio checklist, because none of this has been
run against a real map yet.

## Everything is estimated, nothing is measured

Every number below is **derived from the code and the config, not
measured on a real server.** No map exists to run bots on yet (maps are
hand-built in Studio and this repo has none — CLAUDE.md), so there is no
MicroProfiler trace to quote. They are here so there's something
falsifiable to check the first trace against, in the same spirit
`perf-budget.md` and `threat-model.md` treat their own unverified
figures. Re-measure before trusting any of it.

The worst case throughout is **5 NPCs**, which is a one-human lobby —
`GameConfig.playerCount` (6) minus one.

## 1. What 5 NPCs cost per server

### Instances

The code-built fallback rig is 7 instances: `Model`, `HumanoidRootPart`,
`Torso`, `Head`, two `WeldConstraint`s, `Humanoid`. Five of them is **35
instances**, plus one `Workspace.NPCs` folder.

Against `perf-budget.md`'s "< 12,000 descendants per map" that is
rounding error — about 0.3%. Instance count is **not** the constraint
here, and shaving parts off the rig is the wrong first optimisation.

A hand-built `ServerStorage.NPCRig` (which the service prefers over the
fallback, see below) changes this number entirely: a full R15 avatar is
~20 parts plus accessories and Motor6Ds, so five of them is closer to
150–200 instances *and* five times the animation and joint work. Keep the
template simple — that is the whole reason the fallback is deliberately
crude.

### Pathfinding — the expensive one

`PathfindingService:ComputeAsync` is a real navmesh query. It is the only
genuinely costly thing an NPC does, and the whole pathing design exists
to keep the call count down:

- One `ComputeAsync` per **hop**, not per frame and not per tick.
- A hop is one edge of the coarse `NavNode` route
  (`NPCLogic.findNodePath`, breadth-first so the route is the fewest hops
  rather than the shortest distance — fewer hops is literally fewer
  ComputeAsync calls).
- Extra calls only on a `Path.Blocked` signal or the stuck timer.

Per race, per NPC, in a 12-station map with ~20 nav nodes:

| | Estimate | Where it comes from |
|---|---|---|
| Stations to visit | 6 | `GameConfig.tasksPerPlayer` |
| Hops per station route | ~3–5 | BFS across a ~20-node graph |
| Base `ComputeAsync` per NPC | ~18–30 | 6 stations × hops |
| Repaths (blocked / stuck) | ≤ 5 per station, capped | `npc.maxRepathsPerStation` |
| **Worst case per NPC** | ~60 | base + the cap actually being hit |

At 5 NPCs over a 300-second race (`raceDurationSeconds`) that is **~90 to
~300 ComputeAsync calls, i.e. roughly 0.3–1.0 per second server-wide.**
The worst case only happens on a map whose nav graph is wrong, which is
the case the `warn` in `tickWalking` exists to surface.

The cap matters: without `maxRepathsPerStation`, one bot wedged in a
doorway on a badly tagged map would call `ComputeAsync` every
`repathAfterStuckSeconds` for the rest of the race — 200 calls on its own,
from a single geometry bug.

### Script time

One thread for all bots, at `npc.tickHz` (8 Hz):

- **40 tick bodies per second** total at 5 NPCs (8 × 5), regardless of
  how many stations or nodes the map has.
- A `Walking` tick is a handful of vector subtractions, a magnitude, and
  a `Humanoid:MoveTo` — O(1).
- A `Working` tick is one timestamp comparison.
- The only non-O(1) work is `chooseNextStation` (scans remaining
  stations, ~6, and the nav graph for the two nearest nodes, ~20) and it
  runs **once per station completed** — about 30 times per race across
  all five bots, not per tick.

Estimate: well under 1 ms of script time per second at 5 NPCs. The
physics cost of five Humanoids walking is expected to dominate the script
cost, which is why `SetNetworkOwner(nil)` and the disabled Humanoid states
are in `configureRigForPerformance` — that's the part worth measuring
first in a MicroProfiler trace, not the Lua.

### Which knob to turn first

In order, and only after an actual trace:

1. **`npc.tickHz`, 8 → 5.** The floor of architecture.md's permitted
   band, a 37% cut in tick bodies for one config edit and no behaviour
   change beyond slightly coarser waypoint following. Validation refuses
   anything below 5.
2. **`npc.repathAfterStuckSeconds` up, `npc.maxRepathsPerStation` down.**
   Attacks `ComputeAsync`, the expensive call. If a trace shows
   pathfinding dominating, the map's nav graph is the real problem —
   fix the map before tuning this.
3. **The rig.** If a hand-built `ServerStorage.NPCRig` is in use, this is
   where the cost actually went. Strip accessories and animations before
   touching anything else.
4. **Fewer seats.** Filling to 4 instead of 6 is a real lever, but it is
   a *design* change (a thinner-looking race), so it ranks last.

## 2. Where NPCs can still distort the streak leaderboard

`threat-model.md` §8 ranks "farming NPC-filled lobbies" as the **4th most
damaging** attack on leaderboard credibility, and promotes
`architecture.md`'s "consider reduced or zero streak credit above N NPC
seats" to a required launch mitigation. Stating the distortion vectors
plainly, so rewards can be gated deliberately rather than by accident:

### Already mitigated in this task

- **A bot out-racing a human.** `NPCLogic.sampleWorkSeconds` floors every
  sampled duration at the median human time for that task, so no skill
  profile and no roll can finish faster than the median human. Swept
  across the whole roll range in `NPCLogic.spec.luau`, not spot-checked.
- **The opening-seconds gap.** Before any human has completed a task
  there is no observed median, so the floor falls back to the task's
  catalogue range midpoint rather than being unbounded. This is the
  window a bot would otherwise run away in.
- **Bot times polluting the floor.** Only human completions feed
  `humanDurationSamples` (`NPCService`'s `onCompletion` handler skips
  negative ids). Letting bot times in would drift the floor toward
  whatever the bots were already doing — a guarantee that guarantees
  nothing.

### Not mitigated here — gate rewards on these

1. **An NPC-heavy lobby is simply easier to win.** The floor stops a bot
   beating the *median* human; it does not make a bot as good as a *good*
   human. Five bots and one skilled player is a near-guaranteed
   qualification. **This is the main distortion, and code cannot fix it —
   only reward gating can.** `NPCService.roundEarnsStreakCredit()` is the
   call P4-1's `ProgressionService` must make before awarding streak;
   `GameConfig.npcSeatStreakCreditThreshold` (currently 3, PLACEHOLDER) is
   the N. Per threat-model.md §8's cost note, a round that fails the check
   needs an explicit *"queue too thin for streak credit right now"*
   message — silent non-progression will read as a bug to an honest
   off-hours player.
2. **The Decision Studio with NPC finalists.** NPCs can qualify
   (design-decisions.md Q5), and a bot's Steal/Share is drawn from a fixed
   personality probability (P3-6). A human who learns the personality
   distribution has a real edge over a human facing humans — the bounty
   maths in `payoff-table.md` assumes opponents who can reason. A Studio
   seat filled by a bot should probably be worth less, but that is a
   payoff-table decision, not a P3-5 one. **Flagged, not answered.**
3. **Time-of-day farming.** Queuing when lobbies are thin is the actual
   exploit pattern (threat-model.md §8), and the per-round threshold
   above doesn't see it. What catches it is telemetry: streak-gain rate
   correlated with NPC seat count per round, clustered by account and
   hour. That's P4-7's job; `roundEarnsStreakCredit` gives it the field to
   log.
4. **Power-ups spent on bots.** NPCs are targetable exactly like humans
   (that's the point), so a human who can tell bots apart will aim
   offensive items at the humans and win more contested races than the
   balance assumed. This is mostly fine — it's skill — but it means the
   HUD's decision about whether to visibly mark NPCs (P6-3) is a balance
   decision, not just a UI one.

## 3. Studio integration checklist

**Nothing in this task has been run in Studio.** No map with `NavNode`
tags exists yet. Run this the first time a real map does, in order:

1. **Build the rig, or accept the fallback.** Put a `Model` named
   `NPCRig` in `ServerStorage` with a `Humanoid` and a
   `HumanoidRootPart` and it is used as-is. With nothing there, the
   fallback in `buildFallbackRig` is used — **its proportions and
   `HipHeight` are the standard minimal-Humanoid recipe but have not been
   walked around a real map.** If bots sink into the floor, float, or
   refuse to move, that function is the first place to look.
2. **Tag a map.** `NavNode` attachments need `NodeId` and
   `ConnectedNodeIds` (map-kit-spec.md), and the graph must be a single
   connected component. `scripts/build-graybox.luau` already produces a
   conforming set for `GrayBoxTest`.
3. **Load it**, from the server's own command bar — the same route
   `powerup-threat-notes.md` uses, through the loader rather than by
   requiring the service directly:
   ```lua
   local Loader = require(game.ReplicatedStorage.Shared.Loader)
   Loader.get("TaskService").debugLoadStationsFromMap(game.ServerStorage.Maps.GrayBoxTest)
   Loader.get("NPCService").debugLoadFromMap(game.ServerStorage.Maps.GrayBoxTest)
   Loader.get("RoundService").debugForceTransition("Loading")
   ```
   Both loads are needed: bots path to stations `TaskService` owns, so a
   station pool that was never loaded means bots with nowhere to go.

   **The map has to be in `Workspace` for this one, unlike the power-up
   test.** `PathfindingService` computes against real Workspace geometry
   and cannot see anything in `ServerStorage`, so clone the map in first
   (`game.ServerStorage.Maps.GrayBoxTest:Clone().Parent = workspace`) and
   point both loads at the clone. A map left in `ServerStorage` gives
   every `ComputeAsync` a `NoPath` status, and every bot falls back to
   walking in a straight line at its station — which looks like a bot
   bug and isn't one. No map-loading service exists yet to do this
   properly (the gap `TaskService.luau`'s header documents).
4. **Watch the fill log.** `NPCService: N human(s) after a 10s grace
   window - spawned M NPC(s)` should appear 10 seconds into `Loading`,
   with `N + M == 6`.
5. **Watch one bot through a full station.** It should walk, stop within
   `stationArrivalRadiusStuds`, pause for the sampled duration, and
   report a completion that moves the `TaskProgress` broadcast.
6. **Check the floor is binding sometimes, and not always.**
   `NPCService: <name> floored on <task>` prints whenever the rubber band
   catches a sample. Never seeing it means the profiles are all slower
   than the floor and the floor is decorative; seeing it on *every* task
   for a profile means that profile is a lie (see
   `Validate.checkNPCConfig`'s own note on why this isn't a boot check).
7. **Freeze a bot.** Use a hard-control power-up on an NPC and confirm it
   stops, that the `StatusEffectsVisual` broadcast carries its negative
   id, and that it resumes — this is the "affected exactly like humans"
   claim, and the one part of it that can only be checked live.
8. **Watch for the give-up warn.** `gave up pathing to <station> after N
   recomputes - teleporting` means the map's nav graph or geometry is
   wrong. It is a map bug report, not an NPC bug.
