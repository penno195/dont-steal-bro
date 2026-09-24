# Soft-launch review loop (P9-2)

A recurring review for the soft launch and the weeks after it. Each
week, read the telemetry, decide what to change, and log the decision.
This file is the **procedure**. The dated findings go in the log at the
bottom (§9).

**Status: no data yet.** This was written before launch. Nothing below
is a finding. Every threshold is the value this review will *act* on,
taken from the design docs, and none of them is a measurement. The first
real review replaces the empty log rows.

**The review can't run on day one without §0.** Only 3 of the 18 events
in `telemetry-schema.md` are actually sent, and the sink uses a
deprecated API. Fix that before launch, or week one produces a funnel
with nothing in it.

---

## 0. Pre-launch blocker: the instrumentation gap

### 0.1 Events that are defined but never sent

`Telemetry.luau` exports 18 event functions. The only calls to them are
in `MatchTeleportService` (`userMatched`, `roundStarted`, `mapPlayed`).
Every other event is dead code. Each needs a call at the point where the
server already knows the fact:

| Event | Emit from | Review section that needs it |
|---|---|---|
| `UserQueued` | MatchmakingService (join accepted) | §2 funnel |
| `TaskCompleted` | TaskService (completion validated) | §2, §4.2 |
| `AllTasksCompleted`, `Qualified` | RoundService (placement resolved) | §2, §5 |
| `FinaleEntered`, `ChoiceLocked`, `ResultReceived` | DecisionService | §2, §3 |
| `StealShareChoice`, `FinaleOutcome` | DecisionService (on resolve) | §3, §6 |
| `StreakLoss` | ProgressionService | §3, §6 |
| `ReturnedToHub` | hub arrival (TeleportService data) | §2 requeue |
| `MapVoted` | VoteService | §4.1 |
| `PowerUpUsed` | PowerUpService (accepted *and* refused uses) | §4.3 |
| `NPCCountInRound` | NPCService (after fill) | §5 |
| `PurchaseCompleted` | StoreService (after the receipt is granted) | funnel (monetisation) |

### 0.2 The sink API

`flush()` calls `AnalyticsService:FireEvent`, which the pinned
`globalTypes.d.luau` marks `@deprecated`, inside a `pcall` that hides
any failure. The current methods are the `Log*` family:

- `LogFunnelStepEvent(player, funnelName, funnelSessionId, step, stepName, customFields)`
  for the round funnel (§2). Use `roundId` as `funnelSessionId`.
- `LogCustomEvent(player, eventName, value, customFields)` for everything else.

Both constraints below come from the signatures and the enum in the
pinned types:

- **Every call needs a `Player`.** NPC events (negative ids) and
  round-level events (`FinaleOutcome`, `MapPlayed`, `NPCCountInRound`)
  must be logged against a human in the round, or aggregated into a
  human's event. A bot-only fact with no human anchor can't be logged.
- **Only 3 custom fields** (`Enum.AnalyticsCustomFieldKeys.CustomField01..03`).
  Most schema events carry 4–6 parameters. Use the numeric `value` for
  one number (a duration, a streak) and put the fields you break down by
  into the three slots. The mapping per event has to be decided when the
  events are wired, and it controls which breakdowns this review can do.

**Verify in Studio before launch:** fire each event from a test place
and confirm it appears in Creator Hub analytics. Expect some ingestion
delay. Don't trust a `pcall` that returned nothing.

### 0.3 Events this review needs that the schema doesn't have

| Missing | Why | Suggested shape |
|---|---|---|
| Task abandoned | The brief asks for "too often abandoned". Completions alone can't show it. | `TaskAbandoned(taskId, secondsSpent)` when a player leaves a station with the task unfinished |
| Power-up collected | "Never used" needs a denominator. Unused because nobody picks it up, or picked up and held? | `PowerUpCollected(powerUpId)` |
| Round ended | Race length, finishers, backfilled seats, humans still present | `RoundEnded(mapId, raceSeconds, humanFinishers)` |
| Streak credit | Whether `NPCService.roundEarnsStreakCredit()` refused credit (npc-notes.md §2) | a field on the win event |
| Bounty tier | The finale check (§3) is done per tier | a field on `StealShareChoice` |
| Config version | Tells patched rounds apart from unpatched ones during a `rollout` | a field on `RoundStarted` |

