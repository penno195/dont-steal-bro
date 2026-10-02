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
- [x] **2d. Retire the NPC-seat streak-credit threshold.** Per Q5's
  2026-10-02 applied case, a real player's result always counts.
  - `npcSeatStreakCreditThreshold`, `NPCLogic.earnsStreakCredit`, both
    `roundEarnsStreakCredit`s, `applyResult`'s `streakCredited`,
    RoundRecap's credit fields and ResultsLogic's "Held" kind are gone,
    with their specs.
  - threat-model.md §8, npc-notes.md and launch-review.md record the
    mitigation as retired. Bot-lobby farming is now watched by
    telemetry only (`NPCService.getNPCSeatCount`).
- [x] **3. Show win rewards.**
  - User decisions (design-decisions.md Q1 and Q7 applied cases): the
    reveal shows only your own payout, and the six cosmetics no pass
    grants set `winDrop = true` (all still disabled pending assets).
  - `DecisionPersonalResult` carries a winner's own `reward`
    (`ProgressionService.rewardFor`, after the reveal, targeted). The
    ledger also keeps `dropAmount`, the drop grant's count or coins.
  - `UI/PayoutLogic.luau` parses and words a payout for both screens
    (`tests/PayoutLogic.spec.luau`). `UI/DropNames.luau` names drops
    from config.
  - The Studio's result panel shows "+N coins" and a drop row with the
    item's icon. Results splits the payout into a Coins card and its own
    Drop beat. `FinaleLoading`'s stand-in glyphs became coin piles (3/2/1),
    still no amounts before lock-in.
  - Also cleared 2d leftovers: DecisionLogic's "no streak credit" copy,
    decision-studio.md and store-receipts.md.
- [x] **4. Leaderboard payouts.**
  - User decisions (design-decisions.md Q1 applied case): the top 10 are
    paid in bands (#1, #2–3, #4–10). Daily pays 500/250/100 and weekly
    pays 4x that. The all-time board never pays. A band can name a
    limited cosmetic, but none does yet.
  - `GameConfig.leaderboard.payouts` replaced `rewardTopN`. Validate
    checks the bands and that any `cosmeticId` is a real cosmetic.
  - `LeaderboardPayoutLogic.luau` is the pure part
    (`tests/LeaderboardPayoutLogic.spec.luau`).
  - `LeaderboardPayoutService` claims the reward hook. It queues each
    payout on the winner's profile with `ProfileStore:MessageAsync`,
    because winners are usually offline. DataService routes profile
    messages by `type` (`routeProfileMessages` / `sendProfileMessage`),
    and applies the grants and the processed mark in one step.
  - Verified in Studio (mock ProfileStore) with an online player:
    Daily #1 paid 500, Weekly #5 paid 400, and a malformed message was
    dropped. Delivery to an offline player, picked up when they next
    join, needs a published place to test.
  - There's no on-screen "you placed #N" notice yet. The coins just
    arrive and StoreState refreshes.

- [x] **5. Pass reward tracks.**
  - User decisions (design-decisions.md Q1 applied case, "seasons and
    their tracks"): every pass is a season with fixed UTC dates. A
    season has a free track and a premium track, and track items are
    track-only forever. FounderPass and VictoryEmotePass are retired.
    Their cosmetics are on Season 1's premium track.
  - `Config/Seasons/` holds one file per season: the window, `passKey`,
    `free` and `premium`. `Store/Season1Pass.luau` is its pass and
    grants nothing itself. Validate checks dates, overlap, the pass
    pairing, Q8 for power-ups, and track-only cosmetics.
  - `SeasonLogic.luau` is the pure part (`tests/SeasonLogic.spec.luau`).
    Schema v5 adds `seasonProgress`: `passSeenAt`, win counts and paid
    counts per season.
  - A win is counted inside the progression writer's mutation
    (`DataService.SeasonStep`). On join and on a pass purchase,
    `StoreService.syncPasses` records the pass sighting and pays any due
    items. A pass can't be bought outside its season.
  - Season 1 ships disabled, because its cosmetics have no assets. Not
    yet Studio-verified: to test, enable it with placeholder cosmetics
    enabled, or move its items to coins and power-ups.

## Next
- [ ] **5b. Track UI.** The store lists the season pass, but nothing
  shows a track or a player's progress on it. StoreState needs the
  player's own season progress (private, so Q7 holds).
- [ ] **6. Store audit.**
  - Currency buys specific named items at fixed prices.
  - Check that nothing bought is random, for Robux or for currency.
  - Verify Roblox's current random-item policy before launch.
- [ ] **7. Tune in playtest.** Every amount and odd is PLACEHOLDER.
  Q8's "Robux buys time, never power" rests on these numbers.
