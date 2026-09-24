# Security Audit — Remote Surface (P8-1)

Scope: the whole server boundary as of commit `8d60123` (P7-6). Assumption,
per Ground Rule 1: the client is fully compromised. Every remote can be
fired with any payload at any rate, no client-side check exists, and the
attacker can read all replicated state.

## 1. How the boundary is built

There is exactly **one** way in. `Net.createRemotes` creates every
`RemoteEvent` from the `Net.Remotes` table (no `RemoteFunction`s exist, so
there are no server→client invokes to hang), and `NetGuard:init` connects
the **only** `OnServerEvent` in the codebase. There are no `Instance.new`
remotes elsewhere, no `ClickDetector`/`ProximityPrompt` handlers, and
exactly one server `Touched` handler (power-up pickups, §4 F3).

Every call passes, in order (the order changed in this audit, see F2):

1. **Player still present:** late events after `PlayerRemoving` are dropped.
2. **Schema declared:** a `ServerBroadcast` remote has none, so any client
   `FireServer` on one is dropped.
3. **Per-player, per-remote token bucket.**
4. **Exact-shape schema:** unknown keys are rejected, and NaN, non-integer
   and out-of-range values fail.
5. **Round-state gate.**
6. **The owning service's own truth check.** This is always required: a
   NetGuard pass only means well-formed, never true.

Rejections are reported through a per-player throttled sink (F2) and
counted toward a flag-for-review signal.

## 2. Remote table (client → server)

"At 1000/s" means what actually happens past the bucket: every excess call
is dropped after one token-bucket check and, at most, one throttled report.
"Best gain" is the most an attacker gets with full control of the payload.

| Remote | Caller / states | What it does | Malformed payload | At 1000/s | Best gain |
|---|---|---|---|---|---|
| `TaskInteract` | any player / Race | Starts a server-issued challenge if the station is assigned, incomplete and within `INTERACT_RANGE_STUDS` of the **server-side** root | dropped by schema | 5 burst, 1/s | Restart their own challenge (a fresh random code) |
| `KeypadDigitSubmit` | session owner / Race | One digit against the server-held code | dropped | 10 burst, 5/s | None. A wrong digit resets their own progress |
| `TapSubmit` | session owner / Race | One valve tap | dropped | 20 burst, 20/s, plus the handler's own `MIN_TAP_INTERVAL` | None. Tap rate is capped by the handler, not the remote |
| `FuseDropSubmit` | session owner / Race | One fuse→slot placement against a server mapping | dropped | 10 burst, 3/s | None |
| `TaskAbort` | session owner / any | Ends their own session if `attempt` matches | dropped | 5 burst, 1/s | Cancel their own task |
| `PowerUpUseIntent` | roster racer / Race | Uses a held item. Inventory, cooldown, target, range, cone and `mayAct` are all checked on the server | dropped | 5 burst, 1/s | Pick a target among those already legal |
| `DecisionChooseIntent` | qualifier / DecisionStudio, phase Choose | Locks Steal/Share once; locks are final | dropped (`stringEnum`) | 3 burst, 0.5/s | None beyond their own honest choice |
| `StudioChatTypingIntent` | qualifier / DecisionStudio, phase Negotiate | "X is typing" sent to the other qualifiers | dropped (`struct({})`) | 3 burst, 1/s | A fake typing indicator (cosmetic) |
| `TitleEquipIntent` | any / any | Equips an **owned** title | dropped | 5 burst, 1/s | None. Ownership is checked against the profile |
| `StorePurchaseIntent` | any / any | Opens a Roblox purchase prompt for an enabled catalogue key | dropped | 4 burst, 0.5/s | A prompt for themselves. Nothing is granted here |
| `StoreEquipIntent` | any / any | Equips an owned cosmetic into a slot the category allows | dropped | 6 burst, 1/s | None |
| `StoreLoadoutIntent` | any / any | Places stocked power-ups into loadout slots. Stock is spent only in `consumeLoadout`, which re-checks it | dropped | 6 burst, 1/s | None |
| `QueueJoinIntent` / `QueueLeaveIntent` | hub player / any | Matchmaking queue membership (MemoryStore) | dropped | 3 burst, 0.5/s each | Queue churn, bounded to about 1 MemoryStore write per 2s |
| `MapVoteIntent` | group member with a live ballot / any | Casts a vote through a CAS on the group record | dropped | 4 burst, 1/s | One vote, changeable. See F7 for quota cost |
| `SettingsIntent` | any / any | Patches their own settings. Bounds come from the schema | dropped | 8 burst, 2/s | Their own settings |
| `DebugForceRoundState` | Studio or `DEVELOPER_USER_IDS` (empty) / any | Forces a state transition | dropped | 3 burst, 0.2/s | **Nothing in live.** Refused and logged. See F6 |
| `DecisionDebugForceOutcome` | Studio only / any | Forces a finale branch | dropped | 3 burst, 0.2/s | **Nothing in live.** See F6 |
| every `ServerBroadcast` (30) | nobody | — | dropped: no schema | dropped (F2b) | Nothing |

