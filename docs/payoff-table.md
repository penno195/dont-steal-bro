# Don't Steal Bro! — Steal/Share Payoff Table (P0-4)

Tunes the Decision Studio's payoff numbers and shows the game-theory behind
them. Per `design-decisions.md` Q1, "bounty" is a fixed item package, not a
currency shown to the player — the **value units (VU)** below are an
internal design currency for balancing, not something a player ever sees.
They exist to (a) decide which item-tier bracket a `RewardTables` lookup
should assign per (streak tier, outcome tier), and (b) drive the pure,
`--!strict`-testable EV maths this document is built on, per Ground Rule 4.
Treat every number here as a starting value for `Outcomes.luau`'s config,
to be corrected by the telemetry in the closing section — not as final.

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

## 2. Baseline numbers (streak tier 1, e.g. streak 1–2)

| L (sole steal) | M (lone share vs. 2 stealers) | S (3-share) | Closs (streak 1) |
|---|---|---|---|
| 20 VU | 10 VU | 5 VU | 2 VU |

Plugging in: `p* = 1 / (1 + √((10+2)/(20−5))) = 1 / (1 + √0.8) ≈ 0.53`.

### Three population assumptions, at this tier

| Assumption | p | EV(Steal) | EV(Share) | Favored |
|---|---|---|---|---|
| Mostly cooperative | 0.2 | **12.1** | 3.0 | Steal, strongly |
| Mixed (≈ equilibrium) | 0.53 | 2.7 | 2.7 | Indifferent |
| Mostly greedy | 0.8 | −1.1 | **6.0** | Share, strongly |

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

Reward, per Q1, is bucketed into coarse **streak tiers**, not continuous —
which means it naturally grows *slower* than the streak itself the higher
you climb. That gap is the actual lever, and it should be kept, not closed:
letting reward scale as slowly as risk grows is what makes a big streak
feel increasingly precious to protect rather than just proportionally more
lucrative to gamble.

Using `c₀ = 2` and a 5-tier reward bracket that grows modestly per tier:

| Tier | Streak range | L / M / S (VU) | Representative streak (n) | Closs = 2n | p* |
|---|---|---|---|---|---|
| 1 | 1–2 | 20 / 10 / 5 | 1 | 2 | 0.53 |
| 2 | 3–5 | 24 / 12 / 6 | 4 | 8 | 0.49 |
| 3 | 6–9 | 28 / 14 / 7 | 8 | 16 | 0.46 |
| 4 | 10–14 | 32 / 16 / 8 | 12 | 24 | 0.44 |
| 5 | 15+ | 36 / 18 / 9 | 18 | 36 | 0.41 |

`p*` falls monotonically from 0.53 to 0.41 as streak climbs — exactly the
"more to lose, more cautious" effect the brief asks for, derived rather
than hand-set. It doesn't hit 0: even at tier 5, Steal remains the better
response whenever a player believes fewer than ~41% of the table will
steal, so a high-streak lobby is never a foregone conclusion.

### The same three scenarios, at tier 5 (streak 18)

| Assumption | p | EV(Steal) | EV(Share) | Favored |
|---|---|---|---|---|
| Mostly cooperative | 0.2 | **10.1** | −5.0 | Steal, very strongly |
| Mixed (≈ equilibrium) | 0.41 | ≈0 | ≈0 | Indifferent |
| Mostly greedy | 0.8 | **−33.1** | 0.4 | Share, decisively |

Notice the swings are far more violent than tier 1's (−33.1 vs. −1.1 at the
greedy extreme; a *negative* Share EV at the cooperative extreme, which
tier 1 never sees). This is the intended effect of §3's asymmetric scaling:
a high-streak player isn't just risking a bigger number, they're playing a
version of the same game with dramatically higher variance at both ends,
which is what should make the Decision Studio feel like the climax the
GDD frames it as once someone's sitting on a real streak.

## 4. Telemetry: three metrics to watch, and which way to move the numbers

**1. Observed steal-rate vs. the modeled `p*`, segmented by streak tier.**
Log every Studio decision with the deciding player's streak tier and
choice. If the empirical steal-rate is persistently *above* the tier's
`p*`, players are stealing more than the maths says is rational — either
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

**3. Steal-rate slope across streak tiers.** This is the direct test of
§3's central claim — steal-rate should *decrease* as streak tier
increases. If the observed slope is flat or, worse, reversed (high-streak
players stealing as much or more than low-streak ones, e.g. because a big
streak makes them feel invincible rather than cautious), the loss-aversion
effect isn't landing. **Direction:** if high-streak players steal too
often, steepen `Closs(n)` (raise `c₀`, or make it convex above a
threshold) or slow down streak-rebuild pacing so a reset is felt more;
if high-streak players *never* steal (predictable, boring finales at the
top of the leaderboard), flatten `Closs(n)` slightly or add a small `L`
premium at the top tier to keep some temptation alive even at the summit.

## 5. What this doesn't cover

Q4's disconnect handling (leaver forced-loss, substituted Share vote for
the other two) is a deliberate non-strategic override for a rare edge
case — it doesn't change any number above, it just fixes one player's
action in that scenario rather than leaving it to the EV model. The
numbers here assume three live, connected decision-makers.
