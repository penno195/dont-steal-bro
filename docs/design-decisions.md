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
| 9 | Where does a KillZone put a fallen racer? *(added 2026-10-03, not from GDD §7)* | Back to their last safe (grounded) spot on the map, after a short respawn delay as the penalty. |
| 10 | Which tasks ship at launch? *(added 2026-10-03, not from GDD §7)* | All eight: the four built plus `alarm-killswitch`, `breaker-sequence`, `reactor-sync` and `airlock-cycle`. |
| 11 | Which way up is the game played on a phone? *(added 2026-10-04, not from GDD §7)* | Landscape only, in both the Hub and the Match. |
| 12 | How long do Freeze and Push/Trip last? *(added 2026-10-06, not from GDD §7)* | Freeze 3.5s, Push/Trip 2s (with a ragdoll). Blind stays 4s. |

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

### Revision: currency, drops and pass tracks (2026-09-30, user decision)

Q1's fixed-package bounty is replaced, before RewardTables was ever
built. The user's reasoning: a streak is a run of coin flips, so long
streaks will be rare and the tiers must be much tighter; and in-game
drops should be rarer and worth more.

- **Every win pays currency**, scaled by the winner's streak and outcome
  tier (sole-stealer / minority-sharer / all-share). This is the same
  `currency` field Q8's free path already uses.
- **A win also rolls a chance at a random drop**: a power-up or cosmetic.
  Rarer items are harder to roll, and the odds of rarer items improve
  with the winner's streak. Random items exist **only** as win prizes.
- **Nothing bought is ever random.** Currency buys specific named items
  at fixed prices; there are no crates, for Robux or for currency. This
  matters because currency is itself sold for Robux, so a currency crate
  would be a paid random item. This keeps Q1's original reason (random
  virtual item rules) intact. Verify the current Roblox policy before
  launch.
- **Game passes are time-limited reward tracks.** A pass lists specific
  items unlocked at fixed win counts. Only wins between the purchase and
  the pass's set end point count. A Roblox pass is owned forever, so the
  window is ours to enforce: record when ownership is first seen, and a
  new track needs a new pass. The game can't grant a pass itself, only
  the items on its track. Q8 still applies: a power-up on a track must
  also be earnable free.
- **Leaderboards** (daily, weekly, all-time) pay currency and/or
  limited-edition items. Limited items are cosmetic only, per Q8.
- **The streak ladder** is one title per win from 1 to 10, then
  12, 14, 16, 18, 20, then every 5 up to 50: 21 rungs. It replaces
  P4-2's ten rungs (1…120), and it's also the streak-tier axis for
  currency and drop odds. User chose: 50 is the top.

All amounts and odds start as PLACEHOLDER, to be tuned in playtest.

*Applied (2026-10-02, user decision):* the 21 rungs' names. Existing
titles keep their ids and move to: Menace 16, Untouchable 35, Final
Boss 40 (Glow), Actual Villain 45 (Pulse), Touch Grass 50 (Rainbow).
New: Back To Back 2, Not A Fluke 4, Suspicious 6, Reported 7, Under
Review 8, Main Character 9, Sweaty 12, Tryhard 14, Lobby Ender 18,
Twenty Deep 20, Allegedly Legit 30. Unlocks stay append-only, so
anything already unlocked is kept. NPC bots now skip the top 6 rungs
(25 and up) rather than the top 3.

*Applied (2026-10-02, user decision):* how a win's reward is worked out.
- **The ladder replaces bountyTiers.** The five VU tiers are retired.
  A win pays a base currency amount for its outcome tier (sole stealer
  > lone sharer > all share > 0, the same ordering as before) times a
  multiplier that grows with the winner's rung.
- **The rung comes from the streak after this win**, so a first-ever
  win pays at rung 1, next to the title it just unlocked.
- **The drop pool** is every enabled power-up marked `freelyEarnable`,
  plus enabled cosmetics that opt in with `winDrop = true`. Founder,
  paid-only and limited cosmetics stay out unless a file opts them in.
- **A cosmetic the player already owns** still counts as the drop, and
  pays a fixed currency amount by rarity instead. The odds never shift
  with what a player owns.