Server-driven inputs that are not remotes:

| Input | Trusted? | Notes |
|---|---|---|
| `MarketplaceService.ProcessReceipt` | Yes (engine) | F1 |
| `PromptGamePassPurchaseFinished` | **No.** Treated as a hint | Ownership is always re-checked with `UserOwnsGamePassAsync`. See F5 |
| `TeleportData` (join) | **No** | Only read to (a) pick a return message from a fixed table and (b) choose a map during a MemoryStore outage, limited to enabled maps (F8). Streak, bounty and currency are never read from it |
| Power-up `Touched` | **Was yes, now no** | F3 |
| Character position | Measured server-side | Speed hacks are detected, not reversed. See §5 |
| `TextChatService` Studio channel | Gated by `ShouldDeliverCallback` | Only qualifiers, only during Negotiate |

## 3. Required verifications

| Claim | Result | Evidence |
|---|---|---|
| No task completes without the server-issued challenge | **Holds** | `TaskHandlerService.handleSubmission`: an active server session is required, then assignment, server-side range, a minimum plausible elapsed time, and the handler's `validate` against server-held state. Nothing on the client can mark a task done; the only caller of `TaskService.recordCompletion` is that path. A submit type that doesn't match the task (e.g. `TapSubmit` to a keypad) only resets the sender's own progress |
| No power-up without ownership, cooldown, range and state | **Holds** | `PowerUpService.useFor`: inventory slot, `isOnCooldown`, `resolveTarget` (range and cone from the server-side root), `mayAct`, plus NetGuard's Race gate. **Acquiring** a power-up was the gap (F3, fixed) |
| No Decision Studio choice readable before the reveal | **Holds** | Choices live only in `DecisionService`'s upvalue `choices`. `DecisionLockedIn` carries `playerId` only. NPC choices are rolled independently of chat lines and lock-in timing (`NPCBrain`). There are no attributes, replicated instances or preloaded outcome assets. The only per-choice log line is server-side `warn`. Info: F9 |
| No streak, bounty or currency accepted from the client or TeleportData | **Holds** | No intent schema carries any of them. `currentStreak`/`bestStreak` are written only by `DataService` from `ProgressionLogic` results, and `currency` only by `DataService`/`StoreService` from catalogue grants. The bounty tier is computed from the server-held streak |
| No purchase grants twice or grants without a confirmed write | **Failed, now fixed** | F1. Double-grant was already prevented by the PurchaseId cache. "Without a confirmed write" was broken |
| No DataStore key from client data | **Holds** | Profiles are keyed `tostring(UserId)`. Leaderboard keys come from `PeriodKeys` (server clock) and `userId`. MemoryStore group keys come from `PrivateServerId` or a server-minted `groupId`. `MapVoteIntent.mapId` is only ever a **value** checked against enabled maps, never a key |

## 4. Findings, ranked by exploitability × damage

Scores run 1–5 on each axis.

| # | Finding | Expl. | Dmg | Score | Status |
|---|---|---|---|---|---|
| F1 | Receipt save confirmation never matched, and a replay confirmed unsaved grants | 3 | 5 | **15** | **Fixed** |
| F2 | Junk payloads bypassed the rate limiter, and every rejection was an unthrottled `warn` with an unbounded payload walk | 5 | 3 | **15** | **Fixed** |
| F3 | Power-up pickups trusted client-reported `Touched` at any distance | 5 | 2 | **10** | **Fixed** |
| F4 | NetGuard's flag hook is never wired, so repeated violations lead nowhere | 5 | 2 | **10** | **Fixed** (kick on malformed traffic) |
| F5 | Spoofed `PromptGamePassPurchaseFinished` busts the pass cache, costing one `UserOwnsGamePassAsync` per pass per spoof | 2 | 2 | 4 | **Fixed** |
| F6 | Debug remotes write real finale results for allow-listed IDs in live servers | 1 | 4 | 4 | **Fixed** (forced finale is Studio-only) |
| F7 | `MapVoteIntent` costs one MemoryStore `UpdateAsync` per accepted call, including "Unchanged" votes | 3 | 1 | 3 | **Fixed** |
| F8 | During a MemoryStore outage, the map comes from client-carried `TeleportData` (enabled maps only) | 1 | 1 | 1 | Accepted |
| F9 | NPC chat lines come from per-personality pools in replicated config, so a player can infer an NPC's steal *probability* (not its choice) | 3 | 0.3 | ~1 | Accepted, by design |

