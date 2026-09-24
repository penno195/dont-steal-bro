# Live-ops roadmap: the first 90 days and season structure (P9-3)

Builds on `launch-review.md` (P9-2, the weekly review that feeds every
balance beat here), `live-ops.md` (P8-5, the switches and tunables events
are made of) and `leaderboard-scale.md` (P4-3/P4-4, the period boards a
season extends).

This is a plan, and P9-2's data outranks it. Two buffer weeks are held
empty for that reason, and any beat can move into a buffer week if a
review says so.

---

## 0. Starting position and assumptions

| | At launch | Waiting |
|---|---|---|
| Maps | Wave 1: School, Factory, Museum, Laboratory | Wave 2: Bunker, Prison, Mall, Construction Site. Wave 3: Space Station, Aircraft Carrier, Deserted Island. All 7 built in Studio. `waveNumber` is set in each `Config/Maps` file |
| Tasks | 8 | 7 more in `tasks-catalogue.md` |
| Power-ups | 10 | none planned in this window |
| Titles | 10-rung `bestStreak` ladder (1 → 120) | seasonal ladders, §3 |

**Assumption: the launch 8 tasks.** Four are built: `pressure-valve`,
`vent-purge`, `fuse-rewire` and `code-playback`. This plan assumes the
other four are `alarm-killswitch`, `breaker-sequence`, `reactor-sync` and
`airlock-cycle`. All four score 5/5 on mobile, and they bring the Hold
and Timing verbs that the built four lack. That leaves these seven to
ship after launch:

| Order | Task | Verb | Mobile | Why this slot |
|---|---|---|---|---|
| 1 | `crate-winch` | Hold | 4/5 | Easy to read, and a second Hold task gives the verb some variety |
| 2 | `conveyor-sort` | Timing | 4/5 | |
| 3 | `cable-splice` | Drag | 4/5 | |
| 4 | `lock-tumbler` | Drag | 3/5 | |
| 5–7 | `morse-relay`, `turret-calibration`, `sensor-sweep` | Sequence, Aim, Aim | 3/5 | These score lowest on mobile. They ship after day 90, and only if the P7 mobile audit passes them on a cheap Android phone. Ground rule 3 cuts any that fail |

If the launch set turns out different, keep the ordering rule: highest
mobile score first, and fill missing verbs before adding a second task
with a verb that already exists.

**Week numbering.** W1 is launch week. Weeks follow the ISO week, so
they start Monday 00:00 UTC, as the weekly board does
(`leaderboard-scale.md` §5). 90 days runs W1–W13.

**Prerequisite:** the P9-2 §0 instrumentation gap has to be closed
before W1. Every "confirming metric" below needs it.

---

## 1. Rules of the calendar

1. **A week is either a content week or a balance week, never both.**
   A content week publishes new maps, tasks or store items. A balance
   week changes live-config tunables only, with no publish, as set out in
   `live-ops.md`. The `launch-review.md` §8 wait floor (a sample count,
   and at least 7 days) is what keeps them apart.
2. **Something new every 2–3 weeks, and never a dead month.** The longest
   gap in §2 between new things players can see is 3 weeks.
3. **Two buffer weeks: W5 and W11.** Nothing is scheduled in them. They
   are there for whatever the reviews turn up, whether that's an extra
   balance pass, a bug fix, or pulling a later beat forward.
4. **Every beat states a return reason.** It's written for a player who
   has been away for 2+ weeks, and says what is different for *them*,
   not just what changed.
5. **The weekly shape:**
   - **Mon:** the weekly board rolls at 00:00 UTC, and the P9-2 review runs.
   - **Tue:** content publishes or balance changes go live. Monday's
     review gets a day to land first, and it's never a Friday.
   - **Fri 18:00 UTC → Mon 00:00 UTC:** the weekend event, which ends
     when the weekly board ends.
6. **Events never touch the payoff table.** `bountyTiers.*` belongs to
   P9-2's finale-health loop (`launch-review.md` §3). A "double bounty
   weekend" would wreck the one measurement the game can least afford to
   lose.
