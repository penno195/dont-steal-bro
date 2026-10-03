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

- [ ] **6. Switch to `LogFunnelStepEvent` / `LogCustomEvent`** and decide
  each event's three custom fields.
- [ ] **7. Hook up the 15 defined-but-unsent events** from the service
  that already knows each fact.
- [ ] **8. Add the missing events**: task abandoned, power-up collected,
  round ended, bot seat count, reward rung, config version.
- [ ] **9. Check in Studio** that events reach Creator Hub analytics.

## Stage 4: Assets, products, publishing

- [ ] **10. Cosmetic assets.** Add asset ids to placeholder cosmetics and
  enable them. Season 1 needs its premium-track items first.
- [ ] **11. Store products.** Create passes/products in the Creator
  Dashboard and put their ids in the store configs.
- [ ] **12. Publish the Hub and Match places.** Set `hubPlaceId` and
  `matchPlaceId`; test teleport and the matchmaking queue for real
  (MemoryStore is off in Studio).
- [ ] **13. Test on the published place**: leaderboard payouts to an
  offline player, receipt redelivery.
- [ ] **14. Check platform assumptions** flagged in the leaderboard and
  receipt docs against current Roblox documentation.

## Stage 5: Pre-launch hardening

- [ ] **15. Mobile audit on a cheap Android phone**
  (`mobile-checklist.md`): every task and the HUD, portrait.
- [ ] **16. Performance check** against `perf-budget.md`, all launch maps,
  6 players.
- [ ] **17. Security pass**: re-run `security-audit.md` over code added
  since the tracker (rewards, coin offers, profile messages, throws).
- [ ] **18. Full playtests with real people** per `playtest-protocol.md`.

## Stage 6: Soft launch, then live-ops

- [ ] **19. Soft launch and first review** per `launch-review.md`; watch
  whether the finale stays tense or one strategy dominates.
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
