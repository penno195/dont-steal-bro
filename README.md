# Don't Steal Bro!

A competitive Roblox mini-task race with power-up griefing and a social-deduction
finale. Six players race to finish their tasks while sabotaging each other. The
first three to finish are teleported to the **Decision Studio**, where they can
talk, negotiate and lie — then blindly pick **Steal** or **Share**.

Your win streak is the whole metagame. It only goes up. One loss takes it all.

## Status

**All 57 tracker tasks are done (Phases 00–09), and the game is in
Studio playtesting.** `lune run tests/run` passes 1,206 cases across 46
spec files. What's still open is listed under [What's left](#whats-left)
below; the phase-by-phase history follows.

Pre-production (Phase 00) resolved all eight open design questions
(`docs/design-decisions.md`) and wrote the task and power-up catalogues,
map kit contract, payoff table, perf budget and threat model.

Foundation and tooling (Phase 01) landed a working Rojo project with CI;
a two-phase Service/Controller bootstrap loader (`src/shared/Loader.luau`);
a typed remote layer with payload validation, rate limiting and violation
escalation (`src/shared/Net.luau`, `src/server/Services/NetGuard.luau`) —
the game's entire client-facing attack surface; a data-driven config layer
with boot-time validation (`src/shared/Config/`,
`src/server/Services/ConfigValidator.luau`); a player data service over
ProfileStore with a versioned migration chain (`src/server/ProfileLogic.luau`,
`src/server/Services/DataService.luau`); and documented testing conventions.

The gray-box core loop (Phase 02) is playable end to end on the server
side. `RoundService` is the single source of truth for round phase,
replicated as one small payload with per-state Signals other services
subscribe to instead of polling. On top of it: task assignment, progress
and qualification (`TaskService`, `src/shared/Qualification.luau`); the
three-file task framework with three working tasks — Code Playback,
Fuse Rewire and Pressure Valve — where adding a task is adding a config,
a handler and a view and nothing else (`docs/how-to-add-a-task.md`);
power-up pickups, inventory and server-validated use (`PowerUpService`);
a status effect system with stacking and mercy rules (`StatusEffects`);
and movement sanity checks that are deliberately log-only for now
(`MovementWatch`, `docs/movement-watch-notes.md`).

Phase 03 (the Decision Studio and NPCs) delivered: the outcome
resolution table and its spec (P3-1), the
Decision Studio phase machine and its secrecy guarantees — no client ever
learns another finalist's choice before Reveal (P3-2, `DecisionService`);
proximity text and voice chat for the negotiation (P3-3, `StudioChat`,
`docs/studio-chat-notes.md`); a gray-box Studio set builder (P3-4,
`scripts/build-studio.luau`); and NPC fill (P3-5, `NPCService`,
`src/server/NPCLogic.luau`, `docs/npc-notes.md`) — bots that don't play
the minigames but simulate their timing, floored so one can never beat
the median human time for a task.

P3-5 also introduced the **participant roster**
(`src/server/Participants.luau`, `ParticipantService`). Race-side
services used to key their state on a `Player` instance, which made
architecture.md §4's "an NPC reports completion through the same
TaskService API a human uses, so qualification logic has no NPC branch
anywhere" impossible to honour. `TaskService`, `StatusEffects` and
`PowerUpService`'s targeting are now keyed on a participant id instead —
a real `UserId` for a human, a negative one for a bot — so an NPC is
just another racer to all of them. The only surviving distinction is
"is there a client to fire a remote at."

P3-6 gave those bots a brain (`NPCBrain`,
`src/server/NPCBrainLogic.luau`): a utility AI that scores whether to
spend a held power-up on the current situation, and a hidden Decision
Studio personality (Greedy / Loyal / Chaotic, one config file each in
`src/shared/Config/NPCPersonalities/`) that bluffs through the
negotiation and locks in at a random point in the Choose window. What a
bot says and what it does are independent by construction. Every bot
action routes through the same validated server path a human's input
reaches — `PowerUpService.useFor` and `DecisionService.lockIn` are the
only functions that can spend an item or record a choice, and neither
has a bypass to take.

P3-7 closed the phase by hardening the finale against disconnects and
dodging (`src/server/FinaleRoster.luau`,
`docs/finale-disconnect-tests.md`). A qualifier who leaves before the
Studio opens is replaced by the 4th-place alternate; one who leaves
inside it keeps their seat, forfeits personally, and has an already-
locked choice left untouched rather than overwritten. Once the result
is written, leaving changes nothing in either direction — it can
neither dodge a loss nor manufacture one for a player who just won. A
server shutdown mid-finale preserves every streak exactly as it was,
because a player can't cause one and the streak is the whole metagame.

Phase 04 opened with P4-1, streak and bounty resolution
(`ProgressionService`, `src/server/ProgressionLogic.luau`).
`applyRoundResult` is now the only path to a streak change in the game,
and that is enforced rather than asked for: `DataService` no longer
publishes a way to move a streak at all, and hands its single atomic
writer to one claimant, erroring loudly on a second. Every change
carries a reason code, a round id for idempotency, and an audit line
naming the before and after state. It also closed two real gaps —
nothing anywhere applied design-decisions.md Q7's "failing to qualify
is a loss too", so a 4th-place finisher kept their streak indefinitely;
and threat-model.md §8's NPC-seat streak-credit threshold now actually
gates a win.

P4-2 added the title ladder, since retuned to 21 rungs, from a first win ("Got One") to a
streak nobody should have ("Touch Grass", 50), one config file each in
`src/shared/Config/Titles/`. Permanence is structural rather than
promised: unlocking is a function of `bestStreak` alone, `bestStreak` is
never lowered, the stored list is append-only, and no module exposes a
way to revoke one.

That task also ran into the first real conflict with a locked design
decision. Q7 condition 1 forbids any in-round tell of a player's streak
and names "nameplate" specifically, and a title maps to a `bestStreak`
threshold. Resolved in `design-decisions.md` §7's new applied-case note:
**titles show in the lobby and after the result, and are suppressed for
every state in between**, enforced server-side so a modified client has
nothing to un-hide.

P4-3 built the all-time highest-streak board on OrderedDataStore
(`LeaderboardService`, `src/server/LeaderboardLogic.luau`,
`docs/leaderboard-scale.md`). Writes go out only on a genuine personal
best, through `UpdateAsync` with a max comparison so a lower value can
never overwrite a higher one. Reads happen once per server on a
jittered 60–120s interval and never on player demand — there is no
request remote for a client to call. A failed refresh serves the
previous board flagged stale rather than blanking it.

The scale write-up concludes the first limit is **not** the per-server
budget (cost per server is flat in total population) but the
universe-wide read pressure of ~3,300 servers fetching a byte-identical
first page. The mitigation is a MemoryStore cache in front of the
store — which P4-4 brings in anyway.

P4-4 added the daily and weekly boards on MemoryStore SortedMaps
(`src/server/PeriodKeys.luau`), where entries expire on their own and
no cleanup job exists because none is needed — the period key is in the
map name, so at midnight every server simply starts addressing a
different map. **A day is a UTC day and a week is an ISO-8601 week**;
the reasoning, including what that costs a player in UTC+13, is in
`docs/leaderboard-scale.md` §5. The guard against two servers awarding
the same finished period is the snapshot write itself rather than a
separate lock: the transform refuses to overwrite, and only the server
whose payload comes back fires the reward hook — no window, and no lock
that can drift out of step with the thing it guards.

**Nine platform assumptions across those two tasks are flagged as
unverified** and need checking against current Roblox documentation
before launch. A7 is the one that would change the design.

P4-5 built the store and its receipt handling (`StoreService`,
`src/server/StoreLogic.luau`, `src/shared/Config/Store/`,
`docs/store-receipts.md`). Game passes are permanent cosmetics,
developer products are consumables (currency and power-up stock), and
the two cannot be confused: `Validate.checkStoreItem` refuses a pass
that grants a consumable at boot, because a pass's grants re-apply on
every join and a consumable one would be either a one-shot purchase or
an infinite tap.

The receipt path follows ProfileStore's own `PurchaseId`-caching
pattern rather than the simpler official Roblox example. **The grant
and the PurchaseId are written in the same `Profile.Data` mutation**,
and `PurchaseGranted` is returned only once that write is observed in
`Profile.LastSavedData` — so the DataStore holds both or neither, and
there is no window where a player is charged and un-granted. Every
other path returns `NotProcessedYet`, including an unknown ProductId:
confirming a receipt this game has no config for would take the money
and hand over nothing, while declining keeps the receipt alive until
the config ships. Schema v2 adds `purchaseIdCache` and `powerUpStock`,
with a real v1 → v2 migration step rather than leaving the cache to
`Reconcile()` — a nil cache and an empty one have to mean the same
thing on a player's very first receipt.

`DataService` grew a second claimed write gate alongside P4-1's, and
for the same reason: receipt handling genuinely cannot work through
narrow accessors (it needs `IsActive`, `Save` and `LastSavedData` —
durability facts, not data), so the handle is handed out once, to
StoreService, and a second claimant errors at boot.

The task also enforced **design-decisions.md Q8 from the selling side**,
which nothing did before: `checkPowerUp` already refused a power-up
that priced itself with no free acquisition path, but a *bundle* of
such a power-up slipped through, because the power-up's own config
names no price and looks innocent. `Validate.run` now refuses that too.
The 3-item loadout cap is pinned at exactly 3 by config validation, so
raising it means amending Q8 rather than editing a number.

`docs/store-receipts.md` carries the eight-case Studio test plan (built
on a Studio-only, remote-less `debugSimulateReceipt` seam, because a
real Studio purchase gives no control over the PurchaseId), eight more
flagged platform assumptions, and a plain pay-to-win verdict: the
mechanical vector is closed structurally, but **the economy numbers —
all PLACEHOLDER — are what actually decide whether Q8's rule holds**,
and a bought loadout is not "convenience" in a game whose whole
metagame is a streak that resets on one loss.

`consumeLoadoutFor` is the only place stock is ever decremented;
`PowerUpService` calls it at race start. It shipped unwired at first,
because `powerups.md` never said how a 3-item loadout and a 1-slot
pickup inventory coexist (`docs/store-receipts.md` §5).

P4-6 built the cosmetics pipeline: one config file per item in
`src/shared/Config/Cosmetics/`, sold through a store entry rather than
priced itself, and a category-aware equip gate so an owned item can't be
equipped into the wrong slot. P4-7 added the analytics funnel and round
telemetry (`docs/telemetry-schema.md`).

Phase 05 connected the places. A cross-server queue forms groups in the
Hub (`MatchmakingService`, `docs/matchmaking.md`) and teleports them to a
reserved match server, recovering from a failed teleport
(`MatchTeleportService`, `docs/teleport.md`). The map vote with a random
tie-break (`docs/voting.md`) now runs as an 8-second overlay after each
match. The Hub itself is hand-built in its own place against a tag contract
(`docs/hub-spec.md`), and its practice area uses the same power-up code path
as a real race (`docs/practice-area.md`).

Phase 06 is the client UI, built on Vide: theme tokens, UI scale and safe
areas (`docs/ui-foundation.md`), a component library
(`docs/components.md`), the race HUD (`docs/race-hud.md`), the task view
template with mobile input adapters (`docs/task-views.md`), the Decision
Studio screen and its per-screen reveal order (`docs/decision-studio.md`),
and the store, leaderboard, results and settings screens
(`docs/menu-screens.md`). It closed with a mobile usability audit
(`docs/mobile-audit.md`), an accessibility pass including reduced motion
(`docs/accessibility.md`), and first-round onboarding
(`docs/onboarding.md`).

Phase 07 is map tooling. It includes a map validator that runs both as a
Studio plugin and headlessly (`docs/map-validator.md`), and an asset pack
sanitiser (`scripts/sanitise-pack.luau`). There is a definition file for
each of the 11 maps, plus gray-box briefs for wave 1 (`docs/maps/`). It
also adds per-map lighting and streaming presets
(`docs/lighting-and-streaming.md`) and station readability markers
(`docs/station-readability.md`).

Phase 08 hardened the game. It covers a full audit of the remote surface
with every finding closed (`docs/security-audit.md`), and a pooling and
profiling pass (`docs/perf-report.md`). It adds audio and game feel
(`docs/audio-and-feel.md`), a playtest protocol with bug triage
(`docs/playtest-protocol.md`), and live-ops feature flags
(`LiveConfig`, `docs/live-ops.md`). Phase 09 is the launch paperwork:
the store page brief (`docs/store-page.md`), the soft-launch telemetry
review loop (`docs/launch-review.md`), and the season plan
(`docs/liveops-roadmap.md`).

### Since the tracker

Playtesting has driven the work since the tracker finished:

- **Tasks:** a fourth mini-task, Vent Purge, joins Code Playback, Fuse
  Rewire and Pressure Valve.
- **Power-ups:** an overhaul colours items by role (Attack red, Defence
  blue, Utility yellow). Items have 3D pickup models, click-to-aim, and a
  drag-to-bin discard. Thrown items fly as a projectile, then explode,
  shove the victim and recoil the thrower. A victim is always told who
  hit them with what.
- **NPCs:** bots can path up ramps.
- **Finale:** the Decision Studio has staging and a loading screen.
- **Hub:** a hotel lobby with working doors and a queue card. Its
  practice area deals pickups from a deck, and its dummies fight back.
  A task station there demos Task Insight and Task Scramble.
- **Cosmetics:** nine categories, all drawn in game: Skin, Trail, Emote,
  Podium, Reveal, Projectile, StreakFlair, Nameplate and CallingCard.
  StreakFlair dresses a win-streak counter that exists on the **Hub
  server only**, because design-decisions.md Q7 allows streaks there and
  nowhere a rival you're about to race can read them (see that file's
  applied cases).

