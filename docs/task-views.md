# Don't Steal Bro! — Task Views (P6-4)

The client side of a mini-task, built on one shared shell. The server
side is unchanged: see [`how-to-add-a-task.md`](how-to-add-a-task.md)
for the handler, config and remote. This page covers only the view.

| File | What it owns |
|---|---|
| `src/client/UI/TaskViewBase.luau` | The shell: sheet/window, transitions, header (title, timer, close), status line, play area, input lock, submit |
| `src/client/UI/InputAdapters.luau` | One adapter per verb: Tap, Hold, Drag, Sequence, Timing, Aim |
| `src/client/UI/InputLock.luau` | Freezes camera + character input; restores exactly, reference-counted |
| `src/client/UI/TaskViewLogic.luau` | The pure maths behind all of the above (tested headlessly) |
| `src/client/Controllers/TaskStationController.luau` | When an attempt ends: success, close, death, out of range, race over, server `TaskEnded` |
| `src/client/TaskViews/CodePlayback.luau` | The worked example (keypad, Sequence verb) |

## Building task N (4 through 15): the checklist

1. **Server half first** — config, handler, submission remote, per
   `how-to-add-a-task.md`. Your `TaskDef.verb` picks your adapter.
2. **Create `src/client/TaskViews/<Name>.luau`** and return
   `TaskViewBase.define({ taskId, title, build, onProgress? })`. The
   registry picks it up; nothing else is edited.
3. **In `build(ctx)`, read `ctx.challenge`** (cast it to your handler's
   challenge type) and return your content. It's parented into
   `ctx.area`, the play area, which is already inset from every edge.
4. **Use the adapter for your verb** — never `UserInputService` or a raw
   `TextButton`:

   | Verb | Adapter | You supply | You get |
   |---|---|---|---|
   | Tap | `Tap` | size, visual, `onTap` | touch, click, A/Enter on focus |
   | Hold | `Hold` | visual(fraction, holding), `onPress`, `onRelease(held)` | slide-off release, A/Space hold, alt-tab release |
   | Drag | `Drag` | `items`, `targets` (GuiButtons), `area`, `onDrop` | drag with slop, multi-touch rejection, edge cancel, pick-then-place for gamepad |
   | Sequence | `Sequence` | keys, columns, key visual, `onPress` | D-pad grid that stops at edges, number-key shortcuts |
   | Timing | `Timing` | period, visual(cursor), `onPress` | whole target presses, A/Space from anywhere |
   | Aim | `Aim` | radius, `onAim`, `onRelease` | thumb-origin virtual stick, either gamepad stick |

5. **Submit with `ctx.submit("YourRemote", fields)`** — `stationId` is
   filled in, and submits stop once the attempt is over. Submit raw
   intent (which key, which slot); never a client-judged result.
6. **Feedback with `ctx.setStatus(text, feedback)` and `ctx.cue(feedback,
   sound?)`.** Two or three words, never a sentence. `feedback` is
   `"Neutral" | "Active" | "Good" | "Bad"`: each has its own icon, so
   colour is never the only signal. A cue always pulses the status line;
   the sound is optional garnish.
7. **Don't write close, abort, camera, timer or success handling.** The
   base does all of it. `onProgress(ctx, feedback)` is for a non-final result
   (default text: "Keep going"), plus the handler's optional per-submission
   feedback; a successful result carrying feedback reaches it first so
   the last step paints before "Done!". `FuseRewire.luau` uses it.
8. **Lay out for one thumb:** read-only content at the top of the area,
   interactive content anchored to the bottom (`AnchorPoint (0.5, 1)`).
   Sizes are reference pixels from `Theme` tokens.
9. **Open it in Studio.** The base audits every button after opening and
   warns about anything under 44 points or inside the edge margin. Fix
   every warning. Then run through the device checks below.

## Rules the base can't enforce

- **No task can depend on hearing.** Every sound needs a visual twin
  (`ctx.cue` does both). A "listen for the click" task is cut.
- **No state by colour alone.** Use the `feedback` states, or give your
  own elements a distinct shape or icon per state.
- **Reduced motion:** use `Env.animate` for anything that moves for
  decoration, so it snaps. Motion that *is* the task (a Timing cursor)
  still moves; drop its trails and glows.
- **Never reveal the answer.** The challenge you receive is the only
  secret the server chose to send (see the exploit section of
  `how-to-add-a-task.md`).
