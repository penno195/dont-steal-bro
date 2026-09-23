# Map validator (P7-1)

The only thing between a broken map and a live round. It checks a map
against `map-kit-spec.md` (the contract) and `perf-budget.md` (the
numbers). Any **error** blocks shipping. **Warnings** never do. **Info**
lines are numbers worth knowing.

## Layout

| File | Role |
| --- | --- |
| `plugin/MapValidator/MapCheck.luau` | Every rule, as pure functions over a plain-table snapshot. No Instance or service calls. |
| `plugin/MapValidator/Snapshot.luau` | Reads a real map Model into that snapshot. Runs in Studio and in Lune. |
| `plugin/MapValidator/Main.server.luau` | The Studio plugin: dock widget, config loading, reachability via PathfindingService. |
| `scripts/validate-maps.luau` | Headless runner for CI (Lune). Exits 1 on any error. |
| `tests/MapCheck.spec.luau` | Rule tests, in the normal `lune run tests/run` suite. |
| `plugin.project.json` | Rojo project that builds the plugin. |

All three callers (plugin, headless runner, tests) run the same
`MapCheck.run`, so the rules can't drift between them.

## Installing the plugin

```sh
rojo build plugin.project.json -o "$LOCALAPPDATA/Roblox/Plugins/MapValidator.rbxm"
```

If that path is wrong on your machine, open **Plugins → Plugins Folder**
in Studio and build into that folder instead. Restart Studio, or reload
plugins, after each rebuild. The plugin adds a **Map Validator** button
to a **Don't Steal Bro!** toolbar.

The place must have Rojo synced: the plugin reads task, power-up and map
configs from `ReplicatedStorage.Shared.Config`. It requires a fresh clone
of each def file on every run, so config edits apply without reloading
the plugin.

## Using it

- **Validate selected** checks the map that contains the current
  selection: the Model under `ServerStorage.Maps` it belongs to, or the
  selected Model itself for a map still being built in Workspace.
- **Validate all maps** checks every Model under `ServerStorage.Maps`.
- Click a finding to select every offending instance. A finding with no
  instance, such as a fall-through gap, moves the camera to it instead.
- The full text report is also printed to Output, in the same format as
  the headless runner.

## Reachability

This check paths from every `SpawnPoint` to every `TaskStation` and
`PowerUpSpawn`. A target is an error if **any** spawn can't reach it.
Each failed pair is printed to Output with its `PathStatus`.

- **Agent:** `MapCheck.PATH_AGENT` (radius 2, height 5, can jump), the
  same agent NPCService uses.
- **Probe points:** from `MapCheck.probePoint`. A non-collidable part (a
  trigger or marker) is probed at its centre, which is also where NPCs
  path to. A collidable part (a pad or console) is probed 3 studs above
  its top face. Pathing to a solid part's centre would always fail with
  `FailFinishNotEmpty`.
- **Kill zones:** each `KillZone` gets a `PathfindingModifier` with
  infinite cost, so a route through a kill zone doesn't count as
  reachable.
- **Leaves no trace:** PathfindingService only sees Workspace. A map in
  `ServerStorage.Maps` is cloned into Workspace for the check. The clone
  and the modifiers are made inside a ChangeHistory recording that is
  cancelled at the end, so nothing reaches the place or the undo stack.
  - **Caveat:** anything else already in Workspace at the same
    coordinates (the hub, another map) is part of the navmesh too, and
    can open or block paths. Clear it before trusting a reachability
    result.
- **Cost:** spawns × targets `ComputeAsync` calls, up to 6 × 44. Expect
  several seconds on a full map. The widget shows progress.
- **Skipped, never passed:** if the check can't run (another recording
  in progress, or pathfinding threw), the report says reachability was
  skipped and gives the reason in Output.

## Headless (CI)

```sh
lune run scripts/validate-maps path/to/DontStealBro.rbxl [MapName ...]
```

This runs every rule except reachability, which needs a live engine. The
report marks reachability as skipped rather than passed, so run the
Studio plugin before shipping a map either way.

**Open question: not wired into CI yet.** Maps live only in the `.rbxl`,
which isn't in this repo (see `CLAUDE.md`), so CI has nothing to run the
validator against. The options, none of them chosen yet:

1. Commit the place file, probably through Git LFS. Simple, but the
   `.rbxl` then has two homes.
2. Download the published place in CI using an Open Cloud API key stored
   as a secret. Verify the current download endpoint before building
   this.
3. Keep it a local pre-publish step, and make the plugin's pass line
   part of the ship checklist.

Once one is chosen, the CI step is a single
`lune run scripts/validate-maps <file>`. The exit code is already the gate.

The plugin's code is already covered by CI: selene, StyLua, and a
`luau-lsp analyze` pass against its own sourcemap.

## Limits worth knowing

- The gap scan uses a grid (`gapGridStuds`, default 4). A gap narrower
  than the grid can slip between samples.
- The budget numbers are low-confidence until P7-4 re-baselines them on a
  real device. They are overridable per run through `Context.budget`.
- The plugin UI and the reachability pass have been typechecked and
  linted, but not yet run in a live Studio session. The first real run
  on the gray-box map is the smoke test.
