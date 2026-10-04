# All-time leaderboard — behaviour at scale (P4-3)

Companion to `src/server/Services/LeaderboardService.luau` and
`src/server/LeaderboardLogic.luau`. This is the answer P4-3 asks for:
what the design does at 1,000 and at 20,000 concurrent players, where
the first limit is hit, and what the mitigation is at that point.

## 0. What must be verified before launch — read this first

**Every Roblox limit below is stated as an assumption, not a fact.**
CLAUDE.md is explicit that platform limits shift and are easy to
misremember, and the numbers here were reasoned about, not looked up
against current documentation. The API *signatures* in
`LeaderboardService` were verified against this repo's pinned
`globalTypes.d.luau`; a type definitions file cannot carry rate limits,
so these could not be checked the same way.

| # | Assumption | Why it matters here | Status |
|---|---|---|---|
| A1 | Per-server request budgets are a formula of the form `base + perPlayer × playerCount`, replenished per minute, **and separate per request type** | The whole soft-ceiling policy assumes reads and writes draw on budgets that behave independently | **Confirmed 2026-10-04.** Separate per type, per minute. Ordered store: Read 60 + 40n, Write 30 + 5n, List 5 + 2n. `budget.perWindow = 60` sits at the Read floor, so it is conservative |
| A2 | `GetSortedAsync` has its own, much smaller budget than ordinary reads | The poll interval was chosen to sit far under it | **Confirmed.** It draws on List: 5 + 2n per server. One call per 60–120s is far under it |
| A3 | There is a per-key write cooldown (order of seconds) | We never write the same key twice quickly, so this should be unreachable — but confirm the figure | **Corrected.** The docs now give per-key throughput, not a cooldown: 4 MB/min write, 25 MB/min read. Unreachable with ~100 B entries |
| A4 | There are universe-wide throughput ceilings (bytes/min, requests/min) distinct from per-server budgets | **This is the one the analysis below concludes you hit first** | **Confirmed, but not the first limit.** Experience-wide ordered-store limits are List 300 + 2 × CCU and Write 300 + 20 × CCU per minute. At 20,000 CCU, §3's ~2,200 `GetSortedAsync`/min is ~5% of the 40,300 List allowance. The first limit is MemoryStore (§9, A7) |
| A5 | `UserService:GetUserInfosByUserIdsAsync` has its own rate limit, separate from DataStore | The name cache is sized against a guess | **Partly confirmed.** The method's reference page gives no figure. A secondary source says 250 results per minute, with HTTP 429 above that. A fresh server resolving the all-time, daily and weekly boards asks for up to 300 ids in its first minute, and a failure caches placeholders for 30 minutes (half `nameCacheTtlSeconds`). Follow-up: spread the lookups and retry sooner |

Checked against create.roblox.com on 2026-10-04: *Data store error
codes and limits*, *Memory stores* and its *best practices* and
*sorted map* guides, and the `MarketplaceService` and `UserService`
references.

`GameConfig.leaderboard.budget` is deliberately config, so a corrected
figure is an edit rather than a code change. And the service consults
`DataStoreService:GetRequestBudgetForRequestType` as the **hard gate**
regardless — that is the engine's own count, so a wrong figure in config
degrades our *policy* (how early reads yield to writes) but cannot
produce a request the engine wouldn't have allowed anyway.

## 1. What the design actually costs, per server

The load is **per server, not per player**, which is the single most
important structural property here:

| Operation | Frequency | Notes |
|---|---|---|
| `GetSortedAsync` | 1 per 60–120s, jittered | One page only; `topCount` (100) is the page size, so one page is the whole board |
| `UpdateAsync` | Only on a genuine `bestStreak` improvement | Gated twice: `shouldWrite` before spending a request, and a max comparison inside the transform |
| `GetUserInfosByUserIdsAsync` | ≤ 1 per refresh, batched | Only for ids not in cache or past their 1h TTL |
| Client reads | **Zero** | There is no request remote. Clients receive a broadcast from an in-memory cache |

A 6-player server running back-to-back rounds where nobody sets a
personal best issues **no writes at all**. That is the write
amplification P4-3 names, closed at the source.

## 2. At 1,000 concurrent players

~167 servers (6 seats each).