*Applied (2026-10-02, user decision):* **which cosmetics can drop.**
Every cosmetic that no pass grants sets `winDrop = true`: Champion's
Flare, Gilded Frame, Rubber Duck, Sorry Not Sorry, Vault Door and
Wildfire. Founder's Kit and Founder's Trail (FounderPass) and Victory
Flex (VictoryEmotePass) stay pass-only (since moved to Season 1's
premium track; see "seasons and their tracks"). All nine are disabled until
they get assets, so until then only power-ups actually drop. A new
cosmetic opts in, or doesn't, in its own file.

*Applied (2026-10-02, user decision):* **what the leaderboards pay.**
- The daily and weekly boards pay their **top 10, in three bands**:
  #1, #2–3, #4–10. Daily pays 75 / 50 / 25 coins and weekly pays
  250 / 125 / 50, rescaled by "pricing" below; the first draft's
  500 / 250 / 100 is superseded (confirmed by the user 2026-10-04). All
  PLACEHOLDER until playtest.
- **The all-time board never pays.** Being on it is the prize.
- A band *can* name a limited cosmetic, but none does yet. Each limited
  item gets added later in its own cosmetic file. The field only takes a
  cosmetic id, so a leaderboard can't pay a power-up (Q8).
- Winners are usually offline when a period ends, so a payout is queued
  on their profile and lands the next time they join.
- *(2026-10-04, user decision)* **A period pays even if no server was
  running when it ended.** The first server to boot in the next period
  catches it up, guarded by the same snapshot as the normal rollover, so
  it still pays only once. This only reaches one period back
  (`leaderboard-scale.md` §8).

*Applied (2026-10-02, user decision):* **seasons and their tracks.**
- **Every pass lasts a set period, then another replaces it.** These
  are seasons. Each runs between fixed UTC dates, and no two overlap.
  FounderPass and VictoryEmotePass are retired, and their three
  cosmetics move to Season 1's premium track.
- **Each season has two tracks.** The premium track comes with the
  season's pass. The free track needs no pass and is less generous: it's
  a retention tool. The free track counts every win in the window. The
  premium track counts only wins after the pass was first seen owned.
  This follows the revision's "between the purchase and the end".
- **A track item can be a cosmetic, coins, or power-up stock**, and a
  track's first item can sit at 0 wins (paid as soon as the track starts
  counting). A power-up must be `freelyEarnable` (Q8). A pass grants
  nothing itself.
- **Track items are track-only forever.** A track cosmetic never drops,
  is never sold, and is never on another track or leaderboard band.
  Missing a season means missing its items.
- A pass is only sold while its season is running.

*Applied (2026-10-02, user decision):* **what coins buy.**
- **Power-up stock only**: one of each freely earnable power-up, at a
  fixed coin price (25 each, see "pricing" below). Not
  cosmetics, so win drops stay the only way to get the drop cosmetics.
  Track and leaderboard cosmetics stay exclusive anyway.
- **Each offer is its own store file** (`CoinOffer`): a `coinPrice`, no
  Roblox asset, and Validate refuses any grant but power-up stock.
- This makes Q8 literal: the stock Robux sells can also be bought with
  coins earned by playing.
- Checked against Roblox's paid-random-items policy on 2026-10-02:
  nothing sold is random, and win drops count as free gameplay rewards.
  Selling a luck boost, a crate or a paid round entry would need odds
  disclosure and a PolicyService gate. See store-receipts.md §6b.

*Applied (2026-10-02, user decision):* **pricing** (rewards-roadmap.md
step 7a). Every amount is still unconfirmed until a playtest.
- **Targets:** a casual (rung-0) player affords one power-up for every
  win, whatever the outcome, and a power-up costs about 29 Robux.
- **Win payouts unchanged** (100 / 50 / 25). payoff-table.md's streak-loss
  cost is in the same coins, so rescaling them would shift the
  Steal/Share balance. Instead a power-up costs 25 coins, the all-share
  payout. A rung-0 sole stealer therefore earns four.
- **Robux, best rate in the bundle:** 75 coins for 79 R$ (~26 each),
  250 coins for 249 R$ (~25), Sprint Boost x10 for 249 R$ (~25), and the
  15-item starter bundle for 349 R$ (~23).
