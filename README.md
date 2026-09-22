# Don't Steal Bro!

A competitive Roblox mini-task race with power-up griefing and a social-deduction
finale. Six players race to finish their tasks while sabotaging each other. The
first three to finish are teleported to the **Decision Studio**, where they can
talk, negotiate and lie — then blindly pick **Steal** or **Share**.

Your win streak is the whole metagame. It only goes up. One loss takes it all.

## Status

**Phases 00–02 complete. Phase 03 (Decision Studio and NPCs) is 5 of 7
done — 27 of the tracker's 57 tasks.** `lune run tests/run` currently
passes 269 cases across 14 spec files.

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

Phase 03 so far: the outcome resolution table and its spec (P3-1), the
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

**Next: P3-6** (NPC griefing AI and Studio personalities), then P3-7
(alternates, disconnects and forfeits) to close the phase. Client UI is
still essentially unbuilt: `src/client/` has two controllers and the task
views, and the whole of Phase 06 (theme, components, HUD, Studio UI) is
ahead.

## Documents

| File | What it is |
|---|---|
| [`docs/gdd.md`](docs/gdd.md) | The game design document. §7's open questions are resolved in `design-decisions.md`. |
| [`docs/architecture.md`](docs/architecture.md) | Locked technical decisions, folder skeleton, and the NPC / mobile-UI / Decision Studio deep dives. |
| [`docs/design-decisions.md`](docs/design-decisions.md) | The eight GDD §7 questions, resolved — bounty, qualification edge cases, streak-reset scope, Robux power-ups. |
| [`docs/tasks-catalogue.md`](docs/tasks-catalogue.md) | 15 mini-tasks, server-validated, reskinned across all 11 map themes. |
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
| [`docs/npc-notes.md`](docs/npc-notes.md) | What 5 NPCs cost a server, which knob to turn first, where bots can still distort the streak leaderboard, and the Studio checklist. |
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

This is now the Rojo project root (`default.project.json`, task P1-1):

```
src/shared/     -> ReplicatedStorage.Shared   (config, types, Net)
src/server/     -> ServerScriptService.Server (services, task handlers)
src/client/     -> StarterPlayer.StarterPlayerScripts.Client
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
locally (not just researched): `lune run tests/run` passes 202 cases across
the twelve spec files in `tests/`, and has run green from P1-6 onward
(P1-1's original placeholder, `Example.spec.
luau`, was deleted once a real pure-logic module had its own spec file,
per its own header comment). See `docs/testing-conventions.md` (P1-6) for
what belongs in a pure module versus a Studio integration test, and how
to fake a service dependency reached through the loader. Along the way,
`luau-lsp analyze` (see below) caught a real strict-mode typing bug in
the runner's own
`xpcall` usage, since fixed. See `tests/TestRunner.luau`'s header comment
for the full reasoning, and revisit this if Jest-Lua ships real Lune
support later.

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