- **One thumb.** If it needs two simultaneous touches or camera control,
  it's cut (CLAUDE.md rule 3).

## What the shell guarantees

- **Presentation:** full-screen sheet on any touch device or small
  screen; a centred window on a big mouse/gamepad screen
  (`Tokens.taskView.windowMinShortAxis`). Re-decided live on rotate.
- **Input lock:** controls and camera are frozen from open to close and
  restored on every close path. The lock works at the input layer
  (`ControlModule:Disable`); it never touches `WalkSpeed`/`JumpPower`,
  which only the server's `StatusEffects` sets. So a player frozen by a
  power-up mid-task stays frozen, for exactly as long as the server says,
  after the view closes. Camera type goes back to what it was before the
  lock, unless something else changed it in the meantime.
- **Every exit closes cleanly:** the close button, B on a gamepad, death,
  respawn, being knocked or walking more than
  `Tokens.taskView.leaveRangeStuds` from the station, the race ending,
  a new challenge, and the server's `TaskEnded`. All of them run through
  `TaskStationController.finish`, which hides the view and tells the
  server (`TaskAbort`). A disconnect needs nothing from the client:
  `TaskHandlerService` ends the session on `PlayerRemoving`.
- **Attempt numbers:** `TaskChallenge` carries `attempt`; `TaskAbort` and
  `TaskEnded` echo it, so a late message about an old attempt can never
  end a new one, whatever order the remotes land in.

## Biggest mobile usability risk: touches that cross the open/close line

The player's thumb is on the thumbstick when they walk into a station, and
on the keypad when the task ends. A touch held across that moment is the
likeliest thing to go wrong on a phone. When the sheet opens, the
movement thumb is already on the glass where a key or item is about to
appear. When the task ends, the thumb is still down on the keypad as the
world comes back. If either touch counts, the player gets a phantom
key-press, a drag they never started, a camera spin or an unwanted jump,
and on a phone they can't tell what happened.

How the base prevents it:

- **The input lock disables controls at the input layer.** A held
  thumbstick touch stops driving the character the moment the view opens,
  so there's no slide past the station while the sheet animates in.
- **Adapters only accept a touch that begins on their own hit area.**
  Drag starts on the item's `InputBegan`, Hold on the button's, and
  Tap, Sequence and Timing go through `Activated`, which needs both the
  press and the release on the button. A touch carried over from the
  thumbstick never began there, so it can't press anything.
- **Drag has one owner and rejects other fingers.** A resting palm or
  second thumb is ignored. A drag that runs into the edge margin, loses
  its `InputEnded` or is cancelled by the OS is cancelled, never dropped
  at a clamped edge position.
- **Controls come back when the attempt ends, not after the exit
  animation.** Roblox's touch controls only take touches that begin
  after they're re-enabled, so a thumb still resting on the keypad
  doesn't become a jump or camera drag.

## Device checks (not verifiable in CI)

Nothing here has run on a device yet. Check these on a cheap Android phone
in portrait before building more tasks on the base:

1. `ControlModule:Disable()` hides the thumbstick and jump button, and
   `Enable()` brings them back. (`PlayerModule:GetControls()` is used from
   memory of the default PlayerModule. If the place forks PlayerModule,
   `InputLock` falls back to camera-only.)
2. `InputObject.Position` and `AbsolutePosition` share one space on a
   notched phone. Drag and Aim hit tests assume they do; the fix, if not,
   is `pointOf` in `InputAdapters.luau`.
3. A touch drag that runs off the screen edge cancels, and the item goes
   back.
4. With a Freeze landing mid-task, closing the view leaves the player
   frozen until the effect ends.
5. With a PushTrip knockback mid-task, the view closes and the camera
   comes back.
6. On a gamepad: the first key is focused on open, the D-pad stops at
   the keypad's edges, and B closes.
7. With a thumb still down on the keypad as the task succeeds, lifting it
   after the sheet has gone neither jumps nor turns the camera. (The risk
   section above relies on this.)

## Migrating the older views

`PressureValve` (Tap) and `FuseRewire` (Drag) are still plain Instances.
Their camera freeze now goes through `InputLock`, and the controller's
guards close them like any other view. Move them onto the base (with
`InputAdapters.Tap` and `InputAdapters.Drag`) when they're next touched.
Until then they don't get the sheet or the header. P6-7 did move them onto
`createScreen` safe-area screens, bottom-anchored (`docs/mobile-audit.md` #3–4).