### What's left

- **Maps.** All 11 map definitions exist, but every one is still
  `enabled = false` until its geometry is built in `ServerStorage.Maps`.
  The SpaceStation is the map in active playtesting.
- **Assets and store products.** All placeholder cosmetics and store
  items are disabled until they have real Roblox asset ids and products
  in the Creator Dashboard. `GameConfig.matchmaking.hubPlaceId` and
  `GameConfig.teleport.matchPlaceId` are both `0` until the Hub and
  Match places are published, so matchmaking runs in Studio only and
  teleporting is off.
- **Win rewards.** Being built in steps, tracked in
  `docs/rewards-roadmap.md`. The config and pure logic exist
  (`RewardLogic`), but a win still grants nothing, the daily/weekly
  board reward hook has no receiver, and the finale shows stand-in
  glyphs. The design is settled in design-decisions.md Q1's 2026-09-30
  revision and its applied cases.
- **Economy numbers.** Every price and grant is still PLACEHOLDER. Those
  numbers decide whether Q8's "Robux buys time, never power" rule holds
  (`docs/store-receipts.md`).
- **Platform assumptions.** The leaderboard and receipt docs flag
  assumptions that must be checked against current Roblox documentation
  before launch.

## Documents

| File | What it is |
|---|---|
| [`docs/gdd.md`](docs/gdd.md) | The game design document. §7's open questions are resolved in `design-decisions.md`. |
| [`docs/architecture.md`](docs/architecture.md) | Locked technical decisions, folder skeleton, and the NPC / mobile-UI / Decision Studio deep dives. |
| [`docs/design-decisions.md`](docs/design-decisions.md) | The eight GDD §7 questions, resolved — bounty, qualification edge cases, streak-reset scope, Robux power-ups. |
| [`docs/tasks-catalogue.md`](docs/tasks-catalogue.md) | 15 mini-tasks, server-validated, reskinned across all 11 map themes (four are built so far). |
| [`docs/powerups.md`](docs/powerups.md) | 10 power-ups and the anti-frustration/counter-play matrix. |
| [`docs/payoff-table.md`](docs/payoff-table.md) | The Steal/Share equilibrium maths and bounty-tier numbers. |
| [`docs/map-kit-spec.md`](docs/map-kit-spec.md) | The CollectionService tag contract every map must satisfy. |
| [`docs/perf-budget.md`](docs/perf-budget.md) | Performance budget, `StreamingEnabled` config, and the device test matrix. |
| [`docs/threat-model.md`](docs/threat-model.md) | Exploit and streak-collusion threat model, ranked by leaderboard-credibility damage. |
| [`docs/testing-conventions.md`](docs/testing-conventions.md) | What belongs in a pure vs. Studio-tested module, coverage expectations, and how to fake a dependency through the loader. |
| [`docs/how-to-add-a-task.md`](docs/how-to-add-a-task.md) | The code side of a mini-task: the three-file split (config, handler, view) a task author writes against, worked through `code-playback`. |
| [`docs/powerup-threat-notes.md`](docs/powerup-threat-notes.md) | Every way a client could try to cheat the power-up service, and what blocks each one. |
| [`docs/movement-watch-notes.md`](docs/movement-watch-notes.md) | How to read the first week of movement-watch telemetry on mobile before touching a threshold — or enabling enforcement. |
| [`docs/studio-chat-notes.md`](docs/studio-chat-notes.md) | What proximity chat needs configured outside code, and what a player without voice actually experiences. |
| [`docs/npc-notes.md`](docs/npc-notes.md) | What 5 NPCs cost a server, which knob to turn first, where bots can still distort the streak leaderboard, how the brain routes every action through the validated path, and the Studio checklist. |
| [`docs/finale-disconnect-tests.md`](docs/finale-disconnect-tests.md) | The two-client Studio plan for the finale's six disconnect/forfeit cases — including exactly when to close a window to trigger each. |
| [`docs/leaderboard-scale.md`](docs/leaderboard-scale.md) | What the boards cost at 1,000 and 20,000 concurrent players, which limit is hit first, the UTC timezone policy for daily/weekly periods, and the nine platform assumptions that must be verified before launch. |
| [`docs/store-receipts.md`](docs/store-receipts.md) | The receipt guarantee and every ordering that could break it, the eight-case Studio test plan, and a plain pay-to-win verdict on selling starting power-ups in a streak game. |
| [`docs/matchmaking.md`](docs/matchmaking.md), [`docs/teleport.md`](docs/teleport.md), [`docs/voting.md`](docs/voting.md) | The Hub queue, the reserved-server teleport and its failure recovery, and the post-match map vote. |
| [`docs/hub-spec.md`](docs/hub-spec.md), [`docs/practice-area.md`](docs/practice-area.md) | The Hub's tag contract and its practice area (deck, dummies, task station). |
| [`docs/ui-foundation.md`](docs/ui-foundation.md), [`docs/components.md`](docs/components.md) | Theme tokens, UI scale, safe areas and the Vide component library. |
| [`docs/race-hud.md`](docs/race-hud.md), [`docs/task-views.md`](docs/task-views.md), [`docs/decision-studio.md`](docs/decision-studio.md), [`docs/menu-screens.md`](docs/menu-screens.md) | Each screen: the race HUD, task views, the Decision Studio and reveal, and the menus. |
| [`docs/mobile-audit.md`](docs/mobile-audit.md), [`docs/mobile-checklist.md`](docs/mobile-checklist.md), [`docs/accessibility.md`](docs/accessibility.md), [`docs/onboarding.md`](docs/onboarding.md) | The mobile usability audit and checklist, accessibility, and first-round onboarding. |
| [`docs/map-validator.md`](docs/map-validator.md), [`docs/maps/`](docs/maps/), [`docs/lighting-and-streaming.md`](docs/lighting-and-streaming.md), [`docs/station-readability.md`](docs/station-readability.md) | Map tooling: the validator, wave 1 briefs and the map-building handoff, lighting presets, and station readability. |
| [`docs/security-audit.md`](docs/security-audit.md), [`docs/perf-report.md`](docs/perf-report.md), [`docs/audio-and-feel.md`](docs/audio-and-feel.md) | The remote-surface audit, the performance pass, and audio and game feel. |
| [`docs/playtest-protocol.md`](docs/playtest-protocol.md), [`docs/live-ops.md`](docs/live-ops.md) | How to run and triage a playtest, and the live-ops feature flags. |
| [`docs/telemetry-schema.md`](docs/telemetry-schema.md), [`docs/launch-review.md`](docs/launch-review.md), [`docs/store-page.md`](docs/store-page.md), [`docs/liveops-roadmap.md`](docs/liveops-roadmap.md) | Launch: telemetry events, the soft-launch review loop, the store page brief, and the season plan. |
| [`docs/build-plan.html`](docs/build-plan.html) | The production tracker: 57 tasks in 10 phases, each with a paste-ready prompt and a model recommendation. Open it in a browser. |