7. **Store rotations are cosmetic only.** A limited-time power-up offer
   turns the asymmetry `store-receipts.md` warns about ("a player can pay,
   at will, for a material advantage in the round where it is worth the
   most") into urgency marketing. Design decision 8 already keeps Robux to
   buying time. Rotations shouldn't add pressure on top of that.
8. **Content switches only turn things off** (`live-ops.md`). So a new
   map or task always means a publish, but a spotlight event that narrows
   the map pool doesn't need one.

---

## 2. The calendar (W1–W13)

Legend: **C** = content week, **B** = balance week, **S** = season beat,
**—** = buffer.

| Wk | Type | What ships | Weekend event | Store |
|---|---|---|---|---|
| W1 | Launch | Nothing new. Baseline week. The §4 builds start | *none*, so the first weekend's numbers are clean | Launch set |
| W2 | B | Balance 1, from Review 1 | Board Rush | — |
| W3 | C + S | **Season 1 opens.** Wave 2a: **Bunker, Prison** | Lockdown Weekend | Rotation 1 (Bunker/Prison theme) |
| W4 | B | Balance 2 (wave 2a maps) | Blitz Weekend | — |
| W5 | — | **Buffer A** | Board Rush | — |
| W6 | C | Tasks: **Crate Winch, Conveyor Sort** | Chaos Weekend | Rotation 2 |
| W7 | B | Balance 3 (the new tasks) | Board Rush | — |
| W8 | C | Wave 2b: **Mall, Construction Site** | Season 1 Finale (wave 2 spotlight) | Rotation 3 |
| W9 | B + S | **Season 1 rewards granted** after the §3.6 hold. **Season 2 opens.** Balance 4 (wave 2b) | Blitz Weekend | — |
| W10 | C | Wave 3 flagship: **Space Station** | Orbit Weekend | Rotation 4 (Space Station theme) |
| W11 | — | **Buffer B** | Board Rush | — |
| W12 | C | **Aircraft Carrier**. Tasks: **Cable Splice, Lock Tumbler** | Carrier Weekend | Rotation 5 |
| W13 | B | Balance 5 | Board Rush | — |
| *W14* | *C + S* | *Deserted Island and the Season 2 finale, just past day 90* | | |

W9 puts a balance change and a season opening in the same week. That's
allowed, because a season opening changes no gameplay value. The fresh
board changes how many people play, but it doesn't change per-map or
per-task balance. The W9 review should still read engagement metrics
with the season start in mind.

### 2.1 The beats

Each beat lists what ships, the work it needs, the return reason, the
metric it targets and the announcement hook. "Lapsed return" means
players with no session in the previous 14 days who start one within 72
hours of the beat.

**W1 — Launch.** *Ships:* wave 1. *Work:* the P9-1 store page, and
kicking off the §4 builds. *Return reason:* not applicable. *Metric:*
the P9-2 funnel and D1 baselines. *Hook:* the P9-1 trailer.

**W2 — Balance 1.** *Ships:* whatever Review 1 ranks highest that can be
done with live config. *Work:* one admin command per change, recorded in
the review log. *Return reason:* none on its own. Balance weeks aren't
meant to bring anyone back. *Metric:* whatever Review 1 named. *Hook:*
patch notes in the hub news board and the group.

**W3 — Season 1 + Bunker and Prison.** *Ships:* the two map publishes,
the season key going live, the Season 1 title ladder and store
Rotation 1. *Work:* each map's `enabled = true` plus its lighting preset
file (`lighting-and-streaming.md` notes wave 2/3 only have placeholder
presets), the station reskins from the catalogue, a
real-device pass on both maps against the P7 budgets, and the §4 builds
B1–B3 finished. *Return reason:* "The board is empty, a new ladder
counts only what you do from today, and there are two maps you've never
seen." This is the biggest beat before W10. *Metric:* lapsed return,
the share of rounds played on new maps (the first test of whether the
vote pulls toward new content), and the per-map win rate spread
(`launch-review.md` §4.1). *Hook:* **"Season 1: everyone starts at the
bottom of the new board."**

**W4 — Balance 2.** *Ships:* `map.*.npcDifficultyModifier` and task-time
fixes for Bunker and Prison. *Metric:* those maps' win-rate spread
getting close to wave 1's.

**W5 — Buffer A.** Empty on purpose.

**W6 — Crate Winch + Conveyor Sort.** *Ships:* 2 tasks, each needing a
config file, a handler and a view (`how-to-add-a-task.md`). Every enabled
map's `enabledTaskIds` gets both ids, and each map's stations get the
ids added to `AcceptedTaskIds` in Studio, with the per-theme reskin. That
Studio pass across 6 maps is the real cost, not the code. *Return
reason:* "The stations do new things. The race you had memorised isn't
the race anymore." *Metric:* per-task completion time and abandon rate
against the catalogue target times. *Hook:* **"Two new ways to lose a
race."**

**W7 — Balance 3.** Task timing and difficulty fixes. The W6 Chaos
Weekend rounds are excluded from the read (§2.2).

**W8 — Mall + Construction Site.** *Ships:* the rest of wave 2, plus
Rotation 3. *Work:* same as W3, and both maps must include W6's tasks on
their stations. *Return reason:* "It's the last week of Season 1. Your
spot on the board and your season titles lock on Sunday." *Metric:*
lapsed return, and how many players end up in the top 100 of the season
board. *Hook:* **"Season 1 ends Sunday. Two new maps to make your last
run on."**

**W9 — Season 2 opens + Balance 4.** *Ships:* the Season 2 key and
ladder, and the Season 1 rewards once the integrity hold clears.
*Return reason:* "Season 1 is over and your name is either on the hall
or it isn't. The board is empty again." *Metric:* how many Season 1
top-100 players play in the first week of Season 2 (§3.7). *Hook:*
**"Season 1's champions are on the wall. Season 2's spots are open."**

**W10 — Space Station.** *Ships:* the wave 3 flagship on its own, so it
gets a beat to itself. *Work:* as W3, plus the heaviest perf check of any
map. The hard-surface interior is the most likely to blow the lighting
budget. *Return reason:* "A map that doesn't look like any of the
others." *Metric:* lapsed return (expected to be the highest of the
window), and Space Station's share of vote wins. *Hook:* **"Now you can
get robbed in space."**

