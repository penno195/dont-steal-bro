# Payoff-loop roadmap: a payoff for every round

The build order for the 2026-10-17 game review. It found that a round
win comes about 1 time in 4–5, and only wins paid anything. So most
rounds paid nothing, and most players never got past a streak of 1–2.
The streak stays the prestige goal. These steps give everyone else
something to earn every round.

**One step per session, then `/clear`.** Large steps are split at their
seams (a, b, c). Tick a step off here in the same commit that finishes
it. The owner's answers are recorded in `docs/design-decisions.md`:
Q1's "Applied case: a payoff for every round" and Q7's "Applied case:
streak cash-out, own-streak indicator, finale guesses". Read them before
starting a step. If a step hits a question they don't answer, stop and
ask (CLAUDE.md).

All amounts are PLACEHOLDER until a playtest tunes them.

## Priority order (the owner's)

- [ ] **1. XP, account level and coins for every placement.**
  - [x] 1a. Config + pure logic + specs: `GameConfig.roundRewards`
    (XP per task done, per placement, per Studio visit, per power-up
    hit; the level curve; coins per level; coins per placement), and
    `src/shared/LevelLogic.luau` (xp → level, level-up payouts,
    milestones crossed). The profile stores only lifetime `xp`, and the
    level is always worked out from it. No Roblox APIs, so it's
    unit-tested in Lune.
  - [x] 1b. Profile field `xp` (schema v16; the level is derived, per
    1a); awarded in `applyRoundResult`'s single progression write
    (DataService's `LevelStep`): XP, place + level-up coins, and every
    enabled level cosmetic now due. Inputs are server-side only:
    TaskService's tasks and qualification rank, PowerUpService's landed
    hits on a rival (`getHitsFor`). Level cosmetics are a
    `CosmeticDef.unlockLevel` (level-only, validated). Three disabled
    PLACEHOLDERS await assets and the owner's say on levels/looks:
    ClimberTrail (5), VeteranNameplate (10), OldHandStreakFlair (25).
  - [ ] 1c. UI: XP bar + level on the results screen and Hub menu,
    level-up pop-up.
- [ ] **2. Finale guesses for knocked-out players.** Each non-finalist
  gets one **Guess Token** per round and picks who walks out. A correct
  guess earns a **streak credit**, but only when the result is a single
  stealer or a single sharer. Every other guess (and an all-share or
  all-steal result) wins nothing. Open sub-questions to ask before
  building: see Q7's applied case.
- [ ] **3. Quick-chat rewording and restyle.** Quick-chat buttons already
  exist. Reword them for the negotiation (promises, threats, emotes)
  and restyle them to the HUD art pass.
- [ ] **4. Cash out the streak.** In the Hub, from streak 3, a player can
  bank their streak: coins that grow steeply with the streak, a
  permanent "best banked" record shown in the Hub, and the streak resets
  to 0. `bestStreak`, titles and the leaderboard are untouched.
  Server-validated through the same single streak writer
  (`applyRoundResult`'s claimant), with its own reason code.

## Also approved (after the four above)

- [ ] **5. Free season pass for playtime.** 6 **active** hours in one
  week (Mon–Sun UTC) unlocks the live season's premium track for the
  rest of that season, once per season. Time in a match always counts.
  Hub time counts only with player input in the last 2 minutes. Grants
  through `SeasonLogic.buyPass`'s path with its own source tag.
- [ ] **6. Own-streak indicator in the Studio.** A finalist sees only
  their own streak ("Your streak: 6, at stake"), sent targeted, never
  replicated to others.
- [ ] **7. Betrayal card + trust stat.** After a reveal, a betrayed
  sharer gets a "Robbed by X" card. Lifetime "times betrayed" and a
  share/steal trust record, built on the existing Studio history (Q5).
- [ ] **8. Daily challenges.** Three a day (e.g. "Freeze 5 players",
  "Reach the Studio twice", "Share and survive"), most doable without
  winning. One config file per challenge.
- [ ] **9. Lifetime-stat titles.** Titles for lifetime wins, Studio
  visits and successful steals, which everyone climbs over time,
  alongside the streak ladder (rungs past ~10 are near-unreachable at a
  ~20–25% round win rate).