The last row pays for itself. `/liveops rollout 10` gives a treatment
group and a control group running at the same time, but only if the
events say which group a round was in.

**Recommendation:** make §0 its own task (wiring, the field mapping,
the new events and a Studio check). Do it before the soft launch.

---

## 1. How to run a review

1. **Pull the window.** 7 days, same weekday to same weekday. Roblox
   traffic has a strong weekend shape, so a shorter window compares a
   Saturday against a Tuesday.
2. **Check sample sizes first (§7).** Mark every metric below its
   minimum as *noise* before you look at its value, so the number can't
   talk you into acting on it.
3. **Go through §2–§6.** Each section says what to compute, the
   threshold that makes it a finding, and the lever to pull.
4. **Write each finding as:** change, expected effect, confirming
   metric, how long to wait (§8 format).
5. **Rank by impact per unit of work (§8)** and ship at most **one
   change per area** per window. Two finale changes at once can't be
   told apart.
6. **Ship through live config where possible:** `set` → `rollout 10`
   → compare by config version → `rollout 50` → `promote`
   (`live-ops.md`).
7. **Log it** in §9, including the findings you decided were noise.

**Always segment by lobby composition.** Rounds with 0–1 NPCs and
rounds with 4–5 NPCs are different games (§5). A pooled number over
both hides whichever effect is real.

---

## 2. Funnel read

### Steps

| # | Step | Source |
|---|---|---|
| 0 | Joined the hub | Creator Hub (built in) |
| 1 | Queued | `UserQueued` |
| 2 | Matched | `UserMatched` |
| 3 | In a round | `RoundStarted` (join by user via `UserMatched`) |
| 4 | Completed a first task | first `TaskCompleted` per user per round |
| 5 | Completed all tasks | `AllTasksCompleted` |
| 6 | Qualified (top 3) | `Qualified`, placement 1–3 |
| 7 | Locked a choice | `ChoiceLocked` |
| 8 | Back in the hub | `ReturnedToHub` |
| 9 | **Queued again** | a second `UserQueued` in the same session |

Retention (D1/D7) and session length come from Creator Hub's built-in
dashboards. Compare those against the **similar experiences** benchmark
that the dashboard itself shows. This doc gives no industry figures,
because any number written here would be a guess.

### What each drop means, and our own expectations

These thresholds come from how the systems are designed, not from
benchmarks:

| Drop | Expected | Finding if | Most likely cause | Fixability |
|---|---|---|---|---|
| 0→1 join→queue | Most people queue | < 70% | Hub doesn't point at the queue, or onboarding stalls (`onboarding.md`) | High: hub UI |
| 1→2 queue→match | ~100%, NPC fill means nobody waits forever | < 95% | Players leave while waiting. Check wait time against `partialGroupTimeoutSeconds` (60) | High: live tunable |
| 2→3 match→round | ~100% | < 97% | Teleport failures (`teleport.md` retry path) | High: engineering |
| 3→4 round→first task | ~100% | < 90% | Can't find a station or read a task (`station-readability.md`) | Medium |
| 4→5 first task→all tasks | Race-dependent | Falls on one map or task only | That map or task (§4) | Medium |
| 5→6 all→qualified | ~50% by design (3 of 6 seats) | — | Not a leak. Top 3 is the design | — |
| 8→9 **requeue** | The metric that matters | Requeue after a **streak loss** far below requeue after a win | The reset stings more than it motivates | Low: design |