### F1: Purchases could be confirmed without a saved write (fixed)

`StoreService.waitForSave` passed `handle.getLastSavedData()` (the **whole
profile snapshot**) into `StoreLogic.isPurchaseSaved(savedCache: {string}?)`.
A `:: any` cast hid the type mismatch. `table.find` over a dictionary always
misses, so no receipt was ever seen as saved:

1. First attempt: the grant is applied in memory, the wait always times out,
   and the result is `NotProcessedYet`.
2. Roblox retries while the player is still in session. `classifyReceipt`
   finds the id in the **in-memory** cache → `AlreadyGranted` →
   `PurchaseGranted`, with no save confirmed.

If the server died before the next autosave, the player had paid, Roblox
considered the purchase done, and the item was gone. The same `AlreadyGranted`
path had the gap on its own, even with correct extraction. It is also a
purchase-UX bug: every first attempt stalled for `receiptMaxWaitSeconds`.

**Fix:** `StoreLogic.savedPurchaseIds(snapshot)` extracts and type-checks
the cache at all three call sites. The new `StoreLogic.answerReplay` makes an
`AlreadyGranted` receipt confirm only when the id is in `LastSavedData`. It
otherwise waits for a save while the profile is active, or declines. This
matches ProfileStore's reference `PurchaseIdCheckAsync`
(`profilestore/docs/devproducts/index.md`). `LastSavedData` is seeded from the
loaded data (`ProfileStore.luau:1048`), so a genuine cross-session replay still
confirms immediately.

**Tests:** `StoreLogic.savedPurchaseIds (P8-1)`, including the regression
case "the whole snapshot is never mistaken for the cache", and
`StoreLogic.answerReplay (P8-1)` in `tests/StoreLogic.spec.luau`.

### F2: Unthrottled junk and log flood through NetGuard (fixed)

The bucket ran **last**, after shape and state. A malformed or wrong-state
call never touched it, so a junk flood was unlimited. Each junk call also
paid for:

- a `warn`, so 1000/s produced 1000 log lines/s;
- a recursive `estimatePayloadSize` over whatever table the attacker sent.

**Fixes:**

- The bucket now runs first. Every call, well-formed or not, spends the
  remote's budget.
- Reports go through a per-player budget (10 burst, 1/s). Suppressed reports
  are counted and the total rides on the next report that gets through.
- `Net.estimatePayloadSize` is capped at 4096 bytes and 8 levels deep.
- Events arriving after `PlayerRemoving` are dropped, so they no longer
  re-create (and leak) per-player state.
- **F2b:** every `ServerBroadcast` now has a drop listener, so a client
  firing one no longer triggers Roblox's per-call "invocation queue
  exhausted" warning.

**Tests:** `Net.estimatePayloadSize (P8-1: bounded)` in
`tests/Net.spec.luau` covers the cap, the depth limit and exact sizing of
ordinary payloads. The bucket-first ordering and the report throttle live in
the Roblox-bound service and need the Studio check in §6.

### F3: Remote-distance power-up pickups (fixed)

A player's own character is simulated on their client, so `Touched`
against it is client-reported. An exploit can "touch" every pickup on the
map from spawn. That lets it:

- fill its inventory at once, capped by slot count;
- starve all five opponents of pickups for the respawn window.

**Fix:** `tryClaimPickup` re-measures the server-side root-to-pickup
distance against `PICKUP_REACH_STUDS = 10` through the pure
`PowerUpLogic.isWithinPickupReach` before claiming.

**Test:** `PowerUpLogic.isWithinPickupReach (P8-1)`.

### F4: Violations were counted but never acted on (fixed)

`NetGuard.setFlagHandler` is never called, so a flagged player only
produced a `warn`. `threat-model.md` §1 says repeated violations
"escalate to a kick", while NetGuard's header said it never kicks.