- **Free track over the weekly board:** the Season 1 free track is worth
  about 15 power-ups (50 coins, 3 Sprint Boosts, 250 coins). Weekly #1
  pays 250 coins (10) and daily #1 pays 75 (3). Duplicate-drop coins and
  the premium track's coin step are scaled the same way.
- Not addressed: high-rung snowball (a rung-21 stealer earns 12
  power-ups a win). Left for playtest.

*Applied (2026-10-08, user decision):* **a much bigger reason to steal.**
- **Win payouts are now 250 / 50 / 25** (sole stealer / lone sharer /
  all share), up from 100 / 50 / 25. At rung 0, a sole steal now buys
  ten power-ups. This reverses the "win payouts unchanged" line above,
  so payoff-table.md's Steal/Share balance has to be rechecked.
- **The stakes have to be easy to see:** the Studio shows each choice's
  payout in large type, plus the win's **chance of an item drop as a
  percentage**, with its own icon. Only your own numbers are shown, as
  in the Q7 reveal case.

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
shows it. It is lifetime `steals`/`shares` counts from the profile.
Making it public later would need its own review under Q7.

**NPC history (2026-09-29, user decision):** bots must be
indistinguishable from humans, so an NPC no longer sends 0/0. Each bot
gets a small fixed history - `npc.historyFinales` (1-8) past finales,
each rolled from its hidden personality's steal probability
(`NPCBrainLogic.staticHistory`) - so a Greedy bot's line usually leans
steal and a Loyal one's leans share, with the noise a short record has.
Bots also wear real avatars drawn from `npc.appearance`, not a
placeholder rig.

*Applied (2026-10-02, user decision):* **a real player's result always
counts, however many seats are bots.** This reverses threat-model.md
§8's NPC-seat streak-credit threshold. The user's reasoning: a player
can't choose a bot-filled lobby (it only happens when nobody else is
queueing), and bots are trained to vary their answers, so winning one
is still luck rather than a farm. A win in such a round raises the
streak and pays the full reward at the new rung, like any other.
- Built (rewards-roadmap.md step 2d): the threshold, its check and its
  "queue too thin" message are gone, and threat-model.md §8 records the
  mitigation as retired.
- **Planned:** separate practice and ranked modes. Practice pays no
  rewards. Not built yet; ask before designing it.

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

### Applied case: the Hub streak counter and StreakFlair (P4-6)

The StreakFlair cosmetic needed a streak counter to dress. Decided with the
project owner (2026-09-30): **a counter over each player's head, on the Hub
server only.** That is condition 1's own "hub" allowance, read strictly: a
match server's pre-round lobby does not count, because everyone standing in
it is about to race you. Enforced server-side: `StreakTagService` is inert
unless `StreakTagLogic.isHub`, so a match server never sends
`StreakTagState`. The number is always the real `currentStreak`; flair
changes only its colour and backing texture.

### Applied case: after every finalist has locked in (2026-10-02)

Decided by the project owner: **a finalist's level (streak, rung, and
anything scaled by them, such as a win's coin payout) may be revealed
once all three finalists' choices are locked in.** Nothing shown after
that point can change the outcome, so condition 1 has nothing left to
protect in that round. Before lock-in, everything above still holds:
the payoff table names prizes in words only, and titles and streaks stay
hidden through the intro, Negotiate and Choose.
- "Locked in" means every choice is final: all three finalists
  submitted, or the Choose timer filled in the defaults (Q4). In code,
  that is the moment DecisionService computes the outcome.
- **Applied (2026-10-02, user decision): the reveal shows only your
  own payout.** A winner sees their own coins and drop on the result
  panel. Another finalist's payout is never sent to your client, even
  though this case would allow it. Built in rewards-roadmap.md step 3
  (`DecisionPersonalResult.reward`, targeted).
- This permits, but doesn't require, showing amounts or levels in the
  reveal. It widens the P4-2
  titles case's "after the result is in" to this slightly earlier
  moment, but doesn't change `TitleService` by itself.

### Applied case: buying back a streak (2026-10-08, user decision)

- **Who:** any player who loses a round while holding a streak of 1 or
  more. That covers Studio losers, 4th–6th place, and anyone below Q2's
  50% floor. The offer appears on their own end screen. There's **no
  limit** on how often it can be bought.
