# How to add a mini-task (P2-5)

Companion to `tasks-catalogue.md` (what the 15 tasks are) and
`map-kit-spec.md` (the `TaskStation` tag contract a map author fills in
separately). This document is about the *code* side: the framework a
task author writes against, using `code-playback` (tasks-catalogue.md
#9, the P2-5 reference implementation) as the worked example throughout.

## The three-way split

Every task splits into three files, each in its own folder, each
independently auto-collected — dropping the file in is the whole change,
the same pattern `src/shared/Config/Tasks/init.luau` already used before
this task existed:

| File | What it is | Auto-collected by |
|---|---|---|
| `src/shared/Config/Tasks/<Name>.luau` | The shared definition: id, display name, verb, expected duration, mobile feasibility | `Config/Tasks/init.luau` |
| `src/server/TaskHandlers/<Name>.luau` | The server handler: `start`/`validate`/`cleanup` | `TaskHandlers/init.luau` |
| `src/client/TaskViews/<Name>.luau` | The client view: the on-screen minigame | `TaskViews/init.luau` |

**That's it for a task reusing an existing interaction shape** (see
"When you need a fourth file" below for the one case that isn't just
three files). No service anywhere is edited. Concretely, to add task
`#16` today you would write:

1. `src/shared/Config/Tasks/YourTask.luau` — a `Validate.TaskDef`. Copy
   `CodePlayback.luau`'s shape; `id` must be unique (`ConfigValidator`
   fails boot loudly if it collides or any field is out of range).
2. `src/server/TaskHandlers/YourTask.luau` — implements
   `Types.TaskHandler<Challenge, State, Submission>` (see below). `taskId`
   must equal the id from step 1.
3. `src/client/TaskViews/YourTask.luau` — implements `Types.TaskView`
   (see below). `taskId` must also equal the id from step 1.

Then, separately (map authoring, not code): add the id to a station's
`AcceptedTaskIds` attribute in Studio for any map that should roll it.

## The server contract

`src/server/TaskHandlers/Types.luau` declares:

```lua
export type TaskHandler<Challenge, State, Submission> = {
	taskId: string,
	start: (ctx: TaskContext) -> (Challenge, State),
	validate: (ctx: TaskContext, state: State, submission: Submission) -> (boolean, State),
	cleanup: (ctx: TaskContext, state: State) -> (),
}
```