**Fix:** NetGuard now kicks on **malformed traffic only**: 5 calls within
10s that fail their schema or hit a server-to-client remote. Client and
server always run the same place version, so the real client never
produces either. Every client send was checked: all go to intent remotes,
and settings values are clamped by `SettingsLogic.apply` inside the
schema bounds. Wrong-state and over-rate calls still only flag, because a
legitimate player can trip them: a tap in flight as the race ends, or a
very fast masher.

**Test:** the window-and-threshold logic is `Net.recordViolation`, already
covered in `tests/Net.spec.luau`. The kick itself needs the Studio check
in §6.

### F5: Spoofed game-pass signal amplification (fixed)

`PromptGamePassPurchaseFinished` can be spoofed, and each signal busted the
ownership cache and triggered a sync, costing one `UserOwnsGamePassAsync`
per pass.

**Fix:** syncs are coalesced to at most one per player per 10s. The pure
`StoreLogic.passSyncDelay` defers a sync inside the cooldown and never drops
it, so a real purchase right after a spoof is still picked up. The cache is
busted only when the sync runs, for every pass id that arrived meanwhile.

**Test:** `StoreLogic.passSyncDelay (P8-1 F5)`.

### F6: Forced finale outcome in live servers (fixed)

A forced branch runs the real `computeOutcomeAndWriteProfiles`, so an
allow-listed (or stolen) dev account could mint real streaks. Skipping the
writes isn't safe: each qualifier's pending-outcome resolver would then
record a forfeit, and reset their streak, when they left.

**Fix:** `DecisionDebugForceOutcome` is now **Studio-only**, and the unused
`DEBUG_USER_IDS` allow-list is removed. `DebugForceRoundState` keeps its
live allow-list (still empty), because a forced transition decides no
finale outcome by itself.

### F7: MemoryStore write per vote (fixed)

**Fix:** `VoteService.onVoteIntent` now runs `VoteLogic.castVote` against the
cached `session.record` first. Every refusal (not a member, not on the
ballot, locked, unchanged) returns without a MemoryStore request. Votes
that pass still go through the live CAS. `castVote` is already covered in
`tests/VoteLogic.spec.luau`.

## 5. What can't be fixed server-side: detection and reversal

| Threat | Why it can't be prevented | Detection today | Proposed reversal |
|---|---|---|---|
| Speed/teleport hacks between stations | The client owns its character's physics | `MovementWatch` scores excess speed against `StatusEffects`' resolved stats. **Log-only by design** (P2-9, `movement-watch-notes.md`) | When a racer reaches `movementViolationActThreshold` in a round: void their task completions for that round, so they can't qualify, and mark the round result "under review" before any streak write. Enforcement is deliberately a separate decision. See `movement-watch-notes.md` |
| Perfect macros / auto-solvers (the keypad code is shown to the client by design) | A correct answer at a human-plausible rate is indistinguishable per call | The `MIN_PLAUSIBLE_COMPLETION_FRACTION` floor per task | Offline: flag accounts whose completion-time distribution is too tight across sessions (Telemetry task timings). Reverse by resetting streaks and removing leaderboard rows |
| Collusion in the Decision Studio (alt accounts, Discord) | It is a social game, and choices are legitimately free | Repeated co-qualifier pairs across rounds (Telemetry) | Leaderboard review. No automatic reversal, since false positives would punish friends |

## 6. Manual Studio check for the service-level fixes

These can't be run headlessly because they bind to Roblox instances:

1. **F2:** in a Studio server, run
   `for i = 1, 5000 do Remotes.TapSubmit:FireServer({ stationId = "x" }) end`
   from the client command bar. The payload is well-formed, so there's no
   kick. Expect at most 10 NetGuard warns, then about 1/s, each with a
   "+N similar suppressed" suffix.
2. **F4:** run `for i = 1, 5 do Remotes.TapSubmit:FireServer("junk") end`.
   Expect a kick with the "sent data this game doesn't accept" message.
   Rejoin and repeat with `Remotes.RoundState` in place of `TapSubmit`:
   expect the same kick, and no "invocation queue exhausted" warning.
3. **F3:** during a race, fire `firetouchinterest`-style touches, or move a
   pickup 50 studs from the character on the server. Expect no inventory
   change.
4. **F1:** set `receiptMaxWaitSeconds` to 0 and buy a dev product in Studio.
   Expect the first attempt to decline, the retry to wait for a save, and
   "already granted and saved" in the log only after it lands.
