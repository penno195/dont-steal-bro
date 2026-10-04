# Next stages: from playtest to launch

The step-by-step plan from 2026-10-02, after rewards step 7a. **One step
per session, then `/clear`.** Tick a step off here in the same commit
that finishes it. Sources: `README.md`, `rewards-roadmap.md`,
`launch-review.md`, `liveops-roadmap.md`.

## Stage 1: Finish what's half-done (playtest polish)

- [ ] **1. Rewards step 7b: tune prices in playtest.** Check the 7a
  prices, drop odds and per-rung scaling in real rounds. Last open step
  in `rewards-roadmap.md`; Q8's "Robux buys time, never power" depends
  on these numbers. *Deferred by the owner (2026-10-03): do it just
  before publishing, not now.*
- [x] **2. Studio pass on features never checked in Studio.** Season tab
  (enable a season with placeholder items), buying with coins, Slow
  Field zone, discard bin, left-click aim, and a two-player test of the
  "X used Y on you" message. *Done 2026-10-03; all pass. Fixed on the
  way: the store in landscape, NPC ids colliding with Studio test
  players, silent Task Scramble/Slow Field, and the hub's practice rug
  (Lobby.rbxl) hiding the Slow Field zone.*
- [x] **3. Fix the README.** Its "Win rewards" bullet under What's left
  says a win grants nothing, but steps 2–7a are built. *Done
  2026-10-03; the "Economy numbers" bullet now points at 7b too.*

## Stage 2: Launch content

- [x] **4. Build the four launch maps in Studio**: School, Factory,
  Museum, Laboratory, one per session. Check each against
  `map-kit-spec.md` and the map validator, then enable its config.
  *School done 2026-10-03: dressed, roofed, stations and pickups
  re-placed, enabled. Maps now ship in one Match place
  (`Desktop\Match.rbxl`), built by `scripts/assemble-match-place.luau`;
  add each new map with it. Factory done 2026-10-03: built straight
  into Match.rbxl, primitive-part dressing, enabled; as-built notes in
  wave1-briefs.md §3. Its art pass with real packs is still open.
  Museum done 2026-10-03: built the same way, primitive-part dressing,
  enabled; as-built notes in wave1-briefs.md §4. Laboratory done
  2026-10-03: built the same way, primitive-part dressing, enabled;
  as-built notes in wave1-briefs.md §5. All four still want a real-asset
  art pass.*
- [x] **5. Build the four remaining launch tasks**, one per session:
  `alarm-killswitch`, `breaker-sequence`, `reactor-sync`,
  `airlock-cycle` (adds the Hold and Timing styles). Config + handler +
  view, per `how-to-add-a-task.md`.
  *alarm-killswitch done 2026-10-03: the Hold style, with a new
  `HoldSubmit` remote (press/release edges, timed on the server).
  Enabled on all four launch maps; added to stations sch-01, fac-08,
  fac-16, mus-06, mus-09 and lab-15 in Match.rbxl.
  breaker-sequence done 2026-10-03: reuses `KeypadDigitSubmit` (switch
  number as the digit), so no new remote. Enabled on all four launch
  maps; added to its 14 Target stations in Match.rbxl.
  reactor-sync and airlock-cycle done 2026-10-03: the Timing style, a
  new `TimingSubmit` remote (the stop's attempt-clock time, clamped by
  the server) and shared sweep maths in `src/shared/TimingLogic.luau`.
  Enabled on all four launch maps; added to their 15 Target station
  slots in Match.rbxl. TaskAssignment now deals the most constrained
  task first, so with eight tasks a racer almost never repeats one.*

## Stage 3: Analytics (blocks launch)

`launch-review.md` §0. Only MatchTeleportService and PracticeService
call Telemetry, and it still uses the deprecated `FireEvent`.

