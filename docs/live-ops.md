# Live ops: tuning and kill switches (P8-5)

How to change the game after launch without shipping an update: tune
values, switch content off, roll changes out to a share of servers, and
stop anything that costs money or could damage data.

| Piece | File |
|---|---|
| Rules (resolution, validation, commands, audit), headless-tested | `src/server/LiveConfigLogic.luau`, `tests/LiveConfigLogic.spec.luau` |
| DataStore read/refresh, applying config, admin chat command | `src/server/Services/LiveConfig.luau` |
| Settings and the allowlist of tunable paths | `GameConfig.liveOps` in `src/shared/Config/GameConfig.luau` |

## The one rule

**A bad live config must never brick a server.** Every server resolves
its config as *staged (if in the rollout) → active → shipped defaults*,
taking the first layer that passes the **same** validators that run at
boot (`Validate.run`, plus effect bounds). A layer that fails is skipped
whole. The exception is kill switches: a rejected layer's "switch this
OFF" flags still apply, so an emergency can't be undone by a typo
elsewhere in the same layer.

If a refresh can't read the DataStore, the server keeps its last good
config. If the very first read at boot fails, it runs shipped defaults
until the next refresh succeeds (at most `refreshSeconds`, 60s).

## Before launch

1. Put the developers' Roblox user ids in `GameConfig.liveOps.adminUserIds`.
   While it is empty, nobody can run commands. You can still edit the
   DataStore by hand in the Creator Hub.
2. Turn on API access for DataStores in the experience settings.
3. Studio uses a separate store (`LiveConfig_v1_Studio`), picked
   automatically from `RunService`, so testing a command in Studio can't
   change production.

## Commands

Type in chat: `/liveops <command>`. Non-admins get no reply, and no
audit entry. Replies go to the **server log** (F9 → Server).

| Command | Effect |
|---|---|
| `status` | Active and staged layers, and what this server is running |
| `set <path> <value>` / `unset <path>` | Stage a tunable override |
| `disable\|enable map\|task\|powerup <id>` | Stage a content switch |
| `flag store\|npcfill\|leaderboard\|matchmaking on\|off` | Stage a switch |
| `rollout <0-100>` | Run the staged layer on that % of servers |
| `promote` | Staged becomes active on every server |
| `abort` | Discard the staged layer |
| `kill store\|npcfill\|leaderboard\|matchmaking` | **Immediate**, every server, skips staging |
| `readonly on\|off` | **Immediate**, every server, skips staging |

**Normal changes are staged first.** An edit creates a staged copy of
active at 0% of servers, so nothing changes until you run `rollout`. A
typical change: `set …` → `rollout 10` → watch telemetry → `rollout 50`
→ `promote`. A server's rollout bucket comes from its JobId, so a server
stays in or out of a rollout for its whole life.

**Emergencies skip staging.** `kill` and `readonly` write to active and
staged together, so every server picks them up on its next refresh.
The server you typed on applies them straight away. To switch a killed
feature back on, stage it (`flag store on`, `rollout …`, `promote`),
because turning something back on should be deliberate.

An edit that wouldn't pass validation is refused before anything is
written. Two admins on different servers can't overwrite each other,
because every write is an `UpdateAsync`.

## Audit log

Every change command from an admin (anything but `status` or a parse
error) is appended to the `audit` key: time, user
id, command text, whether it was written, the reply, and the version.
Refused commands are logged too. The log is capped at `auditLogCap`
(200) entries, dropping the oldest first. Read it in the Creator Hub
DataStore manager.

## What each switch does

| Switch | Where | Behaviour when off |
|---|---|---|
| `storeEnabled` | StoreService | No new purchase prompts. `ProcessReceipt` returns `NotProcessedYet`, so Roblox keeps the receipt and redelivers it later. Nobody is charged for nothing. |
| `leaderboardWritesEnabled` | LeaderboardService | All-time and period score writes are skipped. The last-written marker is left alone, so the next write after re-enabling catches up. |
| `matchmakingEnabled` | MatchmakingService | New joins get "paused". No new groups form. Groups that already formed still depart. |
| `npcFillEnabled` | NPCService | No bots. Short groups play short-handed, and design-decisions.md §2 already covers races with fewer than 3 finishers. |
| `readOnly` | DataService | Every profile setter becomes a no-op (streak, bounty, currency, stats, titles, loadout, settings). It also forces the store and leaderboard writes off. ProfileStore keeps autosaving the unchanged data and releasing sessions, which session locks need. |
| disabled map | VoteService, MatchTeleportService | Left out of ballots and random picks. A match server whose voted map was disabled falls back to another. |
| disabled task | TaskService | Removed from station pools at race start. A station with no tasks left is dropped. Boards already dealt are unchanged. |
| disabled power-up | PowerUpService | Stops spawning. A held one can't be used: the use is refused but the item isn't consumed, so it still works if re-enabled. |

Content switches can only turn **off** things that shipped enabled.
Validation refuses a layer that would leave no maps, or a map with no
enabled tasks.

