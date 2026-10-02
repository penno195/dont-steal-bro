# Rewards roadmap: building Q1's revision

The build order for design-decisions.md Q1's 2026-09-30 revision
(currency, win drops, pass tracks, leaderboard payouts) and its applied
cases. **One step per session, then `/clear`.** Tick a step off here, in
the same commit that finishes it.

Read Q1 and its applied cases in `docs/design-decisions.md` before
starting any step. If a step hits a question they don't answer, stop
and ask the user (CLAUDE.md).

## Done

- [x] **1. Title ladder retune.** 21 rungs topping at 50; the ladder is
  also the reward rung axis. `303f200`.
- [x] **2a. Win-reward config and pure logic.**
  - `GameConfig.winRewards` holds the currency bases per outcome tier,
    the per-rung bonus, drop chance and rarity weights, and the
    duplicate payouts. All PLACEHOLDER. Validate checks them, and
    `CosmeticDef.winDrop` is the opt-in flag for the drop pool.
  - `src/server/RewardLogic.luau` covers the rung, the currency, the
    drop pool and the roll, and returns StoreLogic-shaped grants.
    Specs: `tests/RewardLogic.spec.luau`, plus `Config.spec`'s win
    rewards block.
- [x] **2b. Grant win rewards.**
  - `ProgressionService.applyRoundResult` rolls the reward on a win
    (streak after the win, every title's `minStreak`, a pool rebuilt per
    roll from enabled power-ups and cosmetics), keeps it in the round
    ledger so a retry returns it rather than re-rolling, and logs one
    `Reward:` line per grant.
  - DataService's progression writer applies the streak, the grants
    (`StoreLogic.applyGrants`) and the record in one mutation.
  - Profile schema v4: `pendingBounty` dropped, `lastWinReward` added.
  - `RoundRecap.reward` carries it at Results; the results screen shows
    a plain stand-in line until step 3.
  - User decision while building it: a real player's win always counts
    however many seats are bots (design-decisions.md Q5 applied case),
    which added step 2d.
- [x] **2c. Retire `bountyTiers`.**
  - Outcomes gives each winner an `outcomeTag` and no amount, rather
    than switching the `*VU` numbers to currency as first planned, so
    currency comes only from `RewardLogic.currencyFor`, in
    ProgressionService. (2c's commit also claimed an amount in
    `DecisionReveal` would leak streaks. The user then ruled that levels
    may show once all choices are locked in, so it wouldn't: Q7's
    2026-10-02 applied case.)
  - `BountyTier`, `resolveBountyTier`, `bountyTiers`, their checks and
    specs are gone. LiveConfig allows `game.winRewards.**`.
  - payoff-table.md runs on coins (1 VU = 5 coins at rung 0, so
    `streakLossWeight` became 10), with p* recomputed per streak.
    live-ops, launch-review, liveops-roadmap and decision-studio updated.

## Next

- [ ] **2d. Retire the NPC-seat streak-credit threshold.** Per
  design-decisions.md Q5's 2026-10-02 applied case, a real player's
  result always counts. The threshold is set to 5 today so it never
  fires.
  - Remove `npcSeatStreakCreditThreshold` (GameConfig, Validate,
    Config.spec), `NPCLogic.earnsStreakCredit`, NPCService's
    `roundEarnsStreakCredit`, and ProgressionService's credit gate and
    `roundEarnsStreakCredit` export.
  - Drop `applyResult`'s `streakCredited` parameter and its specs.
  - Drop `RoundRecap`'s `streakCredited`, `npcSeatCount` and
    `npcSeatThreshold`, plus ResultsLogic's "Held" streak change.
  - Update threat-model.md §8 (and its ranking table), npc-notes.md and
    launch-review.md to say the mitigation was retired, and why.
- [ ] **3. Show win rewards.**
  - Results and the finale show the currency and the drop. This
    replaces `FinaleLoading`'s stand-in glyphs.
  - The reveal may show everyone's amounts and levels, since it follows
    lock-in (Q7's 2026-10-02 applied case). Before lock-in, prizes stay
    words only. **Ask the user** whether the reveal should show other
    finalists' payouts or just your own.
  - **Ask the user** which cosmetics set `winDrop = true`. None do yet,
    so today only power-ups can drop.
- [ ] **4. Leaderboard payouts.**
  - Give LeaderboardService's daily/weekly reward hook a receiver. It
    has none today.
  - Payouts are currency and/or limited cosmetics, and limited means
    cosmetic only (Q8).
  - **Ask the user** for the amounts, the placement cut-offs and the
    limited items, and whether the all-time board pays at all.
- [ ] **5. Pass reward tracks.**
  - Add a track config: the pass, a start and an end, and items
    unlocked at win counts. Only wins inside the window count.
  - Store when ownership was first seen, plus each track's win count.
    This needs a schema bump.
  - Grant items as the counts are reached. A new track needs a new
    pass, and Q8 still applies: a power-up on a track must also be free
    to earn.
  - **Ask the user** what happens to `FounderPass` and
    `VictoryEmotePass`.
- [ ] **6. Store audit.**
  - Currency buys specific named items at fixed prices.
  - Check that nothing bought is random, for Robux or for currency.
  - Verify Roblox's current random-item policy before launch.
- [ ] **7. Tune in playtest.** Every amount and odd is PLACEHOLDER.
  Q8's "Robux buys time, never power" rests on these numbers.
