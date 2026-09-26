# Don't Steal Bro! — Hub-to-Match Teleport (P5-2)

How a formed group gets from the Hub to a reserved Match server, what
happens when that fails, and why nothing the client can touch changes
what the match server does. Code: `src/server/TeleportLogic.luau` (pure,
tested by `tests/TeleportLogic.spec.luau`) and
`src/server/Services/MatchTeleportService.luau`. Config:
`GameConfig.teleport`, plus `npc.fillGraceSeconds` as the arrival window.

## The flow

1. **Reserve before claiming.** A group can span several hub servers,
   and only the server that calls `ReserveServerAsync` learns the access
   code. So the *former* reserves (MatchmakingService's destination
   provider) before it claims anyone. The reserved server's
   `PrivateServerId` becomes the group id, and the access code and map
   id go into the group record. If the reservation fails, nobody has
   been claimed and formation is retried on a later tick. If a claim
   fails after reserving, the reserved server is never used, which is
   harmless because a reserved server doesn't start until someone
   arrives.
2. **Each owner sends its own players.** Every hub server that departs a
   member reads the same record, so all of them `TeleportAsync` to the
   same access code. Each server sends its local party in one call.
3. **The match server finds its own record.** It reads
   `MatchGroups_v1[game.PrivateServerId]`, which is the *manifest*.
   Members, map and NPC slots all come from there. The TeleportData
   hint is compared against the manifest and any mismatch is logged
   (threat-model.md §5).
4. **The arrival gate.** The round stays in `WaitingForPlayers` until
   `TeleportLogic.gateDecision` says Start, and then requests `Loading`.
   NPCService fills the empty seats from the humans it can see.

MatchmakingService refuses to form groups until the provider is
installed whenever teleporting is configured. Otherwise a fresh hub
server could form a destination-less group in the moment between its
tick loop starting and this service's `start()`.

## Retry and failure handling (hub)

Each attempt ends in exactly one of three ways: TeleportInitFailed
fires, `TeleportAsync` throws, or the **travel watchdog**
(`travelWatchdogSeconds`) fires while the player is still on the hub.
A per-player token makes sure only the first of those to arrive is
acted on. `TeleportLogic.classifyFailure` then decides:

| Reason | Verdict | Player sees |
|---|---|---|
| `Failure`, `Flooded`, `Timeout`, `Error` | Retry to the same server, backoff `retryBaseSeconds × 2^(n-1)` capped at `retryCapSeconds`, up to `maxAttempts` | "…Trying again…" |
| same, on the last attempt | Requeue | "…You're back in the queue at your old place." |
| `GameFull`, `GameEnded`, `GameNotFound`, `Unauthorized` | Requeue immediately (retrying that server can't help) | reason-specific, plus the same suffix |
| `IsTeleporting` | Wait (the watchdog is still armed) | nothing new |
| anything unrecognised | Requeue | generic, plus the suffix |

**Requeue** is `MatchmakingService.requeue(player, nil, message)`. The
Departing ticket still holds `enqueuedAt`, so the fresh entry goes in at
the original sort key. `MatchmakingLogic.join` accepts a write over the
player's own `Departed` entry. The rematch cooldown recorded when the
group formed still applies, so a requeued player won't be regrouped
with the same people. They get other players or NPC seats.

**Nobody is stranded.** Roblox returns a client to the hub when a
teleport fails. The watchdog covers the case where no failure event
ever arrives. The worst case is a requeue that loses a race with a
teleport that finally completes. The player then leaves the hub
(`PlayerRemoving` marks their entry `Left`), and the match server
admits them if its gate is still open, or sends them home otherwise.

## Arrival (match server)

**Admission** (`TeleportLogic.admission`):
- The gate is closed (the round has started): **Late**. They're sent
  home with a fixed message. The seats are settled and NPCs have filled
  them.
- The manifest is known and doesn't list them: **Stray**, sent home.
- Otherwise they're admitted. With no manifest (a MemoryStore outage),
  the reserved server's access code is the only gate. Only our own
  servers can send anyone to a reserved server.

"Sent home" means `TeleportAsync` to `hubPlaceId` with
`{ returnReason = "Late" | "Stray" }`, and a `Kick` with the same
message if that fails or no hub place is set. The hub maps the reason
to one of its fixed strings (`TeleportLogic.returnMessage`), so a
forged reason can't put text on screen.

Every match also ends this way: at `Cleanup`, everyone still on the
server is sent home together with `returnReason = "RoundOver"`
(`MatchTeleportService.sendEveryoneHome`). In Studio they respawn
instead.

A public (non-reserved) server of the match place never runs a round:
everyone who joins one is sent home.

**The gate** (`TeleportLogic.gateDecision`, polled every 0.25s once
the manifest read has settled):
1. Everyone expected is here and loaded: **start now**.
2. Before `npc.fillGraceSeconds` (architecture.md §4's ~10s): wait.
3. Nobody came: **abandon**. No round runs, and the empty server shuts
   itself down.
4. Someone's profile is still loading: wait up to
   `profileLoadGraceSeconds` more (see session locks below).
5. Otherwise, **start short**. NPCService derives the bot count as
   `playerCount − humans present`.

The gate *is* the grace window, so it calls
`NPCService.markArrivalGraceServed()` before requesting Loading, and
bots spawn at once instead of after a second 10s wait. Studio's debug
path still waits.

**The fewer-than-expected rule, in one line:** the round starts with
whoever made it by the end of the grace window, NPCs take the empty
seats, and anyone arriving after that is sent back to the hub. This
decides no streak question. A no-show or a late arrival never played,
so no round outcome is written for them either way.

## Profile session locks

The hub **cannot** release a profile before the teleport: a failed
teleport brings the player back, still needing their data. It releases
on `PlayerRemoving`, which fires once the player has left for the
match. That leaves a window where the match server asks for a profile
the hub still holds. ProfileStore 1.0.3 handles this itself (read from
`ProfileStore.luau` in `ServerPackages`):

- the waiting server messages the holder over MessagingService to save
  and end its session;
- it re-reads after `FIRST_LOAD_REPEAT` = 5s, then every
  `LOAD_REPEAT_PERIOD` = 10s;
- it steals the lock after `SESSION_STEAL` = 40s if the holder never
  answers, which means the holder is dead.

`DataService.loadProfile` passes `Cancel`, which disables ProfileStore's
start timeout, so the match server keeps waiting instead of kicking.
The arrival gate counts a player as ready only once `isLoaded`. This
covers the normal case, where the hub releases within about 5s.

**The race where the hub doesn't release:** the profile loads after
the round has started, at the latest when the lock is stolen at 40s.
The player is on the roster, can race, and has their result written
once the profile is present. If the load fails outright, DataService
kicks them with its existing "still saving" message. A steal discards
whatever the dead hub hadn't autosaved. That is ProfileStore's accepted
trade-off, and a hub that crashed mid-teleport has nothing newer than
its last save anyway.

## TeleportData tampering

TeleportData passes through the client, so treat every field as
attacker-chosen. What the hub sends:
`{ v, groupId, mapId, npcSlots }`. What the match server does with
each field:

| Tampering | Why it's harmless |
|---|---|
| Change `groupId` to another group's id | The manifest is looked up by the server's **own** `game.PrivateServerId`, never by the hint. A mismatch is only logged (`GroupIdMismatch`). |
| Change `npcSlots` (e.g. 0 to dodge bots, 5 to farm them) | NPCService never reads it. The count is `playerCount − humans present`, as architecture.md §4 requires. It is only logged (`NpcSlotsMismatch`). |
| Change `mapId` to a favourite map | The manifest's map wins. The hint is consulted only when the manifest is unreadable, and even then only if it names an **enabled** map, which is one the group could have been given anyway. |
| Set `mapId` to garbage, a disabled map or a huge string | It isn't in the enabled list, so a random enabled map is used (`Fallback`). |
| Send a non-table, a wrong version, NaN numbers | Flagged (`NotATable`, `BadVersion`, `NpcSlotsMalformed`) and ignored. Every read is type-checked first. |
| Drop TeleportData entirely | Flagged `Missing`. Nothing depends on it. |
| Add streak / bounty / currency fields | Nothing reads them. Streak and bounty come only from the ProfileStore profile (DataService header, threat-model.md §5). |
| Join a different group's reserved server | Impossible from the client: access codes live only in MemoryStore. If it happened, the manifest wouldn't list them, so **Stray**, sent home. |
| Forge a `returnReason` when arriving at the hub | It can only select one of three fixed messages. Anything else is ignored. |
| Replay an old hint later | It carries nothing trusted, and a Late arrival is sent home. |

## Limits and APIs to VERIFY before launch

- **`TeleportService:ReserveServerAsync` return order.** The pinned
  `globalTypes.d.luau` types it `...any`. The code assumes
  `(accessCode, privateServerId)`, like the older `ReserveServer`, and
  refuses anything that isn't two non-empty strings, so a wrong
  assumption fails closed: no groups form. Confirm against the
  current docs.
- ReserveServer rate limits (not read). One call per formed group, plus
  one per failed formation attempt by the lease holder.
- `TeleportAsync` batch limits and TeleportData size limits (not read).
  The hint is under 200 bytes.
- `Player:GetJoinData()` on the server. Confirmed in the pinned types
  (`TeleportData`, `SourcePlaceId`), but confirm the recommended
  pattern.
- `game.PrivateServerOwnerId == 0` as the reserved-server test (vs a
  VIP server). This is the long-standing documented pattern, but
  recheck it.
- ProfileStore's constants above were read from the pinned 1.0.3
  source, not from docs.

## Not in this task

- **Map loading.** No service loads a map yet (TaskService and
  PowerUpService already document the gap). The chosen map is exposed
  as `MatchTeleportService.getMapId()` for whatever loads it.
- **Voting (P5-3), since landed.** The departure handler runs
  `VoteService.runVote` before teleporting, and the winner is written
  into the group record before anyone departs. `pickMap` only remains
  for groups with nothing to vote on (fewer than two enabled maps). See
  `docs/voting.md`.
- **Match → hub return after Results.** That is part of the Phase 5
  gate, but not of this prompt.
- **Queue UI.** The client has no QueueState consumer yet. The new
  statuses are `Travelling` (with a message) and `Idle`/`Waiting` with a
  requeue or return message.

## Verification on a published place

Teleports don't run in Studio: with `matchPlaceId = 0`, or in Studio,
the service is inert and P5-1's placeholder handler stays in place.
Set `hubPlaceId` and `matchPlaceId`, publish both places, then:

1. Six accounts queue, all arrive together, and the round starts before
   the 10s window ends (log: `starting with 6 human(s)`).
2. Two accounts queue and wait out the partial timer. They arrive, the
   round starts at about 10s, and 4 NPCs spawn at once.
3. Close one client during the teleport. The rest start at the grace
   deadline with one NPC more.
4. Set `matchPlaceId` to a place outside the universe to force
   `Unauthorized`. The client stays on the hub and sees the message,
   the entry is back at its original position, and nobody is stuck on a
   loading screen.
5. Join the match place's public server directly. You are sent to the
   hub with no round started.
