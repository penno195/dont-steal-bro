# Don't Steal Bro! — Steal/Share Payoff Table (P0-4)

Tunes the Decision Studio's payoff numbers and shows the game-theory behind
them. Since `design-decisions.md` Q1's 2026-09-30 revision, a win pays
**currency (coins)**: `RewardLogic.currencyFor` gives the outcome tier's
base (`GameConfig.winRewards.currency`) times `1 + perRungBonus × rung`,
where the rung is how many title-ladder rungs the winner's streak reaches
*after* this win. A win also rolls a chance at a drop, which this EV model
leaves out (it's the same for Steal and Share, so it can't tip the choice).

Until 2026-10-02 (rewards-roadmap.md step 2c) this doc priced payoffs in
abstract **value units (VU)** over five `bountyTiers`. The first coin
bases (100 / 50 / 25) were exactly 5× the old tier-1 VU (20 / 10 / 5), so
the conversion was clean: **1 VU = 5 coins at rung 0**. On 2026-10-08 the
owner raised the sole-steal base to **250** ("a much bigger reason to
steal", design-decisions.md Q1), so the bases are now **250 / 50 / 25** and
every table below uses them. Every number here is a PLACEHOLDER starting
value, to be corrected by the telemetry in §4 (and rewards-roadmap.md
step 7), not a final one.

Players never see these numbers while choices are open. The payoff table
on screen names prizes in words (BIG / MEDIUM / SMALL), because an amount
that scales with your streak would tell the room what your streak is
(Q7). Once all three choices are locked in, amounts and levels may show
(Q7's 2026-10-02 applied case).

## 1. Setup

From a single finalist's point of view, let **k** be how many of the
*other two* finalists choose Steal (k ∈ {0, 1, 2}). Reading the outcome
table from their seat:

| Your choice | k=0 (others both Share) | k=1 (one other Steals) | k=2 (both others Steal) |
|---|---|---|---|
| **Steal** | Sole stealer → **Large (L)** | 2 Steal, 1 Share → you lose | 3 Steal → you lose |
| **Share** | 3 Share → **Smallest (S)** | 1 Steal, 2 Share → you lose | 2 Steal, 1 Share → **Medium (M)** |

This table is the whole game, and it's already more interesting than a
standard Prisoner's Dilemma: Share isn't the safe, low-ceiling option —
it wins at *both* extremes (k=0 and k=2) and only loses in the single
middle case. Steal has the single best cell (L) but loses in two of the
three cases. That asymmetry, not a flat "cooperate vs. defect" framing, is
what has to be tuned.

Let **p** be the probability any one other finalist independently chooses
Steal (a symmetric population belief), and **Closs** the cost of losing —
which is not an arbitrary number, it's the value of the streak being reset
(see §4). Then:

```
EV(Steal) = L·(1-p)² − Closs·(2p − p²)
EV(Share) = S·(1-p)² + M·p² − Closs·2p(1-p)
```

Setting `EV(Steal) = EV(Share)` and simplifying (the `2p(1−p)` and
`2p−p²` terms collapse to a clean `p²` difference) gives the indifference
point — the population steal-rate at which a rational player has no
preference:

```
(L − S)(1 − p)² = (M + Closs)·p²
p* = 1 / (1 + √((M + Closs) / (L − S)))
```

Below `p*`, Steal is the better individual response; above it, Share is.
Under naive best-response dynamics this is a **stable** attractor: at low
population steal-rates Steal looks great (temptation to exploit
cooperators), which pushes more players toward it; at high steal-rates
Share looks great (being the lone holdout against a greedy table), which
pulls the population back down. The lobby's actual steal-rate should
oscillate around `p*`, not collapse to 0 or 1 — that's the "tension, not a
dominant strategy" the brief asks for, and it falls out of the numbers
rather than needing to be forced in separately.

## 2. Baseline numbers (streak 1 going in, so a win reaches rung 2)

| L (sole steal) | M (lone share vs. 2 stealers) | S (3-share) | Closs (streak 1) |
|---|---|---|---|
| 300 coins | 60 coins | 30 coins | 10 coins |

Plugging in: `p* = 1 / (1 + √((60+10)/(300−30))) = 1 / (1 + √0.26) ≈ 0.66`.
(At the old 100 base, L was 120 and p* was 0.53.)

### Three population assumptions, at this streak

| Assumption | p | EV(Steal) | EV(Share) | Favored |
|---|---|---|---|---|
| Mostly cooperative | 0.2 | **188.4** | 18.4 | Steal, overwhelmingly |
| Mixed (≈ equilibrium) | 0.66 | 25.3 | 25.3 | Indifferent |
| Mostly greedy | 0.8 | 2.4 | **36.4** | Share, strongly |

Reading this: if you believe the table is mostly going to Share, betraying
them is the single most profitable move in the game — that's the
temptation that keeps 3-Share from being a boring default. If you believe
the table is mostly greedy, Share stops being the cautious choice and
becomes the objectively *better* one (you collect the Medium reward as the
lone holdout while the stealers destroy each other). Neither strategy
dominates once you average over genuine uncertainty about the other two —
which is the real condition at the table, especially given `design-
decisions.md` Q7 keeps streak hidden in-round, so a player is reasoning
about *behavior* (aided by the Q5 reputation history — visible steal/share
rate — which they should and will use), not about who specifically has the
most to lose.

## 3. Should bounty or risk scale with streak?

**Both — but at different rates, and risk should scale faster, and
mostly for free.** `Closs` isn't a number that needs inventing: losing
resets the streak, so the cost of losing *is* the streak itself. A
12-streak player risking a loss is risking 12 levels of progress; a
1-streak player is risking 1. That relationship is already linear (at
minimum) with zero extra design work — `Closs(n) = n · c₀` for some small
constant `c₀`.

Reward grows with the **rung**, not the streak: one rung per win to 10,
then every 2 wins to 20, then every 5 to 50 (21 rungs). Each rung adds a
flat `perRungBonus` (10%) of the base, so reward grows linearly in rungs
and *slower* than the streak itself past 10. That gap is the actual lever,
and it should be kept, not closed: letting reward scale more slowly than
risk is what makes a big streak feel increasingly precious to protect
rather than just proportionally more lucrative to gamble.

Using `c₀ = 10` coins (`GameConfig.streakLossWeight`; 2 VU before the
conversion) and the current PLACEHOLDER `winRewards`:

| Streak going in (n) | Rung after a win | L / M / S (coins) | Closs = 10n | p* |
|---|---|---|---|---|
| 0 (first-ever finale) | 1 | 275 / 55 / 27 | 0 | 0.68 |
| 1 | 2 | 300 / 60 / 30 | 10 | 0.66 |
| 4 | 5 | 375 / 75 / 37 | 40 | 0.63 |
| 8 | 9 | 475 / 95 / 47 | 80 | 0.61 |
| 12 | 11 | 525 / 105 / 52 | 120 | 0.59 |
| 18 | 14 | 600 / 120 / 60 | 180 | 0.57 |
| 30 | 17 | 675 / 135 / 67 | 300 | 0.54 |
| 49 | 21 (top) | 775 / 155 / 77 | 490 | 0.51 |

(Amounts are floored, as `currencyFor` does.) Streak 0 is a real case,
not an edge: a first-ever finalist has nothing to lose, so their p* is the
table's highest. The old VU table needed a fix for it, because its lowest
tier started at streak 1; the rung formula covers streak 0 by construction.

`p*` falls monotonically from 0.68 to 0.51 as streak climbs — exactly the
"more to lose, more cautious" effect the brief asks for, derived rather
than hand-set. It doesn't hit 0: even at streak 49, Steal remains the
better response whenever a player believes fewer than ~51% of the table
will steal, so a high-streak lobby is never a foregone conclusion. The
250 base lifted every row by about 0.13 (it was 0.55 → 0.38) but left the
downward slope intact.

### The same three scenarios, at streak 18 (rung 14)

| Assumption | p | EV(Steal) | EV(Share) | Favored |
|---|---|---|---|---|
| Mostly cooperative | 0.2 | **319.2** | −14.4 | Steal, overwhelmingly |
| Mixed (≈ equilibrium) | 0.57 | −37.7 | −37.7 | Indifferent |
| Mostly greedy | 0.8 | −148.8 | **21.6** | Share, decisively |

Notice the swings are far more violent than at streak 1 (−148.8 vs. 2.4
at the greedy extreme; a *negative* Share EV at the cooperative extreme,
which streak 1 never sees). This is the intended effect of §3's asymmetric scaling:
a high-streak player isn't just risking a bigger number, they're playing a
version of the same game with dramatically higher variance at both ends,
which is what should make the Decision Studio feel like the climax the
GDD frames it as once someone's sitting on a real streak.

### What the 250 base does to the outcome mix (recheck, 2026-10-08)

The tension still holds: neither choice dominates at any streak, and p*
still falls as the streak climbs. But a population sitting at p* now
steals more often than not at low streaks, and that moves the outcome
mix. If each finalist steals independently at the p* for their row:

| Streak going in | p* | 3-Steal (all lose) | Sole steal | 3-Share |
|---|---|---|---|---|
| 0 | 0.68 | 31% | 21% | 3% |
| 1 | 0.66 | 29% | 23% | 4% |
| 18 | 0.57 | 19% | 31% | 8% |
| 49 | 0.51 | 13% | 37% | 12% |

At low streaks, the predicted 3-Steal rate (~30%) is above §4's
15–20% warning line for "trust has collapsed". That is the cost of a
much bigger reason to steal. It is a prediction, not a measurement:
real players lean toward cooperating (and the Q5 reputation display
pushes that way), so the telemetry in §4 decides whether it lands. If
3-Steal really does run above ~20%, the levers are: raise `c₀`, raise
`M` (the lone sharer's reward), or trim `L` back toward 200. 3-Share
becoming rare (3–4%) is intended here, since a formality finale was
what the change was meant to kill.

## 4. Telemetry: three metrics to watch, and which way to move the numbers

**1. Observed steal-rate vs. the modeled `p*`, segmented by rung.**
Log every Studio decision with the deciding player's rung and choice. If
the empirical steal-rate is persistently *above* that rung's `p*`, players are stealing more than the maths says is rational — either
they undervalue the loss emotionally, or `L` is priced too temptingly
relative to `Closs`. **Direction:** lower `L` or raise `c₀`. If it's
persistently *below* `p*`, Share is over-rewarded relative to the
temptation — **raise `L`** or narrow the `M`/`S` gap so lone-stealing pays
off more often than it currently seems to.

**2. Outcome-type distribution (1-Steal/2-Steal/3-Share/3-Steal split).**
Watch for any single outcome dominating. If 3-Share exceeds roughly 50–60%
of Studios, the finale is reading as a formality, not a decision —
**lower `S`** or raise `L` to sharpen the temptation. If 3-Steal (mutual
destruction — the worst outcome for everyone) exceeds roughly 15–20%,
trust has collapsed and the Studio is reading as pointless paranoia rather
than tension — **raise `Closs`'s weight relative to `L`**, or check
whether the Q5 reputation display is actually visible/legible enough for
players to use it to build trust over repeat sessions.

**3. Steal-rate slope across rungs.** This is the direct test of
§3's central claim — steal-rate should *decrease* as the rung
increases. If the observed slope is flat or, worse, reversed (high-streak
players stealing as much or more than low-streak ones, e.g. because a big
streak makes them feel invincible rather than cautious), the loss-aversion
effect isn't landing. **Direction:** if high-streak players steal too
often, steepen `Closs(n)` (raise `c₀`, or make it convex above a
threshold) or slow down streak-rebuild pacing so a reset is felt more;
if high-streak players *never* steal (predictable, boring finales at the
top of the leaderboard), flatten `Closs(n)` slightly or add a small `L`
premium at the top rungs to keep some temptation alive even at the summit.

## 5. What this doesn't cover

Q4's disconnect handling (leaver forced-loss, substituted Share vote for
the other two) is a deliberate non-strategic override for a rare edge
case — it doesn't change any number above, it just fixes one player's
action in that scenario rather than leaving it to the EV model. The
numbers here assume three live, connected decision-makers.
