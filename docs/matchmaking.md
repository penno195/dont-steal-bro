# Don't Steal Bro! — Cross-Server Matchmaking (P5-1)

How the Hub's queue forms groups across servers, why a player can
never be put in two groups at once, and what happens in each failure
case. Code: `src/server/MatchmakingLogic.luau` (pure, tested by
`tests/MatchmakingLogic.spec.luau`) and
`src/server/Services/MatchmakingService.luau` (the MemoryStore
wrapper). Config: `GameConfig.matchmaking`.

## Scope decisions

- **No streak priority.** The P5-1 prompt asked for priority re-queue
  for players on an active streak. `design-decisions.md` Q6 rules it
  out ("normal requeue — no priority ticket"), and the owner confirmed
  Q6 stands. The streak is still stored on every queue entry
  (`Entry.streak`), so Q6's "priority can be added later as a flag"
  stays cheap.
- **Re-match cooldown included.** `architecture.md` §7's collusion
  mitigation: players grouped together are kept apart for
  `rematchCooldownSeconds`. The cooldown is **never relaxed** to fill a
  group. On a quiet server the fallback is NPC seats, which already
  earn reduced streak credit. Relaxing it would reopen collusion exactly
  when it is easiest, and Q7 condition 2 ("matchmaking is fully
  random") depends on it staying closed.

## Data in MemoryStore

| Structure | Key | Value | TTL |
|---|---|---|---|
| SortedMap `MatchQueue_v1` | userId | `Entry` (state, owner jobId, enqueuedAt, streak, avoid list, groupId) — **sort key = enqueuedAt** | `entryTtlSeconds`, refreshed by the owner |
| HashMap `MatchGroups_v1` | groupId (GUID) | `GroupRecord` (members, npcSlots) — **the commit point** | `groupRecordTtlSeconds` |
| HashMap `RecentOpponents_v1` | userId | recent co-players + expiry | `rematchCooldownSeconds` |
| HashMap `MatchmakingMeta_v1` | `formationLease` | `{ holder = jobId }` | `leaseTtlSeconds` |

## Why a player can't be double-booked

Entry states: `Waiting → Claimed(G) → Departed(G)`, with
`Claimed(G) → Waiting` (release) and `→ Left` (the owner leaving).
Every change is an `UpdateAsync` compare-and-set whose transform
refuses unless the entry is in exactly the expected state **with the
expected token**.

1. **One key decides.** Claiming a player means turning their entry
   from `Waiting` to `Claimed(G)`. MemoryStore applies `UpdateAsync`
   to one key atomically: on conflict it re-runs the transform against
   the new value. If two servers race, the second transform sees
   `Claimed` and refuses. Only one token fits in the entry, so a player
   is claimed by at most one group at a time.
2. **Membership needs two things.** A player goes with group G only if
   their entry says `Claimed(G)` **and** G's group record exists. The
   owning server checks both, then compare-and-sets
   `Claimed(G) → Departed(G)`, and only then hands the player to the
   teleport. `Departed` is final, so nothing can claim that player
   again.
3. **No clock comparison between servers.** Claims carry no expiry
   timestamp. A claim is judged stale by the owning server, using its
   own `os.clock`, measured from when it first saw that token.
   Wall-clock time is only read for the partial-group timer and the
   rematch cooldown, where a few seconds of skew between servers just
   shifts them slightly.

The formation lease stops every hub server fighting over the same six
entries every tick. It is only an efficiency measure: nothing above
depends on it.

## Failure cases

**Two servers try to form a group at once.** Normally only the lease
holder forms groups. If the lease lapses and two servers both form,
each claims entries one by one and the per-key compare-and-set decides
each contested player. A former that loses any claim releases every
claim it made (token-checked, so it can't undo the other server's
claims). The other former completes, and the loser's players go back
to `Waiting` at their original place, because `enqueuedAt` and the
sort key never change. Worst case: one group forms a tick later.

**A player leaves between claim and teleport.** `PlayerRemoving`, or
the leave intent, compare-and-sets the entry to `Left`.
- *Before commit:* the entry is gone from the group. The group record
  may still be written with them listed, but their owner will never
  depart them, so the group arrives one short. The match server
  already refills empty seats with NPCs after its grace window
  (`architecture.md` §4). The other five still play.
- *After depart:* the leave intent is refused ("your match is already
  on its way"). A disconnect at that point is P5-2's problem, and the
  match server treats them as a no-show.

**A MemoryStore outage.** Every call is wrapped in `pcall`.
- *Joining* fails with a clear "couldn't reach matchmaking" message
  and the player can try again.
- *Players already queued* keep their local ticket, which remembers
  `enqueuedAt`. After `unavailableAfterFailures` failed reads, the UI
  says matchmaking is having trouble but they're still in line. The
  tick backs off exponentially, up to `backoffCapSeconds`.
- *If the outage outlasts `entryTtlSeconds`,* entries expire. When
  MemoryStore returns, the refresh loop re-creates each one at its
  original `enqueuedAt`, so no one loses their place.
- *An outage partway through forming:* the former rolls back what it
  can. Any claim it couldn't release is reverted by the owner after
  `staleClaimRevertSeconds`.
- *A call that errors but actually succeeded* (a timeout after the
  write) is safe, because every transform is token-checked and every
  caller tolerates a write it doesn't know about.

**A server crashes while holding claims.**
- *The former crashes after claiming, before commit:* no group record
  appears. Each owner sees its player stuck in `Claimed(G)` and reverts
  them to `Waiting` after `staleClaimRevertSeconds`, at the same place.
- *The former crashes after commit:* the record exists, and every
  owner departs its players as normal. The group is only short the
  former's own players, who were on the server that died.
- *An owner crashes:* its entries stop being refreshed and expire
  within `entryTtlSeconds`. If one is claimed in that window, the
  group arrives short and gets NPC fill.
- *A clean shutdown* (`BindToClose`) marks its players' entries `Left`
  immediately.

**A former stalls past its own deadline** (a GC pause or yield). The
former abandons any group it couldn't commit within
`claimCommitDeadlineSeconds`, and owners wait longer
(`staleClaimRevertSeconds`) before reverting. Validation enforces that
ordering at boot. Even if it is broken, the result is at most a short
group, never a double booking. The spec's "stalled former" case pins
that down.

## Timing orderings (enforced by `Validate.checkMatchmakingConfig`)

These protect liveness (the queue keeps moving). None of them affects
the no-double-booking guarantee.

- `refreshIntervalSeconds × 2 < entryTtlSeconds`: one missed heartbeat
  can't drop a live player.
- `claimCommitDeadlineSeconds < staleClaimRevertSeconds`: owners don't
  revert claims that are about to commit.
- `groupRecordTtlSeconds > staleClaimRevertSeconds`: a slow owner still
  finds the record.
- `leaseTtlSeconds > formationTickSeconds`: the lease doesn't change
  hands every tick.
- `groupSize == playerCount`, and `queuePageSize` is between
  `groupSize` and 200.

## MemoryStore limits this is designed against — VERIFY before launch

From create.roblox.com's memory-stores guide, read on 2026-09-22.
Confirm each against current documentation and record the result
here, the same way `leaderboard-scale.md` does for DataStores.

| Limit | Value used | Where it matters |
|---|---|---|
| Request units | 1000 + 120 × CCU per minute, experience-wide | Budget below |
| `GetRangeAsync` cost | 1 unit per returned item (min 1) | The dominant cost |
| `UpdateAsync` cost | minimum 2 units | Claims, refresh, lease |
| Memory | 64 KB + 1.2 KB × CCU | Entries are ~200 B plus the avoid list |
| Value size | 32 KB | Avoid list capped at `recentOpponentsCap` |
| Expiration | ≤ 3,888,000 s | Checked in validation |
| `GetRangeAsync` max count | **assumed 200** | `queuePageSize` cap in validation |
| **Per-partition limits** | **not read** — the guide links a separate page | One SortedMap may sit on one partition, which would cap total throughput regardless of CCU |

**Semantics this relies on**, also to verify:
- A transform returning `nil` **cancels** the update. The sorted-map
  guide says returning nil stops the retries. `LeaderboardService.luau`
  once claimed nil *deletes* the entry. That comment was corrected
  alongside P5-1, together with its transform, which wasn't returning
  a sort key.
- `UpdateAsync` re-runs the transform on a concurrent conflict (the
  guide says it "automatically retries").
- `GetRangeAsync` breaks sort-key ties by key.
- A sorted-map transform receives `(value, sortKey)` and returns
  `(value, sortKey)`. The service always returns both explicitly.

**Budget sketch.** Each hub server spends about 30 page reads per
minute × up to `queuePageSize` items, plus about 30 lease attempts
(≥2 units each), plus 3 refreshes per queued player per minute
(≥2 units each). At the full 200-item page that is ~6,000 units/min
per hub server, which the 120 × CCU allowance only covers with roughly
50+ players per hub server. If the numbers are tight in practice, the
first levers are:
- lengthen `formationTickSeconds`;
- have non-lease servers read a smaller page (they only need their own
  players' positions);
- have the lease holder publish one summary key instead.

## Studio verification

The service runs in Studio when `hubPlaceId = 0`. MemoryStore needs
the place published, with Studio API access enabled.

1. Run "Clients and Servers" with 6 players and have all of them press
   Join. One group forms within about one tick. The warning log shows
   `group … formed (6 humans, 0 NPC slots)`, and each client receives
   `MatchFound`.
2. Run the same test with 2 players and wait `partialGroupTimeoutSeconds`.
   The log should show a partial group with 4 NPC slots.
3. Have one player Leave, then Join again. `QueueState` shows the new
   position, and double-tapping Join doesn't change it.
4. Form a group, re-queue the same players and wait. No group forms
   until the partial timer, and then everyone gets a solo partial
   group. That is the rematch cooldown working.
5. Kick a player while the group is claimed (lower
   `claimCommitDeadlineSeconds` and add a yield to reproduce). The group
   forms one short, or rolls back. The player is never listed as
   departing from two groups.

The 12-account gate (two matches, correct streaks, no lost profiles)
is Phase 5's exit criterion and needs P5-2's teleport.

## Hooks for P5-2

- `MatchmakingService.setDepartureHandler(fn(players, group))`
  replaces the placeholder handler, which only reports `MatchFound`.
  `fn` receives this server's members of the group, which can be fewer
  than `group.members`.
- `MatchmakingService.requeue(player, enqueuedAt?)` is the
  teleport-failed path. Passing the original `enqueuedAt` preserves the
  player's place.
- `DataService.isLoaded(player)` gates joining, so nobody can be sent
  to a match before their session lock exists on the hub.
