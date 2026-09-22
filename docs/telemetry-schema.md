# Analytics Schema (P4-7)

## Overview

All analytics events flow through a single `Telemetry.luau` service to ensure consistent naming, parameter validation, and rate limiting. The schema is organized into two categories: **core funnel** (headline metrics) and **custom events** (deep-dives).

- **No PII beyond userId.** Never log player names, display names, or chat content.
- **Timestamps in UTC** (os.time()).
- **Rate limited per player per event per minute** via config. 0 = no limit.
- **Batched and flushed** at 50 events or 10 seconds, whichever comes first.
- **Kill switch** in `GameConfig.telemetry.enabled`.

---

## Core Funnel Events

These are the five critical moments in the player journey. Missing funnel events indicate a leak where players are lost invisibly.

| Event | Parameters | Purpose |
|-------|------------|---------|
| `UserQueued` | `userId`, `timestamp` | Player presses queue button. Baseline: how many players are trying to play? |
| `UserMatched` | `userId`, `groupSize`, `npcCount`, `timestamp` | Group of up to 6 formed and ready to teleport. Leak here = matchmaking stall. |
| `RoundStarted` | `roundId`, `mapId`, `playerCount`, `timestamp` | First player spawned in the match server. Start of timed round. |
| `TaskCompleted` | `userId`, `roundId`, `taskId`, `durationSeconds`, `timestamp` | One task finished. Tracks engagement and pacing. |
| `AllTasksCompleted` | `userId`, `roundId`, `placementIndex`, `timestamp` | All assigned tasks done. Placement index = 1-6 (1=first). Qualification happens after sorting these. |
| `Qualified` | `userId`, `roundId`, `placementIndex`, `timestamp` | Made top 3. Placement = 1-3 for qualifiers, 4-6 for alternates. Replicates placement by rule. |
| `FinaleEntered` | `userId`, `roundId`, `placementIndex`, `timestamp` | Teleported into Decision Studio (podium). Placement is final. |
| `ChoiceLocked` | `userId`, `roundId`, `choice`, `timestamp` | Submitted Steal or Share. Only logged once per player per round. |
| `ResultReceived` | `userId`, `roundId`, `resultBranch`, `timestamp` | Finale resolved and the outcome was sent. Branch = `SoleStealer`, `LoneSharer`, `AllShare`, or `AllSteal`. |
| `ReturnedToHub` | `userId`, `timestamp` | Teleported back to the hub place. Round concluded. |

---

## Custom Events

Detailed behaviors and economy metrics that answer "why" for a funnel leak or trend.

### Map and Round Context

| Event | Parameters | Purpose |
|-------|------------|---------|
| `MapVoted` | `userId`, `roundId`, `mapId`, `timestamp` | Player voted in the voting board. Repeat votes overwrite (only latest counted). |
| `MapPlayed` | `roundId`, `mapId`, `playerCount`, `timestamp` | Map was actually played in a round. Aggregates votes and random tie-break. |

### Power-ups

| Event | Parameters | Purpose |
|-------|------------|---------|
| `PowerUpUsed` | `userId`, `roundId`, `powerUpId`, `targetUserId` (nullable), `succeeded`, `timestamp` | Power-up was used in the race. `targetUserId` is null for self-targeted effects. `succeeded` = true if the effect resolved; false if blocked (immunity, range, etc). |

### Economy and Progression

| Event | Parameters | Purpose |
|-------|------------|---------|
| `StealShareChoice` | `userId`, `roundId`, `choice`, `currentStreak`, `timestamp` | Steal or Share choice breakdown by streak length at decision time. Lets you run "do high-streakers steal more?" |
| `FinaleOutcome` | `roundId`, `resultBranch`, `winnerCount`, `loserCount`, `npcCount`, `timestamp` | Outcome distribution per round. `resultBranch` is one of the four Steal/Share outcomes. Used to watch for distribution skew. |
| `StreakLoss` | `userId`, `roundId`, `streakLength`, `lossReason`, `timestamp` | Player lost a streak. `lossReason` = `FailedToQualify`, `StudioLoss`, or `ForfeitDisconnect`. Separates "how many streamers do we lose at each point" by streak length. |
| `NPCCountInRound` | `roundId`, `npcCount`, `humanCount`, `timestamp` | NPC fill telemetry. Lets you see lobby composition and correlate bot density with player outcomes. |

### Monetisation

| Event | Parameters | Purpose |
|-------|------------|---------|
| `PurchaseCompleted` | `userId`, `productId`, `productType`, `timestamp` | Developer product or game pass granted. `productType` = `GamePass` or `DeveloperProduct`. Funnel for store ARPU and conversion. |

---

## Five Dashboard Questions

This schema answers these specific business questions:

1. **"Where do players drop off, and by how much?"**
   - Core funnel: Queue → Match → Round → Finale → Hub. Each step's volume relative to the previous shows where the leak is.
   - Example: 1000 queued, 800 matched, 750 started round, 300 finished tasks = 63% leak between start and qualification.

2. **"Are players engaging with the power-up system, and does it feel good?"**
   - `PowerUpUsed` breakdown by `succeeded` = true/false shows "tried to use" vs "actually worked." High reject rate = immunity/range/cooldown system too punishing, or map design issue.
   - Pair with `TaskCompleted` times: do power-ups meaningfully change pacing, or are they ignored?

3. **"Is the Steal/Share finale balanced by streak, and do payoffs match the design?"**
   - `FinaleOutcome` shows distribution of the four branches. By design, all-steal should be rarest, lone-sharer rarest-ish, all-share common.
   - `StealShareChoice` by `currentStreak` answers "do players at 20-streak steal more than players at 1-streak?" — ideal answer = no meaningful skew (equilibrium is working).
   - If all-steal is 30% instead of 5%, payoff table is wrong.

4. **"Which leaderboard attacks are actually happening, and at what scale?"**
   - `StreakLoss` by `lossReason`: compare forfeit rate to qualification-fail rate. High forfeit = players timing-out to dodge losses. High NPC rounds without streak credit = farming attempts.
   - Pair with `NPCCountInRound`: rounds with 5 bots but a human winning a 20-streak is a flag.

5. **"What is our monetisation funnel, and where are revenue leaks?"**
   - `PurchaseCompleted` by `productType` shows which products sell. Pair with player cohorts to see if cosmetics or starting power-ups drive retention.
   - Very low `PurchaseCompleted` after high `UserQueued` = store is invisible or prices are wrong.

---

## Implementation Notes

### Rate Limiting

Default limit is **0 (no limit)** in `GameConfig.telemetry.perMinuteLimit`, so events are not dropped by default. A player mashing a button 100x/sec logs 60 events/min at limit 60, not 6000.

To enable: set `telemetry.perMinuteLimit = 60` and redeploy. Key is `"eventName|userId"`, so the limit is per-player per-event, preventing one spammer from drowning out the signal.

### Batching

Events queue up to 50 before flushing, or 10 seconds pass, whichever is first. This batching happens in Lua (the Telemetry service), not inside AnalyticsService, to keep frame time predictable.

### Testing

A Telemetry.flush() call is exposed for tests and edge cases (e.g., BindToClose handler). In CI, call flush() and check the event queue before assertions.

### Missing Events vs Zero Events

If an event never fires, the cell is empty (no row). If it fires but is rate-limited, the event is dropped locally (no entry in queue). Rate limit drops are logged nowhere — they are silent by design, because logging "we dropped the event" would spam the logs.

To debug: temporarily set `telemetry.perMinuteLimit = 0` and re-run.
