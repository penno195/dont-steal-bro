# Analytics Schema (P4-7, reworked in next-stages step 6)

## Overview

All analytics go through `src/server/Services/Telemetry.luau`. What each
event is called, which call carries it, its `value` and its three custom
fields are decided in `src/server/TelemetryLogic.luau` (pure, covered by
`tests/TelemetryLogic.spec.luau`). This doc is the table; keep it in step
with that file.

- **Calls:** `AnalyticsService:LogFunnelStepEvent` for the two funnels,
  `LogCustomEvent` for everything else. The deprecated `FireEvent` is gone.
- **No PII.** AnalyticsService attaches the user itself. Nothing logs
  names, chat or another player's id (`PowerUpUsed` dropped its target).
- **Rate limited** per player per event per minute
  (`GameConfig.telemetry.perMinuteLimit`, 0 = no limit).
- **Batched** at `batchSize` events or `flushIntervalSeconds`, and always
  flushed when a player leaves, while they can still be logged against.
- **Kill switch:** `GameConfig.telemetry.enabled`.

> **Wiring status (step 6):** the sink and mapping are done. Only
> `userMatched`, `roundStarted` and `mapPlayed` are called anywhere;
> step 7 wires the rest, step 8 adds the missing events
> (`launch-review.md` §0.3).

## Platform limits that shaped the mapping

From the current Roblox analytics docs and the pinned `globalTypes.d.luau`:

| Limit | Consequence here |
|---|---|
| Every call needs a `Player` | Callers pass a `Player` or user id; an id with no Player in the server (an NPC's negative id, or someone gone) is dropped. Round-level events are logged once against one human in the server, the **anchor**. |
| 3 custom fields, string values, ≤ 8,000 combinations per event | No field ever holds a round id, user id or unbounded number. Those go in `value` or `funnelSessionId`. Streaks are banded (`0`, `1-2`, `3-4`, `5-9`, `10-19`, `20+`). Values are cleaned and capped at 40 chars. |
| ≤ 100 custom event names per game | Breakdowns live in fields, never in event names. |
| A funnel counts a step once per session; keeps the 10 latest sessions per user | Per-task pacing is a custom event, not a step. |
| Events are only accepted from a **published** game's server | Studio sends nothing. `telemetry.studioEcho = true` prints each event to Output instead. Step 9's check must be on a published place. |

Field values carry their dimension name (`Map: School`), as the docs
recommend, so a chart legend reads on its own. Below, F1–F3 are
`CustomField01`–`03`.

## Funnels

### `Matchmaking` (hub)

Session: a fresh GUID per queue attempt (queue, cancel, queue = two sessions).

| Step | Name | From | Fields |
|---|---|---|---|
| 1 | Queued | `userQueued(who)` | none |
| 2 | Matched | `userMatched(who)` | none |

Lobby make-up is on the round side (`MapPlayed`, `NPCCountInRound`).

### `Round` (match)

Session: RoundService's `roundId`. `roundStarted(roundId, mapId, humans, configVersion?)`
sets the round context and logs step 1 for every human present. Every step
carries the **same** fields, because a funnel can only be split by a field
every step has: F1 `Map`, F2 `Humans` (at start), F3 `Config` (the config
version; empty until step 8 supplies it, then it splits a `/liveops
rollout` into treatment and control).

| Step | Name | From | Replaces |
|---|---|---|---|
| 1 | Started | `roundStarted` | `RoundStarted` |
| 2 | Finished | `finished(who)` | `AllTasksCompleted` |
| 3 | Qualified | `qualified(who)` | `Qualified` |
| 4 | FinaleEntered | `finaleEntered(who)` | `FinaleEntered` |
| 5 | ChoiceLocked | `choiceLocked(who)` | `ChoiceLocked` |
| 6 | ResultReceived | `resultReceived(who)` | `ResultReceived` |

Placement, choice and branch aren't step fields: placement follows from
the step reached, and choice and branch are on the custom events below.

## Custom events

"Anchor" = logged once per round against one human, not per player.

| Event | From | Value | F1 | F2 | F3 |
|---|---|---|---|---|---|
| `TaskCompleted` | `taskCompleted(who, taskId, seconds, taskNumber)` | seconds (floored) | `Task` | `Map` | `Order` (1st, 2nd… task; 1 includes the walk from spawn) |
| `MapVoted` | `mapVoted(who, mapId)` | – | `Map` | | |
| `MapPlayed` | `mapPlayed(mapId, humans)`, anchor | humans | `Map` | `Humans` | |
| `PowerUpUsed` | `powerUpUsed(who, powerUpId, succeeded)` | – | `PowerUp` | `Result` (`Landed`/`Refused`) | `Map` |
| `StealShareChoice` | `stealShareChoice(who, choice, streak, rung?)` | streak | `Choice` | `Streak` band | `Rung` (step 8) |
| `FinaleOutcome` | `finaleOutcome(branch, winners, bots)`, anchor | – | `Branch` | `Winners` | `Bots` |
| `StreakLoss` | `streakLoss(who, streak, reason)` | streak lost | `Reason` | `Streak` band | `Map` |
| `NPCCountInRound` | `npcCountInRound(bots, humans)`, anchor, after the fill | bots | `Bots` | `Humans` | `Map` |
| `PurchaseCompleted` | `purchaseCompleted(who, productId, productType, robux?)` | Robux price | `Product` | `Type` | |
| `ReturnedToHub` | `returnedToHub(who, rawReason)` | – | `Reason` (`RoundOver`/`Late`/`Stray`/`Unknown`) | | |

`Map` on a custom event comes from the round context, so it's `none`
in the hub. `ReturnedToHub`'s reason comes from TeleportData, which the
client controls, so only the three reasons the match server sends are
kept. `PowerUpUsed` is never logged from hub practice (P5-5).

`UserQueued`, `UserMatched`, `RoundStarted`, `AllTasksCompleted`,
`Qualified`, `FinaleEntered`, `ChoiceLocked` and `ResultReceived` are no
longer custom events; they are the funnel steps above.

## Five dashboard questions

1. **Where do players drop off?** The two funnels: Queued → Matched in
   the hub, then Started → … → ResultReceived per round, split by map.
2. **Do power-ups feel good?** `PowerUpUsed` by `Result` per power-up.
   High `Refused` = immunity/range/cooldown too punishing.
3. **Is the finale balanced?** `FinaleOutcome` by `Branch`;
   `StealShareChoice` by `Streak` band (and `Rung` from step 8). Ideal:
   no strong skew by streak.
4. **Is anyone farming?** `StreakLoss` by `Reason` (high
   `ForfeitDisconnect` = dodging losses); `NPCCountInRound` against wins.
5. **Monetisation.** `PurchaseCompleted` by `Product`/`Type`, against the
   Matchmaking funnel's volume.

## Implementation notes

- **Failures:** each call is `pcall`ed, but the first failure per event
  name `warn`s, so a broken sink isn't silent.
- **Rate-limit drops are silent** by design. To debug, set
  `perMinuteLimit = 0`.
- **Ingestion delay:** charts can take up to 24 hours to populate.
