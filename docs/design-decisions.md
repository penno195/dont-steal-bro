# Don't Steal Bro! — Design Decisions v2 (resolves GDD §7)

Produced by task **P0-1**, revised after review. Once accepted, this closes
all eight open questions in `docs/gdd.md` §7 and unblocks P0-2 through P0-7
and P1-1. These are the owner's decisions; the reasoning captures the
trade-offs discussed and, where a decision depends on another system
delivering something specific, says so explicitly.

## Summary

| # | Question | Decision |
|---|---|---|
| 1 | What is bounty? | A fixed (non-random) item package, tiered by the winner's own streak level. No currency, no chance-based drops. |
| 2 | Round timer, <3 finished | Below 50% task completion = never qualifies. Unfilled seats backfill with NPCs — no void case. |
| 3 | Disconnect before Studio | Promote the 4th-place finisher (or NPC). All finalists teleport in together; only the 3 qualifiers can enter the podium's proximity circle. |
| 4 | Disconnect inside Studio | Leaver always takes the loss personally; their substituted vote for the other two is **Share**. |
| 5 | Can NPCs qualify? | Yes, personality-weighted policy. Plus: visible steal/share history per player in the Studio UI. |
| 6 | "Progress to next round" | Normal requeue — no priority ticket. |
| 7 | Streak reset scope | Everyone but the winner(s) resets, including failing to qualify — made safe by streak-hiding in-round, random matchmaking, and mandatory counter-play for every attack. |
| 8 | Robux power-ups | Allowed only for items that are also freely earnable — Robux buys time, never exclusive power. 3-item loadout cap regardless of spend. |

---

## 1. What is "bounty"?

**Decision:** Bounty is a **fixed, deterministic item package**, not a
currency and not a random-chance drop. The package a winning player receives
is looked up from their own streak tier crossed with their outcome tier
(sole-stealer / minority-sharer / all-share) — every player at a given
(streak tier, outcome tier) pair gets the same set. Players at different
streak tiers in the same Studio each resolve their own package independently
against their own tier; there's no shared pot.

**Reasoning:** Deterministic rewards sidestep Roblox's random-virtual-item
disclosure requirements entirely, which apply to randomized reward grants
regardless of whether Robux was spent — this was a real risk in the v1
"percentage chance" framing. Tying the package to the *winner's own* streak
tier keeps the escalation players want: the higher your streak, the more
you stand to gain from a win, mirroring the escalating downside the
streak-reset already creates. The outcome-resolution pure function still
only needs to hand back an outcome tier; the reward lookup is a separate,
swappable table.

**Downstream:** `ProfileStore` schema (streak tier, item inventory — no
currency balance field), `Outcomes.luau` return shape (item-package
reference instead of a bounty number), a new `RewardTables` config module
(streak tier × outcome tier → item set), Decision Studio reveal UI (renders
per-player item reveals, not a shared number).

**Reversal cost:** Moderate. Swapping to currency later replaces the
`RewardTables` lookup with a formula and touches DataStore fields, but the
outcome-resolution function itself is untouched — it only ever says which
tier someone won.

## 2. Round timer expires with <3 finished

**Decision:** Rank finishers by task-completion percentage (tiebreak:
elapsed time). Anyone below **50%** completion never qualifies, regardless
of relative rank — this includes the fully-AFK (0%) case as a strict
subset. Any Studio seat that can't be filled by a qualifying human is
backfilled by an NPC under the same personality-weighted policy used
elsewhere (Q5). There is no void case: NPC backfill always resolves the
Studio, up to and including an all-NPC Studio if no human clears the floor.

**Reasoning:** A hard floor stops a player limping into a Studio seat at
20% progress and resetting someone's streak on the timer's arbitrary
cutoff. NPC backfill is strictly simpler than the v1 "void the round"
fallback, since the game already has to support NPC Studio participants for
the small-human-lobby case — reusing that machinery removes a whole branch
instead of adding one.

**Downstream:** `TaskService` (completion-percentage metric), `RoundService`
(drop the void transition entirely; always resolve via NPC backfill),
`NPCService` (backfill trigger).

**Reversal cost:** Cheap — a threshold constant, and removing a
state-machine branch rather than adding one.

## 3. Qualifier disconnects between the race and the Studio

**Decision:** Promote the 4th-place finisher (NPC backfill per Q2 if none
exists). Mechanically: **all** finishers up to 6 teleport into the Studio
room together in one step. The 3 current qualifiers stand on fixed podium
positions inside a proximity circle for the duration; a server-authoritative
boundary check keeps non-qualifiers on the room's perimeter, visible but
unable to enter the circle. If a podium player disconnects, the alternate's
boundary access opens and they move into the vacated slot; the leaver's
access is revoked.