- **Reads:** 167 servers ÷ ~90s ≈ **1.9 `GetSortedAsync`/sec** universe-wide.
- **Writes:** a server completes a round roughly every 6 minutes → ~0.46
  rounds/sec across the universe → ~2.8 player-results/sec. If a
  generous 1 in 3 is a personal best, **~1 write/sec** universe-wide.
- **Per server:** ~0.7 requests/minute. Against A1's assumed
  `base + perPlayer × 6`, that is a rounding error — under 2% of budget.

**Verdict: comfortable.** Nothing here is close to a limit. Budget
pressure should sit near zero and the metric exists mainly to prove it.

## 3. At 20,000 concurrent players

~3,333 servers.

- **Reads:** 3,333 ÷ ~90s ≈ **37 `GetSortedAsync`/sec**, every one of
  them against **the same OrderedDataStore, for the same first page**.
- **Writes:** ~9.3 rounds/sec → ~56 results/sec → **~6–17 writes/sec**,
  spread across distinct per-user keys.
- **Per server: unchanged.** Still ~0.7 requests/minute. This is the
  point: the per-server budget never becomes the problem, because the
  design's cost per server is flat in total population.

### Where the first limit is hit

**Not the per-server budget — the universe-wide read ceiling on one
OrderedDataStore (assumption A4).**

37 reads/sec of an identical first page is a hot partition by any
reasonable backend's definition, and it is *pure waste*: all 3,333
servers are fetching a byte-identical answer, independently, because
none of them can see the others' copy. The writes are fine at this scale
— they're spread across per-user keys and there are few of them. It is
the reads that concentrate.

Secondary, and likely to bite around the same time: **A5**, the name
lookups. 37 refreshes/sec each resolving up to 100 ids is up to 3,700
id-resolutions/sec at steady state, though the 1-hour TTL should collapse
almost all of it after warm-up — the board's top 100 barely changes.

### The mitigation, in the order to apply it

1. **Lengthen the interval.** 60–120s → 180–300s is a config edit and
   cuts read pressure by 2–3×. Buys time; doesn't change the shape.
   Bump `staleAfterSeconds` with it or the indicator starts crying wolf.

2. **Put a shared cache in front of the store** — the real fix, and it
   changes the shape. One `MemoryStoreService` hash or sorted map holds
   the rendered board; servers read *that* (cheap, designed for exactly
   this) and only a small number of servers ever touch the
   OrderedDataStore. Collapses ~37 ODS reads/sec into a handful.
   Election can be crude: a server takes a MemoryStore lock with a TTL
   just over the refresh interval, and whoever holds it does the
   refresh. Everyone else reads the cached copy.

   **P4-4 already brings MemoryStoreService in** for daily and weekly
   boards, so this is the natural moment to do it rather than a new
   dependency.

3. **Serve the board from the cache with a longer staleness budget.**
   A 5-minute-old all-time board is not wrong in any way a player can
   perceive — the top 100 of an all-time streak ladder changes on the
   order of hours.

4. **Shard the read if it ever still matters.** Split the board across
   N OrderedDataStore keys by `userId % N` and merge — only worth it if
   1–3 somehow aren't enough, and it makes ranking meaningfully harder.

### What does *not* need mitigating

Writes. At 20,000 CCU they're ~6–17/sec across distinct keys, which is
unremarkable, and `shouldWrite` plus the max-comparison transform
already guarantee they only happen on real improvements. If write volume
ever does become a problem, the cause will be a bug in `shouldWrite`'s
call site, not the scale.

## 4. What to watch in production

`LeaderboardService.getBudgetPressure()` returns the fraction of the
configured per-window budget spent, and is exposed for P4-7's telemetry
to log. It is deliberately **not clamped at 1** — a value above 1 means
the budget was genuinely exceeded, and that is the number that says an
outage is coming rather than one that has arrived.

Watch for:

- **Pressure trending up with population.** It shouldn't: cost per
  server is flat. If it does, something is reading or writing per
  player rather than per server.
- **`out of write budget` warnings.** A dropped write is a player's
  record silently not counting — the one failure mode this whole service
  exists to avoid.
- **Repeated `display name lookup failed`.** A5 is wrong, or
  UserService is degraded; the board stays correct but fills with
  `Player <id>` placeholders.
- **`Stale` status persisting past a few cycles.** The store is
  unavailable and players are looking at old numbers. They are labelled
  as old, which is the requirement — but it should not be normal.