Attach the first two to any AI session working on this project. The architecture
doc is what stops each session from re-inventing the folder structure.

### On the tracker's two copies

`docs/build-plan.html` is the offline copy — it ticks, but its tick state is
stored in whichever browser opened it and goes no further.

The **authoritative** tracker is the private artifact at
https://claude.ai/artifact/RSqVYTXtKzUK8v3Zi3hRPX — tick state there syncs and is
visible to anyone the artifact is shared with. Tick progress there, treat the
file in this repo as a read-only backup, and re-export it when the task list
itself changes.

## Layout

The repo root is the Rojo project (`default.project.json`):

```
src/shared/     -> ReplicatedStorage.Shared   (Config/, Net, Loader)
src/server/     -> ServerScriptService.Server (Services/, TaskHandlers/, *Logic)
src/client/     -> StarterPlayer.StarterPlayerScripts.Client (Controllers/, UI/, TaskViews/)
docs/           design and architecture
tests/          pure-logic specs, run headlessly via `lune run tests/run`
```

`ServerStorage` (all 11 maps, built by hand in Studio) has **no entry** in
`default.project.json` at all — deliberately. JSON has no comment syntax
to say so inline, which is why it's written here instead: the `.rbxl` file
is authoritative for map content, this repo is authoritative for
everything else, and Rojo should never touch `ServerStorage.Maps` in
either direction.