**Reasoning:** This avoids the original race condition (an already-returned
4th-place finisher needing to be pulled back from the lobby) by construction
instead of patching it with a grace window — nobody's location changes state
after the single initial teleport, so promotion is just an authorization
flag flip plus a boundary check. Bonus: 4th–6th place get a free spectator
view of the game's climax, which fits the GDD's framing of the Studio as the
moment worth watching.

**Downstream:** `RoundService` (single all-finalists teleport), a
CollectionService-tagged podium region (feeds P0-5's map-kit contract —
every map's Studio hand-off point needs this region defined),
`DecisionService` (vote UI gated by boundary-access flag, not literal
presence).

**Reversal cost:** Cheap — additive to the existing teleport step.

## 4. Qualifier disconnects inside the Studio

**Decision:** The leaver always personally takes the loss (streak resets,
no reward) regardless of the computed table outcome. For resolving the
*other two* players, the leaver's substituted choice is **Share**.

**Reasoning:** The collusion exploit flagged against a Share default
(a stranger's forced-Share vote removing the third seat's ability to
retaliate with Steal) requires colluders to reliably land in the same
Studio, which the matchmaking design already rules out — no party
queueing, and private servers don't count toward streak, so pre-arranging a
seat together isn't a repeatable strategy regardless of the default. A
Steal default, meanwhile, has a real everyday cost: it guarantees a loss for
two genuinely cooperating players (Share/Share) purely because a third
party's connection dropped — punishing players for someone else's
disconnect rather than their own choice, which cuts against the "difficulty
comes from your own decisions" principle the streak-reset design leans on
in Q7.

**Downstream:** `DecisionService` (forfeit path, substituted-choice
constant), `Outcomes.resolve` call site (pass "Share" for missing entries),
streak-reset logic.

**Reversal cost:** Cheap — a single config constant.

## 5. Can NPCs qualify for the Studio?

**Decision:** Yes, through the normal `TaskService` completion path, using
the existing personality-weighted policy (Greedy 0.7 / Loyal 0.2 / Chaotic
0.5 steal-probability). **Addition:** every player's historical steal/share
rate is tracked and surfaced in the Decision Studio UI before the vote
(e.g. "stolen 62% of the last N decisions").

**Reasoning:** Visible reputation history adds real information asymmetry
to a blind simultaneous-choice game without changing the underlying
game-theory — it's exposed information, not a rule change — and gives
returning players a reason to actually protect a reputation, reinforcing
the streak's meta-game.

**Downstream:** `DataService` (persist rolling steal/share counts per
player), Decision Studio UI (reputation display pre-vote). Open detail:
whether this is shown only to co-participants at decision time or is a
public profile stat — the latter must not conflict with the in-round
streak-hiding rule in Q7 (steal/share history is not the same signal as
streak, but should be reviewed under the same "does this let someone target
a specific player" lens).

**Open detail resolved (P6-5, 2026-09-23): Studio room only.** Reputation
is sent in `DecisionParticipants`, to the people in the Studio, while it
runs. It is not a public profile stat, and no hub or leaderboard surface
shows it. It is lifetime `steals`/`shares` counts from the profile, and
an NPC sends 0/0, which reads the same as a first-timer. Making it public
later would need its own review under Q7.

**Reversal cost:** Cheap — additive UI and a counter field; doesn't touch
resolution logic.

## 6. What does "progress to the next round" mean mechanically?

**Decision:** A fresh match via **normal requeue** — no priority ticket,
no same-server continuation.

**Reasoning:** Consistent with wanting the streak to be earned repeatedly
rather than smoothed by a matchmaking favor; a priority skip would be a
small but real advantage that undercuts "this should be hard to hold."

**Downstream:** `MatchmakingService` (no special ticket type needed —
simplifies P1-1's scope), Hub UI.

**Reversal cost:** Cheap — priority can be added later as a flag if wanted.

## 7. Does a loss reset the streak for everyone who fails to qualify, or only Studio losers?

**Decision:** Everyone but the winner(s) resets the streak, including
failing to qualify at all (4th–6th place, or falling below Q2's 50% floor).
This is made safe, not softened, by three conditions that must hold in the
shipped game:

1. **Streak is never visible to other players during a live round** — hub
   and post-match leaderboard only, never an in-round HUD, nameplate, or
   any other tell (including indirect ones — see downstream note on Q1
   reward cosmetics).
2. **Matchmaking is fully random** — no party queueing, and private servers
   don't count toward streak, so pre-arranged targeting isn't possible.
3. **Every offensive power-up has a defined, always-available counter**,
   and choosing an offensive vs. defensive loadout pre-game is a genuinely
   viable choice, not a trap option.

**Reasoning:** The objection to this rule was that it turns race-stage
griefing into a zero-risk way to erase a specific rival's streak without
ever reaching the Studio. That threat depends entirely on being able to
identify a target and reliably reach their lobby — both of which the three
conditions above remove. If they hold, a loss to griefing becomes a
symmetric-risk skill/counterplay problem (anyone might be attacked, nobody
can choose who) rather than a targeted-harassment vector, which fits
wanting difficulty to come from the encounter itself rather than bad luck.
This makes **P0-3's counter-play matrix and P0-7's threat model
load-bearing, not optional** — if streak-hiding leaks (e.g. a high
streak-tier reward package from Q1 is visibly distinct in a way that
telegraphs the wearer's tier) or a defensive loadout turns out to be
strictly worse than offense in practice, this decision needs revisiting.

**Downstream:** `RoundService`/`DataService` (reset fires on any
non-progression outcome, not just a Studio loss), UI (streak explicitly
excluded from every in-round surface — write this as a rule, not an
assumption, in P0-5/P0-6), P0-3 (must ship a complete 1:1 counter for every
offensive effect), P0-7 (must explicitly threat-model "identify and target
a specific rival's streak" as a named attack, including indirect tells from
Q1's reward tiers).

**Reversal cost:** Moderate. Softening later to "only Studio losers reset"
is a cheap state-machine change, but if the game is balanced and priced
around the harsher rule, walking it back after players are used to the
enforced difficulty is a live-balance change, not just a code change.

### Applied case: titles and nametags (P4-2)

Condition 1 above was tested by the first feature that wanted to put
something over a player's head. P4-2's title ladder unlocks off
`bestStreak`, so a visible title ("Untouchable", rung 7 of 10) telegraphs
roughly how strong its wearer is — an indirect tell of exactly the kind
condition 1 names, and it named "nameplate" specifically.

**Resolution: titles display in the pre-round lobby and after the result
is in, and are suppressed for every state in between,** including the
Decision Studio — three finalists reading each other's rungs would learn
who most needs the win, in the one phase where that information is worth
most. Enforced server-side: `TitleService.broadcastTitles` does not send
other players' titles while a round is live, so a modified client has
nothing to un-hide, and both display surfaces (nametag and chat prefix)
inherit the one decision. The `TitleUnlocked` remote is targeted at the
earner alone, because it carries a threshold, and a threshold is a streak
number.

`GameConfig.titleDisplayDuringRound` flips it. **Flipping it to true means
amending this decision, not just the flag** — condition 1 is load-bearing
for the harsh reset rule, and Q7 itself says the decision needs revisiting
if streak-hiding leaks rather than that a leak is acceptable.

### Applied case: the Decision Studio intro (P6-5)

P6-5's task prompt asked for the Studio intro to show each finalist's
title and current win streak "so players can use it to bluff." Decided
with the project owner (2026-09-23): **condition 1 holds, and the intro
shows Q5's steal/share reputation instead.** Reputation is a behavioural
record, the information a bluffer actually needs. Streak is a stake size,
which tells everyone who most needs the win. Titles stay suppressed as
above. A finalist's own streak reaches only that finalist, and only after
the reveal (`DecisionPersonalResult`, targeted), so the result screen can
name the streak that just ended. See `docs/decision-studio.md`.

## 8. Are starting power-ups sold for Robux?

**Decision:** Power-ups may be purchased with Robux, provided **every**
purchasable item is also earnable for free through normal play — Robux buys
time, never exclusive power. Loadouts are capped at 3 items regardless of
spend.

**Reasoning:** This is the standard "pay for convenience" model rather than
pay-to-win, and the 3-item cap already limits how much a bought-ahead
inventory can matter in any single round. The residual risk is perception
and the early-game window, not mechanics: a new game's leaderboard
credibility can still take damage if payers visibly out-perform grinders
independent of skill, even though grinders eventually reach full parity.

**Downstream:** `StoreService`, `GameConfig` (a power-up config with no free
acquisition path should fail config validation per Ground Rule 2, not just
fail review), P0-7 (must track paid-vs-free win-rate correlation
post-launch as the abuse/perception tripwire, alongside the exploit-style
attacks it already covers).

**Reversal cost:** Cheap to tighten (remove the Robux purchase option),
expensive to loosen further — introducing an exclusive paid power-up later
reopens the exact threat-model question this decision just closed.
