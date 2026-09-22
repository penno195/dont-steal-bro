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

---

# Part 2: the brain (P3-6)

`NPCBrain.luau` adds the two behaviours P3-6 asked for on top of P3-5's
fill: using power-ups during the race, and negotiating in the Decision
Studio. `NPCBrainLogic.luau` holds the arithmetic (unit-tested in
`tests/NPCBrainLogic.spec.luau`); the personalities and their lines are
config files under `src/shared/Config/NPCPersonalities/`.

## 4. "Never a shortcut", concretely

P3-6 requires NPCs to "obey exactly the same cooldowns, ranges and
immunity rules as players — route every use through the existing
validated server path." That isn't a promise made in a comment; it's
enforced by there being exactly one path:

| What a bot wants to do | What it actually calls | What a human's input reaches |
|---|---|---|
| Use a power-up | `PowerUpService.useForRacer(id, slot)` | `handleUseIntent` → **the same `useFor`** |
| Lock in a choice | `DecisionService.submitChoiceFor(id, choice)` | `handleChooseIntent` → **the same `lockIn`** |
| Know if an item is ready | `PowerUpService.isOnCooldownFor(id, powerUpId)` | the same `PowerUpLogic.isOnCooldown`, same timestamp |

`useFor` is the only function in the codebase that can consume an
inventory slot, and `lockIn` the only one that can record a choice.
Neither takes a "skip validation" argument, because neither has one to
take. A bot fails where a player fails — out of range, on cooldown, into
a hard-control immunity window — and the audit log records its attempt
in the same shape, so power-up balance data covers the whole field
rather than the human half of it.

The one thing a bot does *not* get is a reply: `sendResult` and
`broadcastInventory` return early when a racer has no `Player`, because
there is no client to tell. Nothing about the decision differs.

## 5. Two judgement calls worth knowing about

### NPCs do not preferentially target humans

P3-6's brief lists "whether a human is close ahead" as a scoring input.
It's implemented as **whether a *racer* is close ahead**, without regard
to whether that racer is a bot.

A species-aware targeting rule would mean a human-heavy lobby is
mechanically harder than an NPC-heavy one, for reasons no player could
see — the exact opposite of what `threat-model.md` §8 is trying to keep
honest, and it would make bots feel personally hostile in a game whose
whole social premise is that betrayal is a *choice* someone made. In a
6-seat race most racers ahead are human anyway, so the observed
behaviour is what the brief describes; what's avoided is the *rule*
knowing the difference. `NPCBrainLogic.Situation` documents this at the
field.

### Power-ups are now consumed on use

**This is a behaviour change to P2-7, found while building P3-6.**
`handleUseIntent` never removed a used item from the inventory — only a
cooldown gated re-use. With `powerUpInventorySlots = 1` and the `Refuse`
full-inventory policy, that meant a player picked up exactly one
power-up per round, re-used it every cooldown for the rest of the race,
and could never pick up another, because their slot never emptied.
`powerups.md` describes a field pickup as "consumed on pickup, usable
immediately, no persistent ownership," so this was a bug rather than a
design choice — and the brain's entire utility score is premised on
using an item costing you the item.

The item is consumed **before** the effect resolves, and **even when the
effect is blocked**. `powerups.md` only settles that for one case — rule
5, Task Scramble immunity: "the caster's power-up is consumed with no
effect" — and is silent for rules 1-3 (hard-control immunity,
diminishing returns, the rolling cap). Treating them the same way is the
consistent reading: a use that found a legal target has been committed,
and a victim's anti-frustration protection is meant to cost the attacker
something. **Revisit if playtesting says firing into an immunity window
feels unfair rather than punishing** — it's one line in
`PowerUpService.useFor`.

## 6. The Studio: what a bot says versus what it does

The two are independent by construction. The hidden choice is rolled
**once, when Negotiate begins**, from the personality's own
`stealProbability` (Greedy 0.7 / Loyal 0.2 / Chaotic 0.5,
architecture.md §4). Nothing between that roll and the lock-in reads a
line, and nothing that picks a line reads the choice. A human reading a
bot's chatter is reading a bluff, not a tell — which is the only honest
way to ship "lines that may or may not match what it actually does."

Lines escalate with the clock rather than being drawn at random:
promises early, pressure in the middle, accusations as it tightens,
wobbles at the end (`NPCBrainLogic.categoryForProgress`). A line is not
repeated inside one window if a fresh one is available — a bot saying
the same thing twice in 45 seconds is the most obvious possible tell
that it isn't a person.

**The rule every line obeys** — *a line must never state a fact only the
server knows* — is written out in full at the top of
`src/shared/Config/NPCPersonalities/init.luau`. No validator can check
it (it's a property of English), so it is a review-time rule. Read it
before adding a line.

Lock-in lands at a random point in the middle 55% of the Choose window
(`lockInEarliestFraction` 0.25 to `lockInLatestFraction` 0.8) and
**never at the deadline** — config validation refuses a latest fraction
of 1.0, because a lock-in racing the phase timer is a coin flip between
the bot's own choice and the configured default, decided by scheduler
ordering. `NPCBrainLogic.spec.luau` sweeps every roll to prove it.

## 7. Cost, on top of Part 1's numbers

The brain re-scores at `npcBrain.decisionHz` (2 Hz), not at
`npc.tickHz` (8 Hz) — a power-up decision that lands a second late is
invisible to everyone. At 5 NPCs that is **10 decision bodies per
second**, each one a scan of the racer roster (at most 6) and one
distance read per racer ahead. It is comfortably the cheaper half of the
NPC system; if a trace disagrees, `decisionHz` is the first knob and has
no floor to respect the way `tickHz` does.

Studio behaviour costs essentially nothing: a handful of `task.delay`
threads per bot, scheduled once per phase and cancelled on exit.

## 8. Studio checklist additions for P3-6

Continuing from Part 1's list — these need a race actually running with
power-up spawns loaded (`PowerUpService.debugLoadSpawnPointsFromMap`):

9. **Watch a bot pick something up.** Walk a bot over a `PowerUpSpawn`
   pickup. Before P3-6 this was impossible — `tryClaimPickup` resolved
   the claimer through `Players:GetPlayerFromCharacter`, which can never
   answer for an NPC. It now resolves through the participant roster.
10. **Watch it use the thing.** `PowerUpService.getAuditLog()` records a
    bot's use in the same shape as a player's, with the bot's negative
    id as `playerId`. A bot holding an item and never firing usually
    means `useThreshold` is above what any real situation scores —
    compare against the logged score by temporarily printing it.
11. **Confirm consumption.** After a bot (or a player) uses an item, the
    inventory must be empty and a new pickup must be claimable. This is
    the P2-7 fix above; it is the single most likely thing to have
    broken something that used to "work."
12. **Watch a negotiation.** With at least one NPC qualifier, the Studio
    should show 3 bubbles from it across Negotiate, at a human pace,
    none repeated. `NPCBubbleController` resolves the rig by name under
    `Workspace.NPCs` using the `NPCRoster` broadcast — **a bubble with
    no rig is dropped silently**, so if nothing appears, check the
    roster arrived before checking the brain.
13. **Confirm the bluff is a bluff.** `NPCBrain.debugGetPersonality(id)`
    is server-side only, deliberately — a client that knew a finalist
    was Loyal would have most of the game solved. Use it from the
    command bar to check what a bot *was* against what it *said* across
    a few rounds; a Greedy bot promising to share and then stealing is
    the system working, not a bug.