**W11 — Buffer B.** Empty on purpose. If W10's perf read is bad, this
week goes to fixing Space Station.

**W12 — Aircraft Carrier + Cable Splice + Lock Tumbler.** *Ships:* one
map and two tasks. Maps and tasks can share a content week, because the
rule separates content from balance, not content from content. *Work:*
the W6 station pass again, now across 10 maps. *Return reason:* "A new
map and two new stations mid-season." *Metric:* same as W6 and W10, read
per item. *Hook:* **"Two new tasks, one flight deck."**

**W13 — Balance 5.** Fixes for the W12 content. Day 90 lands here.

### 2.2 Weekend events

Every event runs Fri 18:00 UTC → Mon 00:00 UTC and ends with the weekly
board. Every event round is tagged (build B4), and P9-2 leaves tagged
rounds out of every balance read.

| Event | Made of | Why it's there | Confounds balance? |
|---|---|---|---|
| **Board Rush** | Presentation only. A hub countdown to the weekly rollover, and the week's top 10 revealed on the hub wall on Monday | The weekly board already exists, and this makes its ending an occasion. It's the default weekend | No |
| **Spotlight** (Lockdown, Season Finale, Orbit, Carrier) | Live-config map disables that narrow the pool to the newest maps. It turns things off, so no publish is needed (§1 rule 8) | The newest maps get played enough for their samples to fill quickly | Per-map reads, no. Maps are read separately. Vote-share reads, yes: exclude the weekend |
| **Blitz** | `game.tasksPerPlayer` −1, `game.raceDurationSeconds` shortened to match | More rounds per hour on the weekly board's final weekend. Every round is still a whole-streak risk | Yes. Tagged and excluded |
| **Chaos** | `powerUp.*.cooldownSeconds` down about 25% | More griefing moments to clip and share | Yes. It also stresses the anti-frustration rules, so watch time spent disabled |

Chaos and Blitz never run the weekend after a balance change to the same
tunable. Board Rush is the fallback whenever there's any doubt.

### 2.3 Store rotations