**Most fixable drop:** the biggest drop in rows 1→2 or 2→3. Those are
engineering or tunable problems and the fix doesn't need a design
argument. **Most important drop:** 8→9 after a loss. The whole game
assumes a reset makes you queue again ("one more go"), and requeue after
a loss is the only direct test of that. Split it by the streak that was
lost (`StreakLoss.streakLength`). Losing a 12-streak and not coming back
is the failure mode that design-decisions.md Q7 accepted, so measure it.

---

## 3. Finale health: tension, or a dominant strategy?

The model is in `payoff-table.md`. With `L`/`M`/`S` = sole-stealer,
lone-sharer and all-share VU, and `Closs` = the value of the streak you
lose:

```
p* = 1 / (1 + √((M + Closs) / (L − S)))
```

`p*` is the steal rate at which neither choice is better. The design
bet is that the population steal rate hovers near `p*` and falls as
streak tier rises (0.53 at tier 1 → 0.41 at tier 5).

**Only count Studios with three human finalists.** A bot's choice is a
fixed personality probability (Greedy 0.7 / Loyal 0.2 / Chaotic 0.5).
Studios with bots measure the personality mix, not player behaviour.
Report them separately (§5).

### 3.1 The three checks

**A. Steal rate by tier compared with `p*`.** From `StealShareChoice`,
steal rate by bounty tier, with a 95% interval
(`±1.96·√(p(1−p)/n)`). A finding needs the **whole interval** to sit
outside `p* ± 0.05`.

**B. Outcome split compared with independent play.** If each of three
players steals independently at the observed rate `p`, the outcome
split would be:

| Branch | Independent expectation | At p = 0.5 |
|---|---|---|
| SoleStealer (1 steal) | 3p(1−p)² | 37.5% |
| LoneSharer (2 steal) | 3p²(1−p) | 37.5% |
| AllShare | (1−p)³ | 12.5% |
| AllSteal | p³ | 12.5% |

Compare the observed `FinaleOutcome` split with this. **More AllShare
than independent play predicts** means players are coordinating. That is
either the negotiate window working as intended, or collusion (§6). The
repeat-pair check tells them apart. Absolute alarm levels are in
payoff-table.md §4: **AllShare > 50–60%** means the finale is a
formality, and **AllSteal > 15–20%** means trust has collapsed.

**C. Steal-rate slope across tiers.** It should fall. If it's flat or
rising, high-streak players aren't protecting what they have, and the
loss-aversion effect isn't landing.