---

# Part 2: daily and weekly boards (P4-4)

`LeaderboardService` also runs a **daily** and a **weekly** highest-streak
board on `MemoryStoreService` SortedMaps. The calendar arithmetic is in
`src/server/PeriodKeys.luau` and pinned by real dates in
`tests/PeriodKeys.spec.luau`.

## 5. The timezone policy

**A day is a UTC day. A week is an ISO-8601 week — also UTC, starting
Monday.** P4-4 asks for this to be stated rather than assumed, so:

A local-time day is the intuitive choice and the wrong one here.

1. **There is no single local time.** The board is shared and global, so
   "today" would have to mean *one* timezone regardless; picking the
   developer's own is arbitrary and invisible to every player who
   doesn't live in it.
2. **The server doesn't reliably know a player's timezone**, and asking
   the client makes the period boundary a client-supplied value — i.e.
   something a compromised client shifts to get two shots at a daily
   reward (Ground Rule 1).
3. **A MemoryStore TTL counts from the write, not to a wall-clock
   instant.** A period whose end is a different real moment per player
   has no single TTL that is correct for it.

**The cost, named rather than hidden:** a player in UTC+13 sees the
daily board reset at 1pm their time, mid-session. That is a
*presentation* problem — the fix is a UI that says when the reset
happens, not a data model that pretends the boundary is local.

## 6. What makes ISO weeks worth a pure module

ISO week 1 is the week containing the first Thursday of January, so **the
ISO year is not always the calendar year**:

| Date | Weekday | ISO key | Why |
|---|---|---|---|
| 2025-12-29 | Monday | `2026-W01` | Its week contains 2026-01-01, a Thursday |
| 2026-01-01 | Thursday | `2026-W01` | The first Thursday — defines week 1 |
| 2027-01-01 | Friday | `2026-W53` | Its week's Thursday is 2026-12-31 |

Keying on the calendar year would split one week across two boards, on
New Year's Eve — precisely when nobody wants to be debugging it. The spec
asserts these named dates, and the weekday of each was verified
independently of the module that produces them.

(2026 starts on a Thursday, which is exactly the condition for a 53-week
ISO year — so `2026-W53` is real, not an off-by-one.)

## 7. Expiry, and why TTLs are measured from *now*

`liveExpirySeconds` returns *time remaining in the period* + a grace
margin, computed at write time — **not** a fixed "one day".

A MemoryStore TTL starts when the entry is written. Give a fixed 24h to
an entry written at 23:58 and it survives almost a full day into the
next period, where it is both wrong and invisible (the new period reads
a different map). Measuring from now means every entry in a period
expires at roughly the same wall-clock moment regardless of when it was
written.

After the period ends, an entry lives **one full extra period** plus a
1h grace margin. Until 2026-10-04 it was the 1h margin alone, which was
only enough for a server that was running at the boundary to read the
finished standings. The extra period is what the boot-time catch-up
(§8) reads: a server that boots any time in the next period can still
snapshot and pay the one before. The cost is that MemoryStore holds up
to two periods of entries at once (one entry per player who scored),
which is small next to the quota.

## 8. Rollover, and the double-award guard

Detection compares **keys, not timestamps**, so it is correct across a
day boundary, a week boundary, a server asleep for three days, and a
clock that jumped — the question is always "is the period I'm in now
different from the one I last saw?"

A server's **first** check is deliberately *not* a rollover. A server
booting at 3am hasn't witnessed midnight, and treating `nil` as a
rollover would have every new server re-processing a period that ended
hours ago.

**The catch-up (added 2026-10-04, next-stages step 13).** The rollover
only fires on a server that was running at the boundary. At low player
counts there may be none, and then nobody paid the period, silently. So
once per boot, after its first random delay, each server looks at the
period **before** the one it booted into. It `GetAsync`s that period's
snapshot. If there is none, it runs the ordinary rollover for that
period. If the read fails, it skips and leaves it to the next boot. Two
servers booting together both see "no snapshot". The guard below then
picks one of them, as at midnight. This costs one snapshot read per kind
per server boot, plus one rollover per period that nobody witnessed.
Only one period back is covered. With no server at all for a whole
period, the older standings have expired and are not paid.

**The guard against two servers awarding the same period** is the
snapshot write itself, not a separate lock:

1. Every server notices the rollover at roughly the same moment.
2. Each calls `UpdateAsync` on the snapshot key with a transform that
   **refuses to overwrite an existing snapshot**.
3. `UpdateAsync` returns what the transform returned. A server compares
   it against what it tried to write — if they match, it created the
   snapshot; if not, someone else did.
4. **Only the creator fires the reward hook.** LeaderboardPayoutService
   receives it and queues each paid rank on the winner's profile with
   `ProfileStore:MessageAsync` (two `UpdateAsync` calls on the player
   store per payout, so at most 20 per daily or weekly rollover).

There is no window, because the read and the write are one operation. A
separate MemoryStore lock would also work, but it would be a second
thing that can expire or fail independently of the snapshot it guards —
using the snapshot means the guard cannot drift out of step with what it
protects.

## 9. Additional limits to verify (extends §0)

| # | Assumption | Status |
|---|---|---|
| A6 | MemoryStore has a per-server request budget *and* a universe-wide quota scaling with player count | **Corrected 2026-10-04.** No per-server budget. The quota is experience-wide, 1000 + 120 × CCU request units per minute. There is also a per-partition limit, and **every sorted map sits on a single partition** (Roblox estimates ~30,000 units/min per partition; a safeguard, not a published quota) |
| A7 | SortedMap `GetRangeAsync` is charged as a single request regardless of `count` | **Wrong.** It costs one request unit per item returned (1 if empty). A full 100-row read is 100 units |
| A8 | MemoryStore item size and per-map item-count ceilings are comfortably above 100 entries | **Confirmed.** 32 KB per value, 128-character keys and sort keys, 1,000,000 items and 100 MB per map. No maximum `count` for `GetRangeAsync` is documented |
| A9 | `UpdateAsync` on a SortedMap is atomic under contention across servers | **Confirmed.** On contention it retries the transform until it succeeds, the transform returns nil, or a retry cap is hit (then a conflict error) |

**A7 was wrong, and it changes the design.** Every server, Hub and
Match alike, reads both period boards every 60–120s
(`startPolling` is unconditional). That is 2 × 100 units per ~90s,
about 67 units/min per board per server. Each board is one sorted map,
so one partition:

- **Per-partition: the first limit.** ~30,000 / 67 ≈ 450 servers per
  board, roughly **2,500–3,000 CCU** at 6 seats per server. Past that,
  period-board reads get throttled.
- **Experience quota: fine on its own.** Both boards together cost about
  22 × CCU units/min against 1000 + 120 × CCU, ~18%. But they share it
  with matchmaking (`matchmaking.md`), whose queue map has the same
  single-partition problem.

The fix is the one §3 already recommends for the all-time board, now
needed before any launch past a few thousand CCU. One elected server per
board reads the sorted map and publishes the rendered top 100 as one
value, sharded across a few hash-map keys (the best-practices guide's
remedy for a hot key). Everyone else reads one shard: 1 unit, not 100.

**Built 2026-10-04** (`refreshPeriodBoardShared` in `LeaderboardService`,
pure parts in `LeaderboardLogic`, tuning in
`GameConfig.leaderboard.periodShare`). Each poll reads one random shard
of the hash map `PeriodBoardsPublished_v1`: 1 unit. A copy older than
`republishAfterSeconds` (60s), or a missing one, sends the reader for
the publish lock, a hash-map `UpdateAsync` that only the first server
since the lock expired wins (`lockSeconds`, 30s). The winner reads the
sorted map (100 units), resolves the names and writes the board into
all 4 shards. Readers get names from the copy, so they make no name
lookups for period boards (helps A5). Rollover and catch-up still read
the sorted map directly, because they need the final standings.

New cost per board: about 100 units/min on the sorted map's partition
in total, however many servers there are, plus 1 unit per server per
poll spread over 4 hash keys. At 20,000 CCU that is ~555 reads/min per
shard key, far under the ~30,000/min partition guide. What players see:
a period board can be up to ~3 minutes old (republish age plus one poll
interval), under `staleAfterSeconds`. A server that boots when no copy
exists and loses the lock shows "Loading" until its next poll. That
only happens at a period's start or after every server has been gone
for 15 minutes.

Still open: the matchmaking queue's sorted map (`matchmaking.md`), the
all-time board's OrderedDataStore reads (§3, not needed until well past
launch scale), and A5's name lookups for the all-time board.