- [x] **6. Switch to `LogFunnelStepEvent` / `LogCustomEvent`** and decide
  each event's three custom fields.
  *Done 2026-10-03. Mapping lives in `src/server/TelemetryLogic.luau`
  (pure, tested); `telemetry-schema.md` is the table. Two funnels
  (`Matchmaking` in the hub, `Round` keyed on roundId); the other events
  are custom events with the round's map from cached context. Telemetry
  functions now take a Player or user id; step 7 calls them with the
  new signatures.*
- [x] **7. Hook up the 15 defined-but-unsent events** from the service
  that already knows each fact.
  *Done 2026-10-03. Every Telemetry function is now called; the
  call-site table is in `telemetry-schema.md`. Not yet seen in Studio's
  `studioEcho` output.*
- [x] **8. Add the missing events**: task abandoned, power-up collected,
  round ended, bot seat count, reward rung, config version.
  *Done 2026-10-03. New events `TaskAbandoned`, `PowerUpCollected`,
  `RoundEnded` and `StreakWin` (bot seats ride on it as `Bots`);
  `StealShareChoice` gets `Rung`, the Round funnel gets `Config`. See
  `telemetry-schema.md`.*
- [ ] **9. Check on a published place** that events reach Creator Hub
  analytics (allow up to 24 hours). Studio can't send analytics at all;
  there, set `telemetry.studioEcho = true` to see what would be sent.
  Needs step 12's published places.
  *2026-10-04: studioEcho pass on a solo Match round. Round-level
  events print with the right fields (`Map` is `none` only in Studio,
  where the arrival gate never calls `roundStarted`). Found and fixed:
  nothing flushed the queue on a timer, so `RoundEnded`/`StreakLoss`
  waited for a player to leave. Still to do: the Creator Hub check on
  the published places.*

## Stage 4: Assets, products, publishing

- [x] **10. Cosmetic assets.** Add asset ids to placeholder cosmetics and
  enable them. Season 1 needs its premium-track items first.
  *Done 2026-10-03. All nine cosmetics have art and are enabled: the
  images and duck mesh come from `scripts/make-cosmetic-art.ps1`, the
  emote from `scripts/make-victory-flex.luau`. How each was uploaded is
  in `assets/cosmetics/README.md`. Season 1 stays disabled until step 11
  gives it its pass. The win-drop items are now in the drop pool.*
- [x] **11. Store products.** Create passes/products in the Creator
  Dashboard and put their ids in the store configs.
  *Done 2026-10-03. Experience published under the user account; the four
  developer products are enabled, the Season 1 Pass is created but stays
  disabled with its season. Ids, icons and descriptions are in
  `store-products.md`; icons come from `scripts/make-store-icons.ps1`.*
- [x] **12. Publish the Hub and Match places.** Set `hubPlaceId` and
  `matchPlaceId`; test teleport and the matchmaking queue for real
  (MemoryStore is off in Studio).
  *Done 2026-10-04. A full live round works: queue, vote, teleport,
  race on Factory, Decision Studio, results, back to the Hub. Getting
  there needed the experience Public with its questionnaire done, the
  Match place actually Published (not just saved), and a real map
  loader (`MapLoaderService`). Racers are now held on their pads until
  Race. `partialGroupTimeoutSeconds` was 5 for solo testing; 30 since
  2026-10-04, the owner's choice (live-tunable if a solo test needs it
  short again).*
- [ ] **13. Test on the published place**: leaderboard payouts to an
  offline player, receipt redelivery.
  *In progress 2026-10-04. Code review before testing found that a
  period nobody was online for at midnight UTC paid no one. Fixed: a
  booting server now catches up the previous period
  (`leaderboard-scale.md` §8). The test steps are in
  `live-test-plan.md`. Needs Owner's id in `liveOps.adminUserIds`, an
  alt account, and both places republished.*