### Sync workflow, for anyone who's only used Studio

If you're used to editing everything in Studio and saving the `.rbxl`,
here's the mental model for this repo:

- **Code lives in Git, not the `.rbxl`.** Everything under `src/` is
  plain text on your disk, edited in VS Code (or any editor), and synced
  *into* a running Studio session by Rojo — Studio never saves this code
  into the place file. If you edit a script directly in Studio's built-in
  editor, that edit is **not persisted** anywhere Rojo looks; it'll be
  overwritten the next time Rojo syncs.
- **Maps live in the `.rbxl`, not Git.** `ServerStorage.Maps` is hand-built
  in Studio the normal way you're used to, and it stays that way — it's
  never converted to Rojo-synced files. Save the place file as you
  normally would; that's still the source of truth for map content.
- **The rule for which is authoritative:** if it's code (`src/`, configs,
  types), Git wins — the `.rbxl` is disposable and gets rebuilt by
  re-syncing. If it's map geometry, the `.rbxl` wins — Git never has an
  opinion about it. Never "fix" a code file by editing it in Studio and
  saving; always edit it on disk and let Rojo sync the change in.
- **Running it locally:** install the pinned toolchain with `rokit
  install`, then `wally install` to pull down `ProfileStore` and `Signal`,
  then `rojo serve` and connect Studio's Rojo plugin to it. From then on,
  editing a file on disk updates the running Studio session live.