**The dominance test itself:** for each tier, compute the *realised*
average payoff of Steal and of Share. A win pays its VU, and a loss
costs `2 × streak` (payoff-table.md's `c₀ = 2`). If one choice pays
more in every tier for two windows in a row, it's dominant in practice,
whatever the model says.

### 3.2 Which lever moves what

`Closs` is the streak itself and can't be tuned. `c₀` is a modelling
constant, not a config value. The live levers are only
`game.bountyTiers.<n>.soleStealerVU | loneSharerVU | allShareVU`, and
Validate keeps Steal above Share.

| Observed | Change | Predicted effect on `p*` |
|---|---|---|
| Steal rate above `p*` (too greedy) | Lower `L` for that tier | Tier 1, L 20→16: p* 0.53→0.49 |
| Steal rate below `p*`, AllShare too high | Raise `L` or lower `S` | Tier 1, S 5→3: p* 0.53→0.54 |
| AllSteal too high | Raise `M` (reward the holdout) | Tier 1, M 10→14: p* 0.53→0.49 |
| Slope flat or reversed | Flatten the upper tiers' `L` (tiers 4–5 only) | Lowers `p*` at the top only |

The `p*` shift is the model's prediction. The effect on the *observed*
rate is smaller and slower, because players react to their beliefs
about each other, and those update over many Studios. **Change one tier
at a time**, starting with tier 1, which has by far the most data.

**Confirming metric:** that tier's steal rate over the next window,
compared with the control servers during `rollout`. **Wait:** until the
changed tier has had its §7 minimum number of choices again. Never less
than 7 days.

---

## 4. Balance

For every table: flag an item only if it's past the threshold **and**
past its §7 sample minimum. Compare each item with the **median item**,
not with a design target, because the design targets are placeholders
(`raceDurationSeconds`, `tasksPerPlayer` are marked PLACEHOLDER in
GameConfig).

### 4.1 Maps (wave 1: Factory, Laboratory, Museum, School)

| Metric | Outlier if | Lever |
|---|---|---|
| Vote share vs play share | A map loses votes it's offered in ≥ 2× as often as the median | Map quality. It's feedback, not a tunable |
| Median race length | > 1.3× or < 0.7× the median map | Station layout (Studio work), or `raceDurationSeconds` if every map is off |
| Rounds where < 3 humans finish before the timer | > 1.5× the median map | Map is too long or confusing |
| NPC qualification rate on this map | > 1.5× the median map | `map.<id>.npcDifficultyModifier` (live) |
| Humans still present at `RoundEnded` | Lowest by a clear margin | Players leave this map mid-round |

"Per-map win rate" in this game means **human qualification rate** in
comparable lobbies (same NPC bucket). The race has three winners, not
one.

### 4.2 Tasks

| Metric | Outlier if | Reading |
|---|---|---|
| Median `durationSeconds` | Outside the task's catalogue range (`tasks-catalogue.md`) | Mis-tuned |
| p90 / median | > 3 | Some players don't understand it. Check `task-views.md` |
| Median below the catalogue minimum | Any | Too easy **or** a validation hole. Check §6 first |
| Abandonment (`TaskAbandoned` / starts) | > 2× the median task | Confusing, too hard on one thumb, or broken on some devices |

Split task times by platform if the custom fields allow it. A task that
is fine on PC and abandoned on phones fails the mobile-first rule, and
the fix is the task, not a tunable.

### 4.3 Power-ups (10 at launch)

| Metric | Outlier if | Lever |
|---|---|---|
| Share of all uses | < 2% ("never used", when 10% is an even split) | Make it stronger (`effect.<id>.magnitude`), or check that its pickup spawns |
| Collected but never used | > 50% of pickups | Players don't understand it. It's a readability problem, not balance |
| Share of all uses | > 25% ("always used") | Longer cooldown (`powerUp.<id>.cooldownSeconds`) or a weaker effect |
| `succeeded = false` rate | > 30% | Range or immunity rules too strict. Try `game.powerUpUseRangeStuds` |

**Noise warning:** the qualification rate of players who used a
power-up, compared with players who didn't, is confounded. Better
players collect more pickups. Don't use it as evidence of strength.
The share of uses and the refused rate are the only clean signals at
soft-launch volume.

---

## 5. NPC calibration

At soft-launch concurrency most lobbies will have bots, so this section
probably matters more in week one than §3 does.

**Bucket every round by NPC count:** 0, 1–2, 3–4, 5 (`NPCCountInRound`).

| Check | Healthy | Finding if | Lever |
|---|---|---|---|
| Human qualification rate by bucket | Rises gently with more bots | Near 100% in the 5-bot bucket: bot rounds are free wins | `game.npc.**`, `game.npcBrain.**` (live) |
| Bots' share of Studio seats in rounds with ≥ 3 humans | Low: bots are floored at median human speed | Bots routinely beat humans into the Studio | Same, or `map.<id>.npcDifficultyModifier` |
| Bots' Studio steal rate | Matches the personality weights | It doesn't | A bug in NPCBrain, not balance |
| Humans' realised payoff against bots vs against humans | Similar | Clearly higher against bots | npc-notes.md §2.2's open question. It needs a design decision (payoff-table), so ask |
| Streak credit refused (`roundEarnsStreakCredit`) | Rare off-peak, near zero at peak | Common at peak hours | `npcSeatStreakCreditThreshold` needs a **deploy**. It isn't in `tunablePaths` |

A qualification rate that is *distorted* by bots moves the streak
leaderboard (threat-model.md §8, 4th most damaging attack). Check the
leaderboard's top 20 by the NPC-bucket mix of their winning rounds. If
the top of the board was built in 5-bot rounds, the credit gate isn't
strict enough.

---

## 6. Integrity

These are patterns to **investigate**, not ban on. Every one of them
has an honest explanation at low concurrency. Take evidence from
server logs (`MovementWatch`, `NetGuard` rejects) alongside the
telemetry.

| Pattern | What it looks like | Honest explanation to rule out |
|---|---|---|
| **Collusion** | The same user pair meets in the Studio far more than concurrency predicts, **and** their AllShare rate is far above strangers' | Low concurrency makes repeat meetings common. Compare with pairs that meet just as often but don't all-share |
| **Feeding** | One account repeatedly loses the Studio to the same account, often LoneSharer vs SoleStealer | Two friends playing at the same off-peak hour |
| **Farming** | High streak gain per hour concentrated in 4–5 NPC rounds, clustered by account and hour of day (npc-notes.md §2.3) | Genuinely thin off-peak queues. That's a credit-gate question, not a player question |
| **Speed exploits** | `TaskCompleted` duration below what the task physically allows, or `MovementWatch` flags | A task whose minimum is set too high in the catalogue |
| **Forfeit dodging** | `StreakLoss` with `ForfeitDisconnect` spiking at the Studio for high streaks | Under Q4 a leaver takes the loss anyway, so this is rage-quitting, not dodging. It's a UX signal |

`game.matchmaking.rematchCooldownSeconds` is the live lever against
repeat pairings if collusion turns out to be real.

---

## 7. Sample-size floor: when a number is noise

For a rate near 50%, the 95% interval half-width is about
`0.98 / √n`. The floors below give roughly ±8 points, the smallest
difference this review acts on.

| Metric | Minimum before it can be a finding |
|---|---|
| Steal rate, per tier | 150 human choices in that tier |
| Outcome split | 150 all-human Studios |
| Per-map anything | 100 rounds on that map |
| Per-task duration or abandonment | 200 attempts at that task |
| Power-up share of uses | 1,000 uses in total |
| NPC bucket comparisons | 100 rounds per bucket |
| Integrity pair analysis | Never from counts alone. Investigate individual cases |
| Retention (D1/D7) | Whatever Creator Hub shows with its own confidence display. Don't compare days one at a time |

**Expect tier 4–5 finale data to be noise in week one.** Reaching
streak 10 takes 10 wins in a row, and few players will have done it.
Don't tune tiers 4–5 until they pass their floor, even if the numbers
look alarming. Tier 1 carries the finale review until then.

Name noise findings in the log anyway, as *"noise at n = …, re-check
next window"*, so a number that turns out to be real later has a
history.

---

## 8. Ranking and finding format

**Impact** = share of rounds or players affected × severity (3 = people
leave the game, 2 = a system is unbalanced, 1 = polish).

**Work:**

| Cost | Kind of change |
|---|---|
| 1 | Live tunable (`/liveops set` + rollout) |
| 2 | Config file + deploy |
| 3 | Code change in a service or handler |
| 5 | Map rebuild in Studio, or a design decision |

**Priority = impact ÷ work.** Ties go to whatever can be A/B'd with
`rollout`.

Each finding, one row:

| # | Finding | n | Change | Expected effect | Confirming metric | Wait | Priority |
|---|---|---|---|---|---|---|---|

"Wait" is a sample count, with a floor of 7 days, never just a number
of days. Balance changes and content ship in separate windows so their
effects can be told apart (the same rule P9-3 plans around).

---

## 9. Review log

Newest first. Copy the block for each weekly review.

### Review 1 — (date) — window (from) to (to)

- **Config version at start:**
- **Volume:** players, rounds, all-human Studios, human Studio choices
  by tier
- **Instrumentation check:** every §0.1 event present? Anything missing
  is logged here before any finding

| # | Finding | n | Change | Expected effect | Confirming metric | Wait | Priority |
|---|---|---|---|---|---|---|---|
| — | *(no data yet)* | | | | | | |

**Noise this window:**

**Shipped:**

**Carried over from last review (result of last window's change):**
