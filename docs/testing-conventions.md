# Don't Steal Bro! — Testing Conventions (P1-6)

How this repo tests itself, and the rule for what's expected to be
covered by an automated test versus verified by hand in Studio.

## The harness, and why it isn't Jest-Lua

`build-plan.html`'s original P1-6 prompt asked for Jest-Lua installed via
Wally, run from Studio's command bar, plus a Lune script running the same
suite headlessly in CI. That was tried first, during P1-1, and found not
to hold: Jest-Lua currently only runs inside the real Roblox engine (no
Lune support), and TestEZ's headless CI path (Lemur) runs on a Lua 5.1
interpreter that can't parse `--!strict` Luau syntax at all — neither
satisfies Ground Rule 4 for this project. `wally.toml`'s own comment
already documents this: "No `[dev-dependencies]` testing library is
pinned here... Jest-Lua and TestEZ+Lemur were both evaluated and ruled
out." This document doesn't re-litigate that — see the README's
**Testing** section for the full reasoning — it picks up from where it
left off: `tests/TestRunner.luau` (a ~95-line hand-rolled runner, no
third-party dependency) executing directly under Lune's real Luau
runtime, registered per-spec-file in `tests/run.luau`, run headlessly via
`lune run tests/run`. **That CI wiring already exists** — `ci.yml`'s
"Run pure-logic tests (Lune)" step, added in P1-1 — there's no further
one-line change to make; this task's job was the *content* around it:
what to test, how to keep it testable, and what a new test file should
look like.

Revisit the Jest-Lua decision if it ever ships real Lune support.

## What belongs in a pure module

A pure module makes **zero Roblox API calls anywhere a test would
execute** — no `game`, no `Instance`, no `workspace`, no `task.wait`.
Outcome resolution, pricing, ranking, tie-breaks, streak maths, payload
validation, rate limiting, config validation, migration chains — anything
that's really just data in, data out. These are the modules Ground Rule
4 requires to be unit-tested headlessly, and every one of them gets a
`tests/<Name>.spec.luau` registered in `tests/run.luau`.

**What needs a Studio integration test instead:** anything that has to
observe a real `RemoteEvent` firing, a real `Player` joining, a real
`ProfileStore` session, a real `CollectionService` tag, or timing against
`workspace:GetServerTimeNow()`. These are verified manually in Studio's
"Clients and Servers" test mode — `ci.yml`'s own comment says so
explicitly for exactly this reason.

**The split isn't "shared vs. server vs. client" — it's whether the file
touches a live Roblox API.** Several pure modules in this repo live under
`src/server/` (e.g. `ProfileLogic.luau`) because the *logic* is pure even
though only server code calls it; what matters is the file itself, not
its folder.

### The pattern: one pure module, one thin Roblox-touching wrapper

Every system with real Roblox-side behavior in this repo follows the
same split, and a new one should too:

| Pure (Lune-tested) | Roblox-touching (Studio-verified) |
|---|---|
| `Net.luau` (schema, rate limiter, state gate) | `NetGuard.luau` (RemoteEvent wiring, `Players`) |
| `Validate.luau` (config checks) | `ConfigValidator.luau` (`ServerStorage.Maps` lookup) |
| `ProfileLogic.luau` (schema, migrations, ordering) | `DataService.luau` (`ProfileStore`, `Players`) |
| `Loader.luau`'s `topoSort`/`registerForTesting` | `Loader.luau`'s own `start` (`folder:GetChildren()`) |

The pure half is where the actual bugs hide (a wrong tie-break, a bounty
invariant that silently breaks, a migration that drops a field) — the
Roblox-touching half is comparatively hard to get wrong and hard to unit
test, so this split puts the automated coverage exactly where it earns
the most.

### Keeping Roblox API calls out of a pure module

1. **No `game:GetService(...)` at module scope.** If a function needs a
   Roblox service, fetch it *inside that function* — never called by a
   test, never executed when the module is merely `require()`'d.