Rotations switch every 2 weeks, and a new one goes live in the same
publish as each content week. Each rotation holds 2–3 cosmetics themed
to the newest map. Cosmetics only (§1 rule 7). Returning items is fine:
bringing an item back after 6+ weeks counts as a return reason too. Needs
build B3, plus real asset ids. Every current store and cosmetic entry is
still a disabled placeholder.

---

## 3. Season structure

### 3.1 Length: 6 weeks, aligned to ISO weeks

Three reasons.

- **It fits one MemoryStore TTL.** P4-4's period boards set each entry's
  TTL to "time remaining in the period + 1h" at write time
  (`leaderboard-scale.md` §7). An entry written in week 1 and never
  improved has to survive to the end of the season. Six weeks is 42 days
  plus grace, which fits under MemoryStore's maximum item expiration.
  That maximum is 45 days as of writing, and it has to be checked
  against the current MemoryStore limits before B1 is built. An 8-week
  season would need a periodic re-write of every entry, or a DataStore
  instead, and either one adds moving parts.
- **It covers two content beats.** Each season gets a mid-season beat
  and a finale beat.
- **It's short enough that a player who falls behind waits at most about
  a month for a clean board.**

W1–W2 are **preseason**. The weekly and all-time boards run as normal,
but no season rewards are given. The first season's champions shouldn't
be crowned before P9-2 §6 has run two integrity reviews on real data.

### 3.2 Season score

**Season score = the highest live streak reached during the season.**
It's written by the same write-on-improvement path as the weekly board,
under the season's key. A streak brought in from the previous season
counts, but only once it's in play. A player who enters Season 2 on a
streak of 30 posts nothing until they win again, which posts 31.

The alternative would be a separate "season-only streak" that counts
from zero at the season boundary. It's rejected because it would give
players a second, phantom streak alongside the real one, which the real
one never agrees with, all for a game whose whole identity is one
number. **This is the one open choice in the plan. Confirm it before B1
is built** (§5).

### 3.3 What resets at a season boundary

- The season board.
- Progress toward the new season's title ladder. The new ladder's titles
  all start unearned.

### 3.4 What carries over

- **The live streak.** Only a loss resets a streak. That's the game's core
  rule (GDD §3, design decision 7), and a calendar reset would break it,
  punishing a player who hasn't lost.
- `bestStreak`, the all-time board and the permanent title ladder.
  Titles are never revoked (GDD §3).
- **Seasonal titles already earned**, which stay permanently and are
  labelled with their season.
- Currency, cosmetics, power-up stock, loadout, and the steal/share
  reputation (design decision 5). Reputation is a record of behaviour,
  and resetting it would let a serial stealer wipe their record just by
  waiting.

### 3.5 Seasonal title ladder

Each season has four rungs keyed on season score, plus one keyed on
final placement:

| Rung | Earned by |
|---|---|
| S*n* Contender | Season score ≥ 5 |
| S*n* Threat | ≥ 15 |
| S*n* Headliner | ≥ 40 |
| S*n* Top 100 | Finishing in the top 100 of the season board |
| S*n* Champion | Finishing in the top 10 |

The thresholds are placeholders. They should be set from the W1–W2
distribution of `bestStreak`, so that roughly half of active players
reach the first rung. Names are written in the voice of the permanent
ladder (`Config/Titles/init.luau`), and every season gets fresh names.
The "S*n*" label is presentation, so the titles themselves can be
themed.