### Testing

`architecture.md`'s original plan was "Jest-Lua for pure logic, run via
Lune in CI." Verified while setting this up and found not to hold:
Jest-Lua currently only runs inside the real Roblox engine (no Lune
support), and TestEZ's headless CI path (Lemur) runs on a Lua 5.1
interpreter that can't parse `--!strict` Luau syntax at all — so neither
obvious choice actually satisfies Ground Rule 4 for this project. Since
pure-logic modules are required to make zero Roblox API calls anyway, they
don't need Roblox emulation in the first place — `tests/TestRunner.luau`
is a ~95-line hand-rolled runner that executes directly under Lune's real
Luau runtime, with no third-party dependency. This was installed and run
locally (not just researched): `lune run tests/run` runs every spec file in
`tests/` (the current count is under Status). New spec files must be
added to `tests/run.luau` by hand; there is no auto-discovery. See
`docs/testing-conventions.md` for what belongs in a pure module versus a
Studio integration test, and how to fake a service dependency reached
through the loader. See `tests/TestRunner.luau`'s header comment for the
full reasoning, and revisit this if Jest-Lua ships real Lune support
later.

### Type checking

The build plan's original prompt named `luau-analyze` — but the standalone
`luau-analyze-rojo` tool (the thing that name usually refers to) hasn't
been released since 2022 and its bundled Luau parser can't read the
current Roblox global type definitions file's syntax (confirmed locally:
it fails with dozens of parse errors on `declare extern type ... with`
syntax). `luau-lsp analyze` is JohnnyMorganz's actively maintained
replacement for the exact same job, confirmed working against a real
`rojo sourcemap` and the current Roblox definitions file. Two things to
keep in sync if either ever changes: the definitions file must be fetched
from the **same tagged `luau-lsp` version** pinned in `rokit.toml`, not
its `master` branch — that mismatch (analyzer version vs. defs-file
syntax version) is exactly what broke the original tool.

## Ground rules

- **The server decides everything.** Clients send intents; the server validates.
  Assume the client is fully compromised, because it will be.
- **Data-driven.** Adding a map, task, power-up or title means adding one config
  file. If it needs a service edit, the abstraction is leaking.
- **Mobile-first.** One thumb, portrait, on a cheap Android phone. If a mini-game
  needs two thumbs plus camera control, it is cut.
- **`--!strict` everywhere**, and pure logic stays free of Roblox API calls so it
  can be tested in CI.
