# Don't Steal Bro!

A competitive Roblox mini-task race with power-up griefing and a social-deduction
finale. Six players race to finish their tasks while sabotaging each other. The
first three to finish are teleported to the **Decision Studio**, where they can
talk, negotiate and lie — then blindly pick **Steal** or **Share**.

Your win streak is the whole metagame. It only goes up. One loss takes it all.

## Status

**Foundation and tooling (Phase 01).** Pre-production (Phase 00) is done —
all eight open design questions are resolved (`docs/design-decisions.md`),
the task and power-up catalogues, map kit contract, payoff table, perf
budget, and threat model are all written. The repo is a working Rojo
project (P1-1) with a two-phase Service/Controller bootstrap loader
(P1-2, `src/shared/Loader.luau`) and a typed remote layer with payload
validation, per-player rate limiting, a round-state gate and violation
escalation (P1-3, `src/shared/Net.luau` and
`src/server/Services/NetGuard.luau`) — the game's entire client-facing
attack surface, and the first real `Service` past the bootstrap loader
itself. `ExampleController` is still a placeholder; no real controller
exists yet.

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
is a ~90-line hand-rolled runner that executes directly under Lune's real
Luau runtime, with no third-party dependency. This was installed and run
locally (not just researched): `lune run tests/run` passes both cases in
`tests/Example.spec.luau`, and along the way `luau-lsp analyze` (see
below) caught a real strict-mode typing bug in the runner's own
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