Display follows the P4-2 ruling (design-decisions.md, "Applied case:
titles and nametags"). Seasonal titles are shown in the lobby and after
the result, and suppressed for every state in between.
`TitleService.broadcastTitles` already enforces that for any title, so a
seasonal title gets no new exposure.

### 3.6 What top streak holders get

**The limit that shapes all of this:** design decision 7 is only safe
while a player's streak can't be seen in a live round. A reward that
marks the top 10 in the race or the Studio is exactly the "indirect
tell from reward tiers" P0-7 was told to threat-model. So nothing a
season awards can be visible during the race or the Decision Studio.
That rules out:

- `podium-champion-flare`, or any Podium cosmetic. They only render in
  the Studio, the phase where a tell is worth the most.
- Exclusive skins, trails or emotes. These show in the race.
- Power-up stock or any other gameplay item. It gives a lasting edge to
  the players already ahead, which undercuts design decision 8.

What they get instead, from most to least valued:

1. **The Hall.** A permanent hub wall with each season's top 10 by name
   and avatar, with the top 3 as statues. The hub is allowed to show
   streak-derived status. The daily, weekly and all-time boards already
   do. Once a season ends it never leaves the wall, and every new season
   adds a panel. *This is the reason to chase Season 2:* a Season 1
   champion's name stays on the wall, but their panel shows they haven't
   repeated.
2. **The S*n* Champion / Top 100 titles.** They're unique per season, and
   the lobby shows who has collected more than one.
3. **A Roblox badge** for each season's top 100. It's visible on the
   profile, outside the game.
4. **A season-history card** on the hub profile panel. It shows every
   season's placement, so consistency counts, not just one lucky run.

**The integrity hold.** Rewards aren't granted automatically at
rollover. The P4-4 rollover hook takes the snapshot as usual, and then
the grant waits 72 hours. During the hold, the Monday review runs P9-2
§6 over the top 100, looking at NPC-lobby share, repeat co-finalists and
all-share clusters. It flags accounts to withhold, and an admin confirms
the grant. A flagged player keeps their live streak and their permanent
titles, but loses that season's placement rewards. A leaderboard that
crowns a farmer once has lost the thing that makes this game's
leaderboard worth chasing.

### 3.7 How a season is judged

- **Season carry-over:** of the season's top-100 players, the share who
  play in the first week of the next season. This is the main season
  metric. It shows whether the Hall and titles made the next season worth
  chasing.
- **Season-board depth:** how many players post a season score at all.
  If fewer than about 20% of season players reach Contender, the
  thresholds are set too high.
- **Final-week lift:** the finale week's rounds per active player,
  compared with the season's mid-weeks. It shows whether the season's
  end actually pulls players in.

---

## 4. One-time builds

A season, a timed store item and an event that ends itself each need
support in the services, built once. After that, running a season,
rotation or event is config only, which is what ground rule 2 asks for.
Each build is a small, separable task:

| # | Build | Scope | Needed by |
|---|---|---|---|
| B1 | **Season key and board** | A pure `seasonKey(now, seasons)` in `PeriodKeys.luau`, with season start dates as a `GameConfig.seasons` list checked by Validate (ISO-Monday starts, 6-week length, no overlaps). `LeaderboardService` gets a third period board that reuses the P4-4 snapshot, rollover and double-award guard. The reward hook queues the grant rather than granting (§3.6). Headless specs pin the boundaries the way P4-4 pins ISO weeks | W3 |
| B2 | **Seasonal titles** | An optional `TitleDef.seasonId` plus `minSeasonScore` / `placementMax`, with `TitleService` unlocking them from the season score. After that, one config file per title, as usual | W3 |
| B3 | **Timed store items** | Optional `availableFromUtc` / `availableUntilUtc` on `StoreItemDef` (Validate: from < until). `StoreService` won't prompt outside the window. `ProcessReceipt` still honours a receipt from inside the window that is redelivered after it closes | W3 |
| B4 | **Self-ending event overrides** | An `expiresAtUtc` on a live-config override layer, so a weekend event can't outlive Sunday if nobody is awake to revert it. Plus an `eventId` field on `RoundStarted`, so P9-2 can exclude event rounds | W2 (Board Rush needs neither, so manual revert covers W2 if this slips) |
| B5 | **Hub Hall and news board** | Hub geometry for the Hall (a hand-built Studio asset, like maps), and a news board that reads a config list of announcements | Hall: W9. News board: W2 |

B1–B3 hold up W3, so they're the first work after launch. If they slip,
**push Season 1 back, but not the wave 2a maps.** The maps are a return
reason even without a season.

---

## 5. Decisions this plan needs from the owner

1. **Season score (§3.2): peak live streak, with a carried-in streak
   counting once it's in play.** This is what the plan recommends. The
   alternative is a season-only counter. Everything else in §3 follows
   from design decisions already recorded.
2. **The launch task set (§0):** is it the assumed four?
3. **Integrity hold (§3.6):** is a 72-hour manual confirmation acceptable
   as a standing weekly and seasonal job?
