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

## Next

- [ ] **2b. Grant win rewards.** Nothing calls RewardLogic yet.
  - On a win, roll `RewardLogic.rollWinReward`. Use the streak after the
    win, the title thresholds (every TitleDef's `minStreak`), and a pool
    built from the PowerUps and Cosmetics registries. Server rng:
    `Random.new()`.
  - Apply the grants with `StoreLogic.applyGrants` through DataService,
    once per round per player. ProgressionService's round ledger is the
    idempotency key, so a retry can't pay twice. Log a single audit line
    for each grant.
  - Replace `PendingBounty` (streakTier + outcomeTag) with a record of
    what was granted. This is a profile schema bump (v4 migration in
    ProfileLogic).
  - Send the reward in the `RoundRecap`, which only goes out at Results.
    Q7: nothing about a reward may show during a live round.
  - Rounds without streak credit (NPC seats over the threshold) still
    pay rewards. That's the existing rule in ProgressionLogic.applyResult.
- [ ] **2c. Retire `bountyTiers`.**
  - Outcomes and DecisionService currently carry `*VU` numbers from
    `bountyTiers`. Switch them to `RewardLogic.currencyFor` at the
    after-win rung, then delete `BountyTier`, `resolveBountyTier`,
    their checks and their specs.
  - Move LiveConfig's allowlisted paths from `game.bountyTiers.*` to
    `game.winRewards.*`, and update its spec.
  - Update the docs that describe VU tiers: `payoff-table.md`,
    `live-ops.md`, `launch-review.md` and `liveops-roadmap.md`. The
    payoff table's Steal/Share balance now runs on currency.
- [ ] **3. Show win rewards.**
  - Results and the finale show the currency and the drop. This
    replaces `FinaleLoading`'s stand-in glyphs.
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