- **Price, by the streak being saved:** 1 → 99 R$, 2 → 119, 3 → 149,
  4 → 179, 5 → 209, 6 → 239, 7 → 269, **8 or more → 299 (the cap)**.
  Every price ends in 9.
- **Effect:** the reset from this loss is cancelled. The streak stays
  as it was and isn't increased.
- **Q7 still holds:** the offer and its price (which reveals your
  streak) are only ever sent to that player, and only after the match.
- **Known cost:** a leaderboard streak can now survive a loss for
  money, which works against Q7's "everyone but the winner resets".
  The owner accepted this. P0-7's paid-vs-free tripwire should also
  track how many saves are bought on top-100 streaks.
- **How long the offer lasts (2026-10-08, user decision):** until that
  player's next race starts. Results is only 24 s, and a Studio loser
  sees about 7 s of it after the reveal, so the offer is shown on the
  end screen and again in the Hub after the teleport. It is stored in
  the profile, so a purchase that completes mid-teleport still lands.
  A new loss replaces it, and the start of any race expires it.
- **A receipt with nothing to save (2026-10-08, user decision):** if a
  buy-back receipt arrives when the offer has already expired, or for
  the wrong price tier, it is confirmed and grants nothing, with a loud
  log line. The normal flow can't get there: the server chooses the
  product and refuses the prompt once the offer is gone. Only a
  tampered client calling the prompt directly can.

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

### Applied case: the Locker and choosing a loadout (2026-10-08)

Decided by the project owner. The loadout is picked in the hub's Locker
screen and checked on a strip shown during the queue countdown. A
fixed-length picker on the match place's loading screen was rejected,
because it would add a wait to every round for every player, including
the many who own nothing.
- **An item with no stock leaves its slot empty.** Nothing substitutes
  another stocked item for it. The queue strip shows the empty slot with
  a red "0" badge, so the player notices before the match.
  (`StoreLogic.consumeLoadout` already drops entries with no stock rather
  than granting them on credit.)
- **The Locker says up front that items are spent at race start**,
  whatever the round's outcome. Losing a round still costs the loadout,
  and that should never come as a surprise.
- **The loadout can be edited until the teleport begins.** That includes
  the queue countdown. `StoreLoadoutIntent` is accepted while queued and
  closes when `MatchTeleportService` marks the group as departing.
- **The loadout never repeats on its own, and there is no confirm
  step.** Spending clears it (`StoreService.consumeLoadoutFor`), so by
  default nothing is spent. A player who used a loadout last round sees
  a one-tap **"Same as last round"** button on the queue strip. It
  re-arms last round's picks, skipping any with no stock left. A
  per-round confirm button was rejected because it adds a step to every
  round, and a player who never answers it still needs a default.
- Practice pickups (`practice-area.md`) never appear in the Locker. In
  the HUD they're marked as practice and carry no count badge, while
  owned stock always shows one.

### Applied case: Navigation (2026-10-08, user decision)

- **What it does:** a toggle next to the direction HUD in a match. While
  it's on, a path line leads to the nearest station the player hasn't
  finished yet, until the round ends.
- **For one round:** 99 R$, or **100 coins**. **Unlimited:** a 899 R$
  pass, sold for Robux only. (Coin price set by the owner on 2026-10-08.
  Robux parity is about 85 coins, so the Robux round is slightly better
  value.)
- **Why Q8 still holds:** every free player can turn it on in any round
  by paying coins. Robux only buys the convenience of never paying again,
  not anything a free player can't have. This is the first coin offer
  that isn't power-up stock, so `CoinOffer` validation allows it as a
  named exception. Validate also refuses to boot when Navigation is sold
  for Robux but no enabled coin offer sells a round.
- The path line is drawn only on the owner's client. Nobody else can see
  that a player is using it.
- **Where a round is bought** (owner, 2026-10-08): only from the toggle,
  during a race. Tapping it with nothing to spend opens a small sheet
  offering 99 R$ or 100 coins. Rounds are never sold in the Hub grid, and
  the server refuses a round purchase outside a race. The pass is sold
  in the Hub store.
