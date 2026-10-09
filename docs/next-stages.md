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
- [ ] **1a. Monthly season pass** (design-decisions.md, 2026-10-09), one
  part per session:
  - [x] Rules: calendar-month seasons, both tracks count every season
    win (buying mid-month unlocks paid tiers already reached), one
    reusable `season-pass` developer product. *Done 2026-10-09.*
  - [ ] Owner: create the "Season Pass" developer product in Creator
    Hub, paste its id into `Store/SeasonPass.luau`, and take the old
    Season 1 game pass (2006972979) off sale.
  - [ ] Pass screen: tiers left to right, paid row on top (locked until
    bought), free row below, as in the owner's reference image.
  - [x] Wearable cosmetic type (hats, back items) with its renderer.
    *Done 2026-10-09: categories `Hat` and `BackItem` (two slots),
    mesh + texture + scale/offset/rotation in the cosmetic file,
    rendered by CosmeticService as an Accessory that hides the avatar's
    own at the same spot. Not yet seen in Studio: needs a first item.*
  - [ ] Items and pass images for the first month's tiers. Models made
    with AI mesh tools (Studio, Meshy via `MESHY_API_KEY`), to be redone in
    Blender later. *2026-10-09: lineup set (Season1.luau, 11 columns
    to 30 wins), five wearables written (disabled, asset ids 0), tiles
    show an item's `previewIconAssetId`. Pictures done for the founder
    trail, skin and emote (`assets/seasonpass/make-art.js`). Left: the
    five Meshy models (Loot Sack, Burglar Beanie, Traffic Cone, Game
    Show Top Hat, Gold Bar Jetpack), their pictures, fitting them in
    Studio, then enabling them.*
