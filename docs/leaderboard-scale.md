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
| A1 | Per-server request budgets are a formula of the form `base + perPlayer × playerCount`, replenished per minute, **and separate per request type** | The whole soft-ceiling policy assumes reads and writes draw on budgets that behave independently | **VERIFY** |
| A2 | `GetSortedAsync` has its own, much smaller budget than ordinary reads | The poll interval was chosen to sit far under it | **VERIFY** |
| A3 | There is a per-key write cooldown (order of seconds) | We never write the same key twice quickly, so this should be unreachable — but confirm the figure | **VERIFY** |
| A4 | There are universe-wide throughput ceilings (bytes/min, requests/min) distinct from per-server budgets | **This is the one the analysis below concludes you hit first** | **VERIFY — highest priority** |
| A5 | `UserService:GetUserInfosByUserIdsAsync` has its own rate limit, separate from DataStore | The name cache is sized against a guess | **VERIFY** |

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