**Read-only mode is lossy by design.** Rounds still play, but their
results aren't recorded, so a win doesn't count and a loss doesn't
reset a streak. It is for a data-corruption incident, not routine
maintenance.

## Tunables

Only the paths matching `GameConfig.liveOps.tunablePaths` can be
overridden. An override has to land on a leaf that already exists with
the same type, and the whole candidate config must still pass
validation. Covered today:

- **Timers:** `game.raceDurationSeconds`, `game.roundTimers.*`,
  `game.studioTimers.*`, `game.powerUpRotationTimers.*`
- **Race shape:** `game.tasksPerPlayer`, `game.qualificationFloorPercent`
- **Bounty:** `game.bountyTiers.<n>.soleStealerVU|loneSharerVU|allShareVU`
- **Power-ups:** `powerUp.<id>.durationSeconds|cooldownSeconds`,
  `effect.<id>.magnitude|durationSeconds`, `game.powerUpUseRangeStuds`
- **NPCs:** `game.npc.**`, `game.npcBrain.**`,
  `map.<id>.npcDifficultyModifier`
- **Matchmaking (per server):** `game.matchmaking.partialGroupTimeoutSeconds`,
  `partialGroupMinPlayers`, `rematchCooldownSeconds`
- `game.telemetry.enabled`

Effects have no registry validator, so `LiveConfig.luau` adds bounds of
its own: values must be finite and positive, and a Multiply can't
change direction. A debuff stays ≤ 1 and a buff stays ≥ 1.

**Deliberately not tunable:** player and qualifier counts, place ids,
MemoryStore names, and matchmaking queue timings (TTLs, leases, the
formation tick). Every hub reads those against one shared queue, and
a partial rollout would run two sets of them at once.

### How a tunable reaches the code

Resolved values are copied leaf by leaf **into** the live `GameConfig`,
power-up, effect and map tables. Services that read config at the
moment they need it see the new value with no code change. **Don't
cache a config scalar at require time**
(`local RACE = GameConfig.raceDurationSeconds`). Capturing a sub-table
(`local config = GameConfig.matchmaking`) is fine.

## Known limits

- **Client-side durations.** The race HUD ring and the Studio phase
  rings take their *full length* from the client's shipped config. The
  countdown number comes from the server's deadline and is always
  right. If you tune `raceDurationSeconds` or a `studioTimers` value,
  the ring starts full (longer) or part-drained (shorter), clamped
  either way. This is cosmetic only.
- **Mid-round changes** apply at each value's next read. For example,
  a round timer changes at the next phase, and task boards change at
  the next race.
- **Replies** only go to the server log. There is no in-game reply UI.

## Studio verification checklist

`LiveConfig.luau` calls DataStoreService and TextChatService, so, like
every service, it is checked in Studio rather than in CI. With API
access on, and your id in `adminUserIds`:

1. Boot. The log shows `LiveConfig: running Defaults v0`.
2. `/liveops status` prints active and staged layers and bucket.
3. `/liveops set game.roundTimers.resultsSeconds 12`, then
   `/liveops rollout 100`. The log shows `running Staged v…`, and the
   next results screen lasts 12s.
4. `/liveops set game.raceDurationSeconds -5` is refused, and nothing
   is written.
5. `/liveops kill store`. A store purchase gets "store is closed".
   Check the `audit` key has the entry.
6. `/liveops readonly on`. Buy/equip/settings changes don't persist
   across a rejoin. Then `readonly off`.
7. Corrupt the `envelope` key by hand (e.g. set it to `"junk"`). The
   server logs issues and runs defaults without erroring.
   `/liveops kill store` still works and replaces the corrupt document.
   Any other command is refused.
8. `/liveops abort`, then `promote`, then `status` all behave as
   described above.

## The five values most likely to change in week one

| # | Value | Why it moves | Covered by |
|---|---|---|---|
| 1 | **Race length** | The first real sessions show whether 300s drags or rushes | `set game.raceDurationSeconds …` ✅ |
| 2 | **Bounty payouts** | P9-2's gate is "the payoff numbers survive contact with real players" | `set game.bountyTiers.<n>.soleStealerVU …` (and `loneSharerVU`, `allShareVU`) ✅, with Validate enforcing the Steal > Share ordering |
| 3 | **NPC difficulty** | At soft-launch player counts most lobbies have bots, and bots that win too often feel unfair | `game.npc.**`, `game.npcBrain.**`, `map.<id>.npcDifficultyModifier` ✅, plus `kill npcfill` as a last resort |
| 4 | **Power-up balance** | One power-up always turns out too strong | `powerUp.<id>.cooldownSeconds`, `effect.<id>.magnitude/durationSeconds` ✅, or `disable powerup <id>` ✅ |
| 5 | **Matchmaking wait** | Low concurrency means long waits for a full group | `set game.matchmaking.partialGroupTimeoutSeconds …` ✅ (per server, so safe in a partial rollout) |

The Decision Studio negotiate window (`game.studioTimers.negotiateSeconds`)
is close behind and also covered.