- [ ] **1b. iPhone playtest fixes** (owner's screenshots, 2026-10-09),
  one per session:
  - [x] Hub UI under Roblox's top bar: on iPhone the queue card's
    status line ("Finding players...", "Round over? Press Play...")
    sits behind the Roblox menu/chat/mic buttons. Keep HUD and menus
    inside the safe area (ScreenGui `ScreenInsets`, `GuiService`
    top-bar inset) on every screen, not just the Hub; check the race
    HUD's top row and the bottom power-up slots against the notch and
    the jump button too. *Done 2026-10-09, not yet seen on a phone:
    every screen already used CoreUISafeInsets; the queue card was
    the leak. On touch it sat above the thumbstick zone and grew up
    into the bar when taller than that room; it now drops to the
    bottom edge right of the thumbstick instead. Race HUD top row
    only lifts into the bar when it fits between Roblox's buttons.*
  - [x] Laboratory lighting is still wrong. Find what an earlier fix
    missed (its `LightingPresets` entry vs what's in the map) and check
    it in Studio Play, not just Edit. Lead: a Hub-place playtest on
    2026-10-09 warned that Lighting holds an Atmosphere (overrides every
    preset's fog) and Studio-authored Bloom/ColorCorrection/DepthOfField/
    SunRays that stack with presets. Check the Match place for the same.
    *Done 2026-10-09, checked in Studio Play, not yet on a phone.
    Match_Area's Lighting is clean (Sky only); the Atmosphere/effects
    are in the Hub place, where no map plays. The real cause: the Lab
    preset has shadows off, so the sun lights through the roof, and
    its clock was 00:00, i.e. moonlight. The earlier fix raised
    ambient, which barely shows. Now 14:00, exposure 0.2. Also found:
    `LightingStyle`/`PrioritizeLightingQuality` can't be written at
    runtime, so every preset's style is ignored (place = Soft).*
  - [ ] Task views too small on a phone: the cards feel small and
    fiddly. Size them from the screen (bigger share of the height in
    landscape), and grow touch targets to a thumb's size.
  - [ ] Text cut off in task art: Pressure Valve's pump button shows
    "PU" for "PUMP". Check every TaskArt button label at phone size.
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
- [x] **4a. Art pass and rendering fixes on the four launch maps**, one
  map per session, Factory first (flashing seen in playtest, likely
  z-fighting). Survey each map in Studio, fix rendering faults, then swap
  primitive dressing for Creator Store assets. Each asset must fit
  `perf-budget.md`; School is already over on draw calls (step 16), so
  its pass removes parts as well as adding them. Added 2026-10-04.
  *Rendering half done 2026-10-04 in Match.rbxl, all six maps in
  `ServerStorage.Maps`. The flashing was z-fighting: block parts sharing
  a face plane with a different colour or material (Factory: line guards
  against press pillars, tunnel walls against floors, the south wall
  against the staff-room roof). On each pair, the smaller part's face
  was pushed out 0.03 studs, repeated until a re-scan found none. Parts
  under Stations, Spawns, Nav and Bounds were left alone. Faces moved:
  SpaceStation 1,189, School 568, Museum 128, Factory 76, Laboratory 43,
  DecisionStudio 1. Rotated and non-block parts weren't scanned.
  Asset half: Factory's candidate pack is "Realistic Factory Props
  Industrial Set" (Creator Store 89805968354629, free, no scripts, 399
  PBR meshes, about 31 textures). It has forklifts, conveyors, pallets,
  roll cages, a wrapping machine and hand trucks. It is parked in
  `ServerStorage.AssetQuarantine` with a 15-mesh storage bundle
  (76442414596854). Use a subset, because the texture budget is under
  100. Factory dressed 2026-10-04: 53 pack props, scaled 1.3×, in
  `Dressing/Props_{Yard,North,South,West,East}`. They include two
  forklifts, wrapped and boxed pallets, pallet stacks, a floor conveyor
  with crates on it, a wrapping machine, tool drawers, hand trucks and
  pallet jacks. The yard's primitive forklift, crate stacks and pallets
  were replaced; the barrels stay. Props sit against the outer walls
  under the catwalks. Each one was checked against the nav edges (4.5 studs
  or more), station, pickup and spawn boxes, and other parts (no
  clipping). Mesh collisions are set to Box. All 58 nav nodes still path
  from the spawn. Factory now uses 67 unique textures and 23 meshes
  (budget under 100 and 150). Museum dressed 2026-10-04. The Creator
  Store had no usable museum pack (SEO spam and scripted NPCs), so 13
  props were made with Studio's mesh generator: sarcophagus, Anubis,
  pharaoh mask, bust, amphora, astronaut, lunar lander, Sputnik,
  ammonite, knight, sculpture, palm and bench. Each is one mesh with one
  texture, and the templates are in `ServerStorage.AssetQuarantine.MuseumGen`.
  The Rotunda's primitive dino became a mounted T-Rex skeleton (Creator
  Store 11786401282, no scripts, 23 meshes). Only its planted leg and
  chest post collide, it stands in the NE quadrant clear of R1's seven
  edges, and nothing hangs lower than 12.6 studs over a walkway. In Egypt,
  Anubis replaced the four block statues, and the sarcophagus now sits in
  its case. In total 72 props went into `Dressing/Props_*` and
  `Dressing/Egypt`, against walls on both floors. Each was checked like
  Factory's, and all 63 nav nodes still path from the spawn. Museum uses
  13 textures and 35 meshes. Laboratory dressed 2026-10-06 (begun
  2026-10-04). 65 props went into `Dressing/Props_{Reactor,Labs,Upper}`.
  The ground floor and labs got Creator Store crates, AC units,
  condensers and kits, plus generated fume hoods, benches, chemical
  cabinets and gas racks. The upper floor got generated desks in Comms
  and Security, a cabinet in Comms, and a couch and planters in
  Director's office, plus seating, bins and crates. Templates are in
  `ServerStorage.AssetQuarantine.LabGen`. Studio crashed four times
  during placement on 2026-10-04. The likely cause was cloning and
  scaling freshly generated meshes while Roblox was still processing
  them. The same meshes placed without trouble two days later. Each prop
  was checked like Factory's, and all 83 nav nodes still path from the
  spawn. The Lab uses 74 textures and 41 meshes. School done
  2026-10-06. This pass cut weight and dressed nothing new. The six
  bookshelves (about 300 parts each, one part per book) became one
  generated bookcase mesh each, turned to face into the rooms.
  The 17 desks and 17 chairs (about 2.4k and 2k triangles each) became
  one low-poly desk-and-chair mesh per seat. Each seat keeps its
  `CollisionHull`, and the papers on desks were raised 0.33 studs to
  the new desk tops. Hidden micro-detail was removed: pens, notebook
  rings, separate paper sheets, book page layers and the open
  textbook's pages. The 51 decorative SurfaceGuis got a `MaxDistance`
  (40 studs for small text, 120 for signs). Templates are in
  `AssetQuarantine.SchoolGen`. Result: 5,461 → 3,060 parts, and the
  worst draw calls 153 → 97 and triangles 147k → 80k over a 200-view
  sweep (`perf-report.md` History). All 74 nav nodes still path.*
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
- [x] **9. Check on a published place** that events reach Creator Hub
  analytics (allow up to 24 hours). Studio can't send analytics at all;
  there, set `telemetry.studioEcho = true` to see what would be sent.
  Needs step 12's published places.
  *2026-10-04: studioEcho pass on a solo Match round. Round-level
  events print with the right fields (`Map` is `none` only in Studio,
  where the arrival gate never calls `roundStarted`). Found and fixed:
  nothing flushed the queue on a timer, so `RoundEnded`/`StreakLoss`
  waited for a player to leave.*
  *Done 2026-10-08. Creator Hub (Analytics → Funnels, and Explore with
  source "Custom events") shows both funnels (`Round` 17 users through
  all 6 steps, `Matchmaking` 5 → 4) and all 13 custom event names
  (`TaskCompleted`, `MapVoted`, `MapPlayed`, `PowerUpUsed`,
  `PowerUpCollected`, `TaskAbandoned`, `StealShareChoice`,
  `FinaleOutcome`, `StreakLoss`, `StreakWin`, `NPCCountInRound`,
  `RoundEnded`, `ReturnedToHub`). `TaskCompleted` by custom field 2
  splits into the four real maps, with no `none`. Purchases not checked
  (no live purchase made).*

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
- [x] **14a. Sound.** All 21 cues in `AudioLogic.luau` still point at
  `PLACEHOLDER_ASSET`, so the game is silent. Pick or make a sound for
  every cue and the three music beds (`audio-and-feel.md` is the brief),
  upload them, and set the ids. Added 2026-10-04. Done 2026-10-08:
  all 21 cues set from licensed libraries (`audio-and-feel.md` §8,
  with alternates); the owner still has to audition them.
- [x] **14b. Map preview images.** Every map's `thumbnailAssetId` is
  `rbxassetid://0`, so the Hub vote board shows blank cards. Capture
  one image per launch map (after its 4a art pass), upload them, and set
  the ids. Added 2026-10-04. *Done 2026-10-06. There is one 512×512
  interior shot per launch map, taken under its own lighting preset:
  School's classroom, Factory's line with the Emergency Stop, Museum's
  T-Rex in the Rotunda, and the Lab's glowing reactor core. Each
  subject sits at the centre, because the vote card crops the image to
  a square. The shots were uploaded through Studio MCP's
  `upload_image`, and all four load. Wave 2 and 3 maps keep
  `rbxassetid://0` until they're built.*
- [x] **14c. Experience thumbnails and icon.** The game icon and the
  thumbnail set for the experience page, made from the art-passed maps.
  Added 2026-10-04. *Done 2026-10-06. The files are in
  `assets/experience/`: a 512×512 icon (two finalists over STEAL /
  SHARE) and five 1920×1080 thumbnails. They show the Decision Studio
  hero, the School race, Factory sabotage with the real STUNNED and
  BLINDED labels, the Museum "top 3 make the final" shot and the Lab win
  streak. All are Studio captures of the launch maps under their own
  presets, with gameplay-only captions in the game's font. The README
  there has the Creator Hub upload path and how the set meets Roblox's
  thumbnail rules. Uploading them is the owner's job.*
- [x] **14d. Store item images and categories.** Store items have no
  image field and no category; the Store screen lists them by
  `sortOrder` only. Add an image and a category to `StoreItemDef`
  (validated, data-driven), give every item an image, and show the
  categories as tabs or sections in the Store screen. Added 2026-10-04.
  *Done 2026-10-06. `StoreItemDef.imageAssetId` is validated: enabled
  items need one, and 0 is legal only while disabled. All 15 items have
  a 512×512 picture from `scripts/make-store-icons.ps1`: the 5 Robux
  products' existing icons, plus 10 new coin-offer badges, one per
  power-up, each with a gold coin. They are uploaded and show on the
  store card and in the preview panel. The categories already existed
  as tabs (Season / Bundles / Power / Style / Coins). They are derived
  from each item's grants in `StoreScreenLogic.categoryOf`, so no
  config field was added: a field could disagree with what the item
  contains.*

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
  events, and lists the steps that must be ticked before launch (1, 4a, 9,
  13, 14a–14d, 15, 16, 18) and the checks the events can't answer (§0.4). The
  biggest gap, the finale's steal rate in all-human Studios, is fixed:
  `StealShareChoice` now carries the Studio's bot finalists. Steal vs
  Share on realised payoff stays unmeasured (no field left). The launch
  and the reviews themselves are the owner's.*
- [ ] **20. Live-ops builds B1–B5** (`liveops-roadmap.md` §4). B1 and B3
  partly overlap rewards step 5's seasons; reconcile before building.

## Stage 7: After launch, more content

Added 2026-10-04. Nothing here starts before the soft launch (no new
maps until then). The dates come from `liveops-roadmap.md` §4's week
plan, which also says how each map ships. One map or one task per
session.

- [ ] **21. The seven unbuilt catalogue tasks** (`tasks-catalogue.md`):
  Crate Winch, Cable Splice, Lock Tumbler, Morse Relay, Conveyor Sort,
  Turret Calibration, Sensor Sweep. Build them in the order the maps
  below need them. Each is a config file plus a handler and a view, like
  step 5. Every one must pass the one-thumb rule and the step 15 audit.
- [ ] **22. Wave 2a maps: Bunker, Prison** (live-ops W3, Season 1 opens).
- [ ] **23. Wave 2b maps: Mall, Construction Site** (live-ops W8).
- [ ] **24. Space Station** (live-ops W10, the wave 3 flagship, shipped on
  its own). It is the most finished unreleased map. It's built (16
  stations), dressed with Roblox's Beyond the Dark packs (2026-09-30,
  seven `Dressing_*` folders), and already in Match.rbxl's
  `ServerStorage.Maps`. Its config and lighting preset are in the repo
  with `enabled = false`. Left: it still uses the four original tasks.
  `airlock-cycle` and `reactor-sync` have Space Station stations in the
  catalogue (hull airlock, reactor core sync), so consider swapping them
  in. It also needs a check against wave 1's standard (validator, perf,
  texture budget) and a music id. It could ship earlier than W10 if
  the launch needs a fifth map.
- [ ] **25. Wave 3 rest: Aircraft Carrier, Deserted Island.**

For each map, use the step 4 process: build or finish it in Studio,
check it against `map-kit-spec.md` and the map validator, check perf
against `perf-budget.md`, add it with `scripts/assemble-match-place.luau`,
then enable its config.

## Decisions needed from the owner

Ask before the steps that depend on them; record answers in
`design-decisions.md`.

- **Season mismatch.** Pass seasons are now calendar months (2026-10-09);
  whether the live-ops leaderboard season follows them is still open. Live-ops plans 6-week seasons ranked by a season
  score; rewards step 5 built fixed-date pass seasons. Same thing, or two?
- **Season score.** Peak live streak (recommended) or a season-only counter?
- ~~**Launch tasks.** The four built plus the four in step 5?~~ Yes, all
  eight (2026-10-03, `design-decisions.md` §10).
- **Weekly payout hold.** Is a 72-hour manual check before weekly and
  season payouts acceptable as a standing job?

Suggested order: Stages 1–3 in sequence, with Stage 2's map building
in Studio alongside. If no group playtest is possible yet, start with
step 2, 3 or the analytics steps (6–9); none depend on anything else.