- **When a round is spent** (owner, 2026-10-08): on the first switch-on
  of a race. Switching off and on again in that race is free. A round
  bought from the sheet switches Navigation on by itself. If a receipt
  lands after its race has ended, the round is kept for the next race.
  A pass owner never spends a held round.

---

## 9. Where does a KillZone put a fallen racer?

*Added 2026-10-03 (user decision). Not one of GDD §7's questions; it came
up in the Laboratory playtest.*

**Context:** `map-kit-spec.md` defines `KillZone` as a volume that
"returns a fallen player to safety", and the P7-1 validator requires one
under every gap. But no service ever read the tag, so on every map a
kill zone did nothing. In the Laboratory playtest a racer fell into the
coolant moat around the reactor platform and couldn't get out.

**Decision:** When a racer touches a `KillZone`, the server returns them to
their **last safe spot**: the last position where the server saw them
standing on map geometry. A short respawn delay is the penalty. They
keep their task progress and items.

**Reasoning:** Their progress survives, so a fall costs seconds, not the
round. The delay still makes deliberately diving off geometry a bad trade.
Sending them back to their spawn pad was rejected: near the end of a
race, that would cost the whole walk back. The nearest NavNode was also
rejected, because on a vertical map it can be on a different level from
the one they fell off.

**Downstream:** a new server service. It tracks each racer's last grounded
position and handles `KillZone` touches for humans and NPCs, then
returns the racer with `PivotTo`. MovementWatch must treat that move as a
server-authorised teleport, not a speed violation.

## 10. Which tasks ship at launch?

*Added 2026-10-03 (user decision). One of the owner questions in
`next-stages.md`, not one of GDD §7's.*

**Decision:** All eight. The four already built (`code-playback`,
`fuse-rewire`, `pressure-valve`, `vent-purge`) plus the four in
next-stages step 5: `alarm-killswitch`, `breaker-sequence`,
`reactor-sync` and `airlock-cycle`.

**Downstream:** step 5 builds the four, one per session. As each lands,
add its id to the four launch maps' `enabledTaskIds`, and add it to the
`AcceptedTaskIds` of every station whose Target list in
`maps/wave1-briefs.md` names it (a Match.rbxl edit).

## 11. Which way up is the game played on a phone?

*Added 2026-10-04 (user decision), during the mobile audit
(next-stages step 15). Replaces "portrait-first" in the ground rules.*

**Decision:** Landscape only. The client sets
`PlayerGui.ScreenOrientation = LandscapeSensor` from the first frame
(`src/first/LoadingCover.client.luau`), so a phone plays either way up
in landscape and never rotates upright, in both the Hub and the Match.
Both `.rbxl` files also set `StarterGui.ScreenOrientation` to
`LandscapeSensor`: Roblox copies StarterGui's value onto PlayerGui after
ReplicatedFirst runs, so the Hub's old `Sensor` overrode the code (the
code now re-asserts on change, as a backstop).

**Why:** on an iPhone in portrait the whole game looked off; every
screen already had a landscape layout.

**Downstream:** the portrait branches of the layouts (RaceHUD,
DecisionStudio, MenuShell, the task views) stay for now. They never run
on a phone, but still apply to a tall Studio viewport or a tablet
window. Tasks still need only one thumb. The mobile checklist now
checks landscape only.

## 12. How long do Freeze and Push/Trip last?

*Added 2026-10-06 (user decision), after the victim looks went in
(an ice block for Freeze, a ragdoll for Push/Trip).*

**Decision:** Freeze 2.5s → **3.5s**; Push/Trip 1s → **2s**. Blind stays
at 4s. Set in each item's config (`durationSeconds`); `powerups.md`'s
table matches.

**Why:** at the old lengths the new looks were over before they read -
a 1s ragdoll is barely a stumble. The user first asked for 3-4s on
everything; the agreed numbers keep Push/Trip shorter because it is the
Common, 7s-cooldown attack, and a long stun on the cheap item is the
most frustrating thing a phone player can be hit by. It also keeps the
two hard-control items feeling different.

**Unchanged:** the anti-frustration layer (`powerups.md`) - the 3s
post-effect immunity, diminishing returns and the 15s rolling cap still
bound the worst case, now reached in fewer hits.
