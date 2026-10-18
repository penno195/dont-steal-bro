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

- [x] **1. XP, account level and coins for every placement.**
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
  - [x] 1c. UI: XP bar + level on the results screen and Hub menu,
    level-up pop-up. The server sends both ends of the bar (RoundRecap's
    `level`, StoreState's `level`) so a LiveConfig curve retune can't
    disagree with the client. Results gets a Level beat before the
    streak; the Hub gets a LevelBadge left of the coin pill; a level-up
    opens the claim pop-up (level-up coins + level cosmetics) when the
    player taps Continue on the results.
- [x] **2. Finale guesses for knocked-out players.** Each non-finalist
  gets one **Guess Token** per round and picks who walks out. A correct
  guess earns a **streak credit**, but only when the result is a single
  stealer or a single sharer. Every other guess (and an all-share or
  all-steal result) wins nothing. The owner's answers (Q7's applied
  case): the credit is a **streak shield**, spent on the holder's next
  loss instead of a reset. It's the whole prize and never adds to the
  streak. No NPC-lobby limit.
  - [x] 2a. Pure logic + specs. `src/server/GuessLogic.luau`: who walks
    out (exactly one winner, tagged a lone stealer or lone sharer, so
    all-share, all-steal and the solo default give nil), whether a guess
    is valid (not a finalist, target is a finalist, NPC seats included,
    one guess per round that can't be changed), and who earns a shield.
    `ProgressionLogic.spendsShield` (any loss with streak >= 1 and a
    shield held spends exactly one), and `applyResult`/`buyBackOffer`
    take that answer: a covered loss keeps the streak and leaves no
    buy-back offer.
  - [x] 2b. Server: profile field `streakShields` (schema v17), a guess
    intent remote (`FinaleGuessIntent`, validated by `GuessLogic.validate`,
    open from `DecisionParticipants` until the outcome is committed, which
    is before the reveal), shields granted then by the new
    `GuessService` (before Results, so a shield saves the guesser's own
    not-qualifying loss this round), and spent in `applyRoundResult`'s
    single write with an audit line. `FinaleGuessAccepted` acks the
    guesser; `RoundRecap` gains `shieldSpent`, `guess` and
    `streakShields`. Practice matches judge guesses but grant nothing.
  - [x] 2c. UI: the Guess Token picker for knocked-out players, the
    result ("You called it: +1 shield"), and the held shield count on
    the player's own Hub/results screens only (Q7 condition 1). The
    picker (`Screens/GuessPicker`, pure half `UI/GuessViewLogic`) sits
    in a spectator's bottom-left corner in the Studio, for anyone in
    this round's standings who isn't a finalist, until the reveal: one
    card per seat, NPCs included. A tap fires `FinaleGuessIntent` once;
    `FinaleGuessAccepted` locks it, and no ack within 4s reads as a
    refusal (no resend: the server takes the first guess only). Results
    gains a Guess beat before Level (`ResultsLogic.guessHeadline`; a
    practice match never promises a shield), a "Shielded" streak kind
    ("Your 4-win streak is safe") when `shieldSpent`, and the shields
    held under the streak card. The Hub shows a shield pill between the
    level badge and coins once one is held (StoreState's new
    `streakShields`). Unseen in Studio when built: check it on device.
- [x] **3. Quick-chat rewording and restyle.** Quick-chat buttons already
  exist. Reword them for the negotiation (promises, threats, emotes)
  and restyle them to the HUD art pass. Done (owner's answers in Q1's
  applied case): the four-word row is replaced by a Quick button left
  of the Studio's chat box that opens a stage-panel pop-up of three
  columns, Promise / Threat / Emote, four short phrases each
  (`DecisionLogic.QUICK_CHAT`, PLACEHOLDER wording). "Emotes" are
  phrases, not animations or emoji. A tap sends the line as ordinary
  chat and closes the pop-up. Unseen in Studio when built: check the
  pop-up's fit on a phone.
- [x] **4. Cash out the streak.** In the Hub, from streak 3, a player can
  bank their streak: coins that grow steeply with the streak, a
  permanent "best banked" record shown in the Hub, and the streak resets
  to 0. `bestStreak`, titles and the leaderboard are untouched.
  Server-validated through the same single streak writer
  (`applyRoundResult`'s claimant), with its own reason code. Owner's
  answers (Q7's applied case): a restored streak pays only for wins
  since the restore; 25 × s² coins; a new Hub launcher button + card.
  - [x] 4a. Pure logic + config + specs: `GameConfig.streakCashOut`
    (minStreak, coinsPerWinSquared), `src/server/CashOutLogic.luau`
    (the offer: streak, wins paid for, coins, whether and why not), the
    `CashOut` reason code, and StoreLogic's restores recording
    `streakRestoredAt`.
  - [x] 4b. Server: profile fields `bestBanked` and `streakRestoredAt`
    (schema v18), `StreakCashOutIntent`/`StreakCashOutResult`,
    `ProgressionService.cashOut` through the one progression writer
    (Hub only, audit line), StoreState's `cashOut` offer (Hub only).
  - [x] 4c. UI: the Hub launcher's bank button and its card, with a
    confirm step. A "Bank streak" launcher button (Hub only, once
    StoreState carries the card) opens `CashOutController`'s card (the
    streak, what banking pays or why not yet, the best banked), then a
    "Bank your 5-win streak?" confirm; StreakCashOutResult toasts the
    outcome. Copy in `UI/CashOutViewLogic`. Unseen in Studio when built:
    check it on device.

## Also approved (after the four above)

- [x] **5. Free season pass for playtime.** 6 **active** hours in one
  week (Mon–Sun UTC) unlocks the live season's premium track for the
  rest of that season, once per season. Time in a match always counts.
  Hub time counts only with player input in the last 2 minutes. Grants
  through `SeasonLogic.buyPass`'s path with its own source tag. Owner's
  answers (Q1's applied case): the count restarts at a season change,
  even mid-week; practice-match time counts like the Hub (input-gated).
  - [x] 5a. Config + pure logic + specs: `GameConfig.playtimePass`
    (activeHoursPerWeek, idleWindowSeconds, maxCreditSeconds),
    `src/server/PlaytimeLogic.luau` (what counts as active per context
    Match/Practice/Hub, the lazy week + season reset, the per-credit
    cap, when the pass falls due, the pass screen's progress), and
    `SeasonLogic.buyPass`'s optional `source` ("Playtime" stored as
    `passSource`; nil = bought, so no migration).
  - [x] 5b. Server: a profile field for `PlaytimeLogic.State` (schema
    bump), a ticking credit per player (context from the place and
    whether the match is practice; Hub/practice input stamped by the
    server from a rate-limited activity intent), the grant through
    `SeasonLogic.buyPass(..., "Playtime")` with an audit line, and the
    week's progress in StoreState for the pass screen. Built as
    `PlaytimeService` (30s tick; StoreState re-sent every 5 min while
    counting), profile v19 `playtime`, `PlaytimeActivityIntent` (sent
    by `PlaytimeActivityController` at most every 30s with input), and
    `StoreService.grantPlaytimePass`. StoreState's `season` gains
    `passSource` and `playtime = { activeSeconds, targetSeconds,
    weekResetsIn }` (nil once the pass is held).
  - [x] 5c. UI: the pass screen's "x / 6 active hours this week" bar
    (with when the week resets) while the pass isn't held, and an
    "Earned by playtime" pass pop-up when it unlocks. Built as a
    `C.ProgressBar` row under the Season tab's track
    (`SeasonTrackLogic.playtimeView`; hours floor to a tenth so it never
    reads 6/6 before the grant) and a ClaimPopup card when `passSource`
    flips to "Playtime" between two StoreStates of one season
    (`earnedByPlaytime`; never on a join), held until no round, Studio
    or loading screen is up. The Studio preview's two pass-less scenes
    show the bar at 2.5 / 6.
- [x] **6. Own-streak indicator in the Studio.** A finalist sees only
  their own streak ("Your streak: 6, at stake"), sent targeted, never
  replicated to others. Built as a `streak` field on the targeted
  `DecisionStakes` (so practice, which sends no stakes, shows none) and
  a flame pill under the Studio header from the intro until the reveal
  (`PayoutLogic.ownStreakLine`). Owner's answers (Q7's applied case):
  "at stake" even with a shield held; at 0 it reads "No streak yet: win
  to start one". Unseen in Studio when built.
- [ ] **7. Betrayal card + trust stat.** After a reveal, a betrayed
  sharer gets a "Robbed by X" card. Lifetime "times betrayed" and a
  share/steal trust record, built on the existing Studio history (Q5).
  Owner's answers: Q5's "betrayal card and trust stat" applied case.
  - [x] 7a. Config + pure logic + specs: `src/server/BetrayalLogic.luau`
    (who was robbed by whom, from the resolved winners and the
    choices; "betrayed" = a sharer who lost to a lone stealer), the NPC
    made-up count (`GameConfig.npc.betrayedPerShare`, rolled per share
    of the bot's fixed history), validated and spec'd. Built as
    `BetrayalLogic.robberies` / `robbedBy` and
    `NPCBrainLogic.staticBetrayed` (roll it after `staticHistory` from
    the same stream, so no bot's history changes); PLACEHOLDER 0.4.
  - [ ] 7b. Server: profile stat `betrayed` (schema bump), recorded
    with steals/shares (never in practice); a targeted "Robbed by"
    payload to each betrayed sharer still present (practice included);
    `betrayed` added to `DecisionParticipants`' reputation entries (the
    NPC count from 7a); the player's own record in a targeted Hub
    payload.
  - [ ] 7c. UI: the "Robbed by X" card after the reveal, "robbed N×" in
    the Studio reputation line, and the Hub's "Your record" panel.
- [ ] **8. Daily challenges.** Three a day (e.g. "Freeze 5 players",
  "Reach the Studio twice", "Share and survive"), most doable without
  winning. One config file per challenge.
- [ ] **9. Lifetime-stat titles.** Titles for lifetime wins, Studio
  visits and successful steals, which everyone climbs over time,
  alongside the streak ladder (rungs past ~10 are near-unreachable at a
  ~20–25% round win rate).