- [x] **14. Check platform assumptions** flagged in the leaderboard and
  receipt docs against current Roblox documentation.
  *Done 2026-10-04:* checked and recorded in `leaderboard-scale.md` §0 and §9,
  `store-receipts.md` §7 and `matchmaking.md`. Found that `GetRangeAsync`
  costs one unit per item and each sorted map is one partition (~30k
  units/min). So the period boards (~2,500–3,000 CCU) and the matchmaking
  queue (hub servers × queue length ≲ 1,000) need a publish-once read
  path before a large launch. Also, name lookups can exceed
  `GetUserInfosByUserIdsAsync`'s ~250/min on a fresh server. S1 and S5
  stay unverified until step 13's test B.
  Follow-ups: period boards' publish-once read path built 2026-10-04
  (`leaderboard-scale.md` §9); matchmaking queue summary built 2026-10-04
  (`matchmaking.md`); name lookups capped and retried sooner 2026-10-04 (A5). All
  three follow-ups done.

## Stage 5: Pre-launch hardening

- [ ] **15. Mobile audit on a cheap Android phone**
  (`mobile-checklist.md`): every task and the HUD, landscape (phones
  are locked to it since 2026-10-04, `design-decisions.md` §11).
- [ ] **16. Performance check** against `perf-budget.md`, all launch maps,
  6 players.
  *Studio half done 2026-10-04 (`perf-report.md` History): all maps pass
  the static rows. Factory, Museum and Lab pass render too. School hits
  ~247 draw calls in round (target 180), mostly its dressing; triangles
  under 300k. The device half (S7–S9, School first) decides whether to
  cut.*
- [x] **17. Security pass**: re-run `security-audit.md` over code added
  since the tracker (rewards, coin offers, profile messages, throws).
  *Done 2026-10-04 (`security-audit.md` §7). One real leak, fixed: a
  match server sent the leaderboards (user ids + streaks) to every
  client mid-round, breaking Q7 condition 1; it now sends them from
  Results on. Knockback and aim are client-side and accepted (F11, F12).*
- [ ] **18. Full playtests with real people** per `playtest-protocol.md`.
  *Prepared 2026-10-04: matchmaking's partial-group wait is now
  30 s, so six friends queueing land in one match instead of each
  getting NPCs after 5 s. `playtest-observation-sheet.xlsx` is the
  moderator's workbook. Before the call: publish both places. Running
  step 13's tests first is safer, since an S0 found there costs nobody's
  evening. The sessions themselves are the owner's.*

## Stage 6: Soft launch, then live-ops

- [ ] **19. Soft launch and first review** per `launch-review.md`; watch
  whether the finale stays tense or one strategy dominates.
  *Prepared 2026-10-04: `launch-review.md` now points at the shipped
  events, and lists the steps that must be ticked before launch (1, 9,
  13, 15, 16, 18) and the checks the events can't answer (§0.4). The
  biggest gap, the finale's steal rate in all-human Studios, is fixed:
  `StealShareChoice` now carries the Studio's bot finalists. Steal vs
  Share on realised payoff stays unmeasured (no field left). The launch
  and the reviews themselves are the owner's.*
- [ ] **20. Live-ops builds B1–B5** (`liveops-roadmap.md` §4). B1 and B3
  partly overlap rewards step 5's seasons; reconcile before building.

## Decisions needed from the owner

Ask before the steps that depend on them; record answers in
`design-decisions.md`.

- **Season mismatch.** Live-ops plans 6-week seasons ranked by a season
  score; rewards step 5 built fixed-date pass seasons. Same thing, or two?
- **Season score.** Peak live streak (recommended) or a season-only counter?
- ~~**Launch tasks.** The four built plus the four in step 5?~~ Yes, all
  eight (2026-10-03, `design-decisions.md` §10).
- **Weekly payout hold.** Is a 72-hour manual check before weekly and
  season payouts acceptable as a standing job?

Suggested order: Stages 1–3 in sequence, with Stage 2's map building
in Studio alongside. If no group playtest is possible yet, start with
step 2, 3 or the analytics steps (6–9); none depend on anything else.
