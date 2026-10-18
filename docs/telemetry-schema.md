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

> **Wiring status (step 8):** every function below is called from the
> service that knows the fact, including the events `launch-review.md`
> §0.3 asked for. Still unchecked on a published place (step 9).

## Where each call is made

| Call | Service | When |
|---|---|---|
| `userQueued` | MatchmakingService | a fresh queue ticket reaches Waiting (not a requeue after a failed teleport) |
| `userMatched` | MatchTeleportService | each player sent to a match |
| `mapVoted` | VoteService | a vote is written to the group record |
| `returnedToHub` | MatchTeleportService | a player joins the hub from the match place |
| `purchaseCompleted` | StoreService | developer product: receipt granted and saved (value = `CurrencySpent`); coin offer: granted (no value); game pass: a pass seen unowned is now owned (value = configured price) |
| `roundStarted`, `mapPlayed` | MatchTeleportService | the arrival gate closes; `roundStarted` carries `LiveConfig.resolution()` as the Config label |
| `npcCountInRound` | NPCService | after the seat fill (deferred, so the round context is set) |
| `taskCompleted` | TaskService | each accepted completion; seconds since the racer's last task or the race start |
| `finished` | TaskService | a racer completes their last task |
| `qualified` | TaskService | qualification is decided, per qualifier |
| `finaleEntered` | DecisionService | the Studio's roster is set |
| `choiceLocked` | DecisionService | a finalist locks in (a timer default isn't a step) |
| `stealShareChoice` | DecisionService | outcome resolved, per human finalist, with their pre-Studio streak (defaults included) |
| `finaleOutcome` | DecisionService | outcome resolved |
| `resultReceived` | DecisionService | the personal result is sent at Reveal |
| `streakLoss` | ProgressionService | every non-win result, including forfeits and failing to qualify |
| `streakWin` | ProgressionService | every win, with the round's bot seats from `npcCountInRound` |
| `roundEnded` | TaskService | entering Results; race length measured from the deal to Race's end |
| `taskAbandoned` | TaskHandlerService | the player closes a race task's view (`Closed`) or starts another station (`Switched`). Not a solve waiting out its floor, a re-roll at the same station, practice, or the round ending |
| `powerUpCollected` | PowerUpService | a field pickup (`Pickup`) or a pre-game loadout item (`Loadout`) |
| `powerUpUsed` | PowerUpService | an item was spent: `Landed` if applied, `Refused` if blocked or the target was gone on impact. Cooldown / no-target refusals spend nothing and aren't logged |
| `playerLeft` (internal) | Telemetry's own `PlayerRemoving` | every player leaving any server, before the queue flushes |
| `leftWhileQueued` | MatchmakingService | its `PlayerRemoving` handler, for a player with a ticket (the two handlers run in no set order) |
| `tutorialStep` (internal) | `TutorialStepIntent` | HubIntroController as each hub step opens or is skipped; OnboardingController as each guided-round pop-up opens |
| `scriptError` (internal) | `ScriptContext.Error` on the server; `ClientErrorReport` from ErrorReportController | an uncaught error, within `errorsPerMinute` per server |

NPC ids are dropped by the sink, so callers pass racer ids freely.

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
every step has: F1 `Map`, F2 `Humans` (at start), F3 `Config` (the
server's live-config resolution and version, e.g. `Staged v7`; during a
`/liveops rollout` treatment servers run `Staged` and control servers
`Active`, so this splits the two groups).

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
| `StealShareChoice` | `stealShareChoice(who, choice, streak, bots, rung?)` | streak | `Choice` | `Bots` (bot finalists in this Studio, 0–2; `0` = an all-human Studio) | `Rung` (the rung a win would pay at) |
| `FinaleOutcome` | `finaleOutcome(branch, winners, bots)`, anchor | – | `Branch` | `Winners` | `Bots` |
| `StreakLoss` | `streakLoss(who, streak, reason)` | streak lost | `Reason` | `Streak` band | `Map` |
| `NPCCountInRound` | `npcCountInRound(bots, humans)`, anchor, after the fill | bots | `Bots` | `Humans` | `Map` |
| `PurchaseCompleted` | `purchaseCompleted(who, productId, productType, robux?)` | Robux price | `Product` | `Type` | |
| `ReturnedToHub` | `returnedToHub(who, rawReason)` | – | `Reason` (`RoundOver`/`Late`/`Stray`/`Unknown`) | | |
| `StreakWin` | `streakWin(who, streak)` | streak after the win | `Streak` band | `Bots` (round's NPC seats, `unknown` before the fill) | `Map` |
| `RoundEnded` | `roundEnded(raceSeconds, humanFinishers, humans)`, anchor | race seconds (floored) | `Map` | `Finishers` (humans) | `Humans` (still here at Results) |
| `TaskAbandoned` | `taskAbandoned(who, taskId, seconds, exit)` | seconds spent (floored) | `Task` | `Map` | `Exit` (`Closed`/`Switched`) |
| `PowerUpCollected` | `powerUpCollected(who, powerUpId, source)` | – | `PowerUp` | `Source` (`Pickup`/`Loadout`) | `Map` |
| `PlayerLeft` | on `PlayerRemoving` | seconds in this server (floored) | `Place` (`Hub`/`PracticeHub`/`Match`/`Practice`/`Tutorial`) | `Where` (below) | `Session` band (`0-1m`/`1-5m`/`5-15m`/`15-30m`/`30-60m`/`60m+`) |
| `TutorialSkipped` | `TutorialStepIntent` with `skipped` | – | `Step` (`Hub welcome`, the only step with Skip) | | |
| `ScriptError` | server or client uncaught error | – | `Side` (`Server`/`Client`) | `Origin` (`Module line N`, first stack frame) | `Place` |

`Map` on a custom event comes from the round context, so it's `none`
in the hub. `ReturnedToHub`'s reason comes from TeleportData, which the
client controls, so only the three reasons the match server sends are
kept. `PowerUpUsed` and `PowerUpCollected` are never logged from hub practice (P5-5).

`PlayerLeft`'s `Where`: `Tutorial <step>` while the tutorial is
running (the last onboarding step this server saw), else `Queued` or
`Hub` on a hub, else the round state (`Loading`, `Race`,
`DecisionStudio`, …). A hub session and a match session are different
servers, so `Session` is time in this server, not in the game. Read it
as: many `Place: Match` + `Where: Race` + `Session: 0-1m` = something
in the first minute of a race drives people out.

`ScriptError` never carries the message (it can hold player names);
`Origin` is the module and line of the first stack frame, with a client
path's `Players.<name>` prefix dropped. Client errors are deduplicated
on the client (each origin once per session, at most 10) and both sides
share `GameConfig.telemetry.errorsPerMinute` per server. Server errors
are logged against any player in the server, so a server with no
players drops them.

`UserQueued`, `UserMatched`, `RoundStarted`, `AllTasksCompleted`,
`Qualified`, `FinaleEntered`, `ChoiceLocked` and `ResultReceived` are no
longer custom events; they are the funnel steps above.

## Onboarding funnel (the tutorial)

`AnalyticsService:LogOnboardingFunnelStepEvent`, the platform's own
first-time-user funnel: one per account, each step counted the first
time it's reached. Steps are `TelemetryLogic.ONBOARDING_STEPS`, the
Hub's (`OnboardingLogic.HUB_STEPS`) then the guided round's
(`OnboardingLogic.STEPS`); a spec fails if either list changes without
it.

| # | Step | # | Step |
|---|---|---|---|
| 1 | `Hub welcome` | 8 | `Hub loadout` |
| 2 | `Hub rivals` | 9 | `Hub close` |
| 3 | `Hub aim` | 10 | `Hub play` |
| 4 | `Hub station` | 11 | `Round station` |
| 5 | `Hub task` | 12 | `Round task` |
| 6 | `Hub locker` | 13 | `Round freeze` |
| 7 | `Hub gift` | 14 | `Round finish` |

A step is logged when it **opens**, so the drop between two steps is
"saw this one, never got the next". A skipped step (no practice area
answered, no Freeze to fire) is back-filled by the platform. The client
reports the step (`TutorialStepIntent`); the server drops any name not
in the list, so a spoofed report only skews that account's own row.
Skip is `TutorialSkipped`, not a step.

## Five dashboard questions

1. **Where do players drop off?** The onboarding funnel for new
   players; then Queued → Matched in the hub, then Started → … →
   ResultReceived per round, split by map. `PlayerLeft` by `Where` says
   where the ones who quit actually were; `ScriptError` by `Origin`
   says whether something broke first.
2. **Do power-ups feel good?** `PowerUpUsed` by `Result` per power-up.
   High `Refused` = immunity/range/cooldown too punishing.
3. **Is the finale balanced?** `FinaleOutcome` by `Branch`;
   `StealShareChoice` by `Rung`, with `Bots = 0`. Ideal: no strong
   skew by streak.
4. **Is anyone farming?** `StreakLoss` by `Reason` (high
   `ForfeitDisconnect` = dodging losses); `StreakWin` by `Bots`.
5. **Monetisation.** `PurchaseCompleted` by `Product`/`Type`, against the
   Matchmaking funnel's volume.

## Implementation notes

- **Failures:** each call is `pcall`ed, but the first failure per event
  name `warn`s, so a broken sink isn't silent.
- **Rate-limit drops are silent** by design. To debug, set
  `perMinuteLimit = 0`.
- **Ingestion delay:** charts can take up to 24 hours to populate.