- **`start(ctx)`** rolls the challenge server-side, from `ctx.rng` (a real
  `Random`, seeded per attempt — never `math.random`, which isn't
  per-instance-seeded and would let one player's rolls influence
  another's). Returns `Challenge` (what the client renders) and `State`
  (your own private progress tracking, carried between calls, **never**
  sent to the client).
- **`validate(ctx, state, submission)`** is called once per submitted
  *intent* — one digit tap, one aim-stop signal, whatever shape your
  task's own remote sends — not once per whole attempt. Returns whether
  the task is now fully **complete**, plus the next `State`. This is what
  lets one contract cover both a single-shot task (one submission,
  immediately true or false) and a multi-step one (several submissions,
  true only on the last) without two different shapes.
- **`cleanup(ctx, state)`** always runs exactly once per attempt: on
  success, on a new interaction superseding this one, or on the player
  leaving. `TaskHandlerService.luau` guarantees this — most handlers
  (including `code-playback`) have nothing to release and leave it empty.

`ctx: TaskContext` carries `player`, `stationId`, `stationPart`, `rng`,
and `elapsedSeconds()` — **never reach past `ctx` for game state**
(`Players`, `CollectionService`, `GameConfig`) from inside a handler. The
three checks the task brief calls out by name — minimum plausible
completion time, still in range of the station, still on the player's
list and not already complete — are enforced by `TaskHandlerService.luau`
itself, once, **before** your `validate` ever runs. You don't re-check
them; a handler that reaches for `Players` to re-verify range itself is a
sign the abstraction has a hole, not a sign of thoroughness.

## The client contract

**Build the client view on `src/client/UI/TaskViewBase.luau`** — the
step-by-step guide is [`docs/task-views.md`](task-views.md). The base
implements the raw contract below for you; you only write a `build`.

`src/client/TaskViews/Types.luau` mirrors the server shape on purpose:

```lua
export type TaskView = {
	taskId: string,
	show: (stationId: string, challenge: any, session: Session) -> (),
	onResult: (stationId: string, success: boolean) -> (),
	hide: (stationId: string) -> (),
}
```

`show` builds/opens your UI from the `challenge` a `TaskChallenge` event
delivered; `session.close()` is the abort path. `onResult` reacts to a
`TaskResult` for a submission your view itself fired — a `false` result
means "still open, try again," only `true` ends the attempt. `hide` tears
the UI down for any other reason the attempt ended — the close button,
death, being knocked out of range, the race ending, a different station
superseding it, or the server's `TaskEnded`. `TaskStationController`
decides all of those (P6-4), for every view.

**A view fires its own submission remote** (`code-playback`'s view fires
`KeypadDigitSubmit`, through `ctx.submit`) — `TaskStationController.luau`
(the client-side dispatcher) never needs to know your submission shape,
only which view to hand a `TaskChallenge` to by `taskId`.

## When you need a fourth file

The `start`/`validate`/`cleanup` and `show`/`onResult`/`hide` contracts
above are fully generic across every verb. The one thing that **isn't**
generic is a submission remote's payload shape — a Sequence task sends a
digit or switch id, a Timing task sends a stop signal, an Aim task sends
a direction, and `Net.struct`'s exact-shape validation means one remote
can't honestly cover all of them.

- **Reusing an existing verb's shape** (e.g. a second Sequence task that,
  like `code-playback`, submits `{ stationId, digit }`): reuse
  `KeypadDigitSubmit` as-is. Zero new remotes, zero dispatcher edits —
  genuinely three files.
- **A genuinely new interaction shape**: declare one new remote in
  `Net.luau` (`Net.string`/`Net.number`/etc. — see its own "adding a new
  remote in five lines" header comment) and add one
  `NetGuard.on("YourNewRemote", ...)` block to
  `TaskHandlerService.luau:init()` that calls the shared
  `handleSubmission(player, stationId, submission)` — the same function
  `KeypadDigitSubmit`'s handler calls. Everything past that point (the
  three shared guards, calling into your handler, firing `TaskResult`) is
  unchanged. This is the one legitimate case that isn't "three files and
  nothing else," because it's a new piece of wire protocol, not a gap in
  the abstraction.

## How an exploiter could complete a task without playing it — and what stops it

Two concrete shortcuts, and the exact line that closes each:

**1. Reading another player's answer off the network.** `code-playback`'s
`Challenge` legitimately contains the answer — the whole premise is
showing the player a code to memorize. If `TaskHandlerService.
beginInteraction` broadcast that payload with `Net.fireAllClients`, every
player in the server would receive every other player's rolled code the
instant anyone interacted with any station — no macro needed, just
reading the RemoteEvent. The fix is one line, in
`TaskHandlerService.luau`:

```lua
Net.fireClient("TaskChallenge", player, { stationId = stationId, taskId = taskId, challenge = challenge })
```

`Net.fireClient`, targeted at the one interacting player — never
`Net.fireAllClients` — for both `TaskChallenge` and `TaskResult`. This is
worth grepping for by name in any *new* task's code review: a
`fireAllClients` call anywhere near a challenge payload is the bug.

**2. Firing a "the client asserts this is a scripted success" remote.**
There is no such remote, and there never should be — completion is
reached exactly once, from server code, in `TaskHandlerService.
handleSubmission`:

```lua
if done then
	TaskService.recordCompletion(player, stationId)
	endSession(player)
end
```

`done` only ever comes from your handler's own `validate`, called after
the three shared guards passed, against a submission whose shape
`NetGuard` already rejected if malformed. A script that skips the
minigame has no remote to fire that would ever make `done` true — there
is nothing to "complete a task without playing it" *toward*, because
completion was never externalized as something a client can assert.