2. **No requires of a sibling shared module**, even a pure one, unless
   both sides can resolve the SAME require syntax in both runtimes.
   Roblox's Instance-path requires (`require(ReplicatedStorage.Shared.X)`)
   can't resolve under Lune, and Lune's relative-path requires
   (`require("./X")`) can't resolve as Roblox `require()` calls either.
   `Net.luau`, `Validate.luau` and `ProfileLogic.luau` all stay
   self-contained for exactly this reason — where two pure modules would
   otherwise need to share a small type, duplicate it (Luau's structural
   typing means a real value from the other module still satisfies the
   duplicated type with no cast needed — see `ProfileLogic.luau`'s
   `BountyTier` for the actual example).
3. **Take a clock, don't read one**, for anything time-based. `Net.
   tryConsume(state, now)` and `Validate`/`ProfileLogic`'s functions all
   take `now`/timestamps as arguments rather than calling `os.clock()`
   or `os.time()` themselves — deterministic, and a test can move time
   forward without waiting on a real clock.
4. **Return values, not the ability to observe side effects.** A pure
   function tells its caller what happened (`Issue`, `LoadOutcome`, a
   boolean) instead of logging or mutating global state directly — the
   Roblox-touching wrapper decides what to actually do with that.

## Faking a dependency reached through the loader

A pure-logic module sometimes needs to reach another service via
`Loader.get(name)` rather than requiring it directly (that's the whole
point of `Loader.get` — no direct coupling). Its unit test shouldn't have
to boot the entire `Loader.start` pipeline — with a real Roblox `folder`
of `ModuleScript`s — just to satisfy one dependency it isn't even trying
to test.

`Loader.registerForTesting(module)` is the seam for this: it inserts
directly into `Loader`'s singleton registry, so a later `Loader.get(name)`
call finds it, without ever touching `folder:GetChildren()`.
`tests/Loader.spec.luau`'s "mocked-service module" example is the
pattern to copy:

```lua
Loader.registerForTesting({
	name = "TitleService",
	labelFor = function(streak: number): string
		return if streak >= 10 then "Legend" else "Rookie"
	end,
})

-- now any code under test that does Loader.get("TitleService") finds the fake
```

Never call `registerForTesting` outside a test — production always goes
through `Loader.start`, which is what keeps the registry honest about
what's actually running.

## Example test files

- **Pure module, adversarial input:** `tests/Net.spec.luau` — the
  well-formed/hostile-extra-field pair, a token-bucket burst/refill test,
  and a fail-closed state-gate test.
- **Pure module, boot-time config:** `tests/Config.spec.luau` — one case
  per named invariant (bounty ordering, the Robux-needs-a-free-path rule,
  cross-registry references) plus a happy-path check.
- **Pure module, migration chain + ordering guarantees:**
  `tests/ProfileLogic.spec.luau` — migration chain, mid-round-leave
  ordering, failed-load classification, double-release idempotency.
- **Mocked-service module:** `tests/Loader.spec.luau` — `topoSort`
  against hand-built registries (normal order, a cycle, a missing
  dependency), then the `registerForTesting` fake-dependency pattern
  above.

## Coverage expectations and CI failure threshold

- **Pure modules: every named invariant and every failure class gets its
  own case**, not just a happy path. If a module's own doc comment names
  an invariant (e.g. Validate.luau's "sole-stealer > lone-sharer >
  all-share > 0"), that invariant has a test that fails when it's
  violated — not just a test that it holds for one example.
- **Roblox-touching wrappers are NOT required to have an automated
  test.** They're expected to be exercised manually in Studio before a
  task is marked done (see each service's own file for what "working" 
  looks like), and kept intentionally thin so there's as little
  untested surface as possible.
- **CI failure threshold: any failing case fails the build, full stop.**
  `TestRunner.run()` calls `process.exit(1)` the moment `totalFailed > 0`
  (see its own source) — there's no "acceptable failure count" concept,
  by design. A flaky pure-logic test is a bug in the test (it shouldn't
  be flaky — there's no real clock, no real network, nothing
  nondeterministic in scope), not something to tolerate.
- **No line/branch coverage percentage is enforced.** With ~50 tests
  covering four modules' worth of named invariants at this point in the
  project, a percentage target would be premature — revisit once there's
  enough pure-logic surface for a regression in an untested corner to be
  a real, observed risk rather than a hypothetical one.
