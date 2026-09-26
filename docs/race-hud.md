# Don't Steal Bro! — Race HUD (P6-3)

The in-race HUD, built from the P6-2 component library
(`docs/components.md`) on the P6-1 foundation (`docs/ui-foundation.md`).

| File | Role | Tested |
|---|---|---|
| `src/client/UI/HudLogic.luau` | Pure: standings and the line gap, labels, effect timers, edge treatment per category, nearest station, arrow bearing | Headless (`tests/HudLogic.spec.luau`) |
| `src/client/UI/Screens/RaceHUD.luau` | The screen. Reads a `Store` of Vide sources and never touches a remote | Preview screenshot |
| `src/client/Controllers/RaceHUDController.luau` | Remotes → sources, the objective search, the use intent, and mounting for the `Race` state | On device |
| `src/client/UI/Screens/RaceHUDPreview.luau` | The real screen on scripted fake data | Screenshot |

## Data

Everything comes from payloads the server already pushes. The HUD never
polls or requests anything.

| HUD element | Source | Sent |
|---|---|---|
| Countdown | `RoundState.endsAt`, counted down locally against `Clock.now()` | On state change |
| Task list, objective arrow | **`TaskAssignmentState`** (new, targeted) | At race start and on each of your own completions |
| Placement, line gap | `TaskProgress` (counts for everyone) | On any completion |
| Power-up slots | `PowerUpInventoryChanged` (`slotCount`, held `{ slotIndex, powerUpId }`) | On change |
| Selected slot dimmed while firing | `PowerUpUseResult` clears it (or a 2s timeout) | Per use |
| Lock-on highlight | Local: `PowerUpLogic` targeting over rivals' rigs | Per frame while an Aimed/Nearest item is selected |
| Effect chips, edges | `StatusEffectsChanged`, which now carries `kind` | On change |

**Two server changes were needed**, both minimal:

- **`TaskAssignmentState`** (Net.luau, sent from `TaskService.sendAssignment`).
  Before this, no client knew its own route, only everyone's counts, so a
  task list and an objective arrow had nothing to draw. It's targeted,
  never broadcast: every route on every client would let a modified client
  predict where each rival is heading.
- **`kind` on `StatusEffectsChanged`**. The edge warning is for effects
  you are *suffering*, and `Movement` covers both Slow Field (debuff) and
  your own Sprint Boost (buff). The category alone can't tell them apart.

## Layout

Positions come from `Layout.THUMB_ZONES` rather than numbers of their own.

- **Top-centre (Info zone).** Placement card, the countdown ring, and the
  objective card, with the effect chips under them. In portrait the task
  progress bar sits between those two rows.
- **Top-left, landscape only.** The task list (progress bar, then one row
  per task). Portrait has no room beside the info bar, so it shows the bar
  alone.
- **The first Primary zone** (landscape: just left of and above the jump
  button; portrait: lower right). This holds the three power-up slots in a
  row, right-aligned to the zone's edge. Each slot shows an icon and a
  name, and the selected one has a glow outline. The full scheme is in
  `powerups.md` "Inventory and aiming". Tap a slot to select it, tap it
  again to quick-fire, and drag out of it to aim, releasing to fire or
  dragging back onto it to cancel (the outline turns red). With a
  keyboard or gamepad, slot numbers show and a `Q use RMB aim` / `X use
  L2 aim` line sits under the row. Q/X and 1–3/L1/R1 are bound through
  ContextActionService. Hold-to-aim is watched on UserInputService
  instead, because right-drag also turns the camera and must never be
  sunk. ButtonA is jump and R2 is Roblox's tool activate, which is why X.
- **Lock-on highlight.** A `Highlight` on the racer a fire would hit. It
  is faint for a quick-fire and strong while aiming. `RaceHUDController`
  runs the same `PowerUpLogic` targeting the server does, and sends the
  highlighted racer's id with the fire.
- **Screen edges.** These sit on their own full-bleed ScreenGui under the
  HUD, so the bands reach past the notch. Nothing on it is interactive.

Glance rules: there are no sentences. Placement is `1st`/`=3rd`. The gap is
`+2`/`−1`/`0`, and each line state changes icon as well as colour (✓ safe,
! on the line, ▼ out). The arrow shows a distance in studs, then `Done`.
Effect chips show an icon and seconds, with buffs as green pills and
debuffs as red squares.

**Placement ties are shown, not guessed.** The server breaks ties by finish
time and distance to your next station (`Qualification.luau`), and a client
can't see either for rivals. Two players on the same count both show
`=3rd` with a gap of `0`.

### Edge treatment

Each category differs by which edges light up, not only by colour
(`HudLogic.EDGES`, tested for uniqueness):

| Category | Edges | Colour | Motion |
|---|---|---|---|
| HardControl (Freeze, Push Trip) | all four | danger | pulses (off under reduced motion) |
| Movement (Slow Field) | left + right | warning | none |
| Vision (Blind) | top + bottom | brand | none |
| anything new | all four, thin | inkMuted | none |

Bands are 10–12% of the screen's short axis deep and fade to clear inward,
so the middle of the screen is never covered. Buffs never light an edge.

## Performance

The HUD has to run at 60 fps on a cheap phone without churning instances.

- **Built once.** Every instance is created at mount. Nothing is created
  or destroyed per frame. The task rows and effect chips go through
  `vide.indexes`, which reuses the row for a key. Controller list entries
  are frozen, so an unchanged row isn't rewritten (Vide only treats a
  table as unchanged if it's frozen).
- **Bind, don't poll, for server data.** Each remote writes one source
  once per real event. Placement, the task list and the power-up card
  re-run only when their source changes.
- **One clock, quantized.** A single Heartbeat writes `Clock.now()`,
  rounded to 0.1s, into a source. Vide skips equal primitives, so:
  - the ring's arc updates 10×/s, and that's the only 10 Hz work;
  - every number (the ring digits, effect seconds) sits behind a
    `derive` that returns a string, so each Text is written once a second;
  - `Visible` on the edge sets is derived to a boolean, so it's written
    only when an edge actually turns on or off.
- **The pulse is a Tween.** HardControl's pulse is a repeating
  TweenService tween on the band's transparency. It costs no Lua per
  frame, and it's cancelled while hidden and under reduced motion. A
  CanvasGroup would have been simpler to fade, but a full-screen one costs
  a screen-sized texture on low-memory phones.
- **The objective splits cheap from rare.** Picking the nearest outstanding
  station runs 5×/s (at most `tasksPerPlayer` distance checks). Turning the
  arrow runs every frame, because the camera turns every frame. It only
  writes when the bearing moves a whole 5° step or the distance moves a
  whole stud.
- **Update only on change:** placement, gap, task rows, held power-up,
  edges. **Per second:** ring digits, effect seconds. **10 Hz:** the ring
  arc. **Per frame, gated to a 5° change:** the arrow.

## Device review

1. Set the `UIRaceHUDPreview` attribute on `ReplicatedStorage` to `true`.
   A scene changes every 4 seconds: each effect category in turn (then a
   buff, then an unknown category, then none), the player going from out,
   to on the line, to safe, the arrow turning 45°, and the power-up slot
   alternating between held and empty. The countdown loops over the last
   20 seconds so its warning and critical states show up.
2. On each `perf-budget.md` §3 device, screenshot both orientations in
   each scene. Check the following:
   - Nothing sits under the notch, the top bar, the thumbstick or the jump
     button (turn on `UILayoutHarness` too to overlay the zones).
   - The use button is reachable with the right thumb without letting go
     of jump.
   - Each edge set reads as different in a greyscale screenshot.
   - The HardControl bands pulse, and stop pulsing under Reduced Motion.
   - Tapping a slot selects it (glow outline). Tapping the selected slot
     dims it, then empties it. Slots empty in place, with no shifting.
   - Dragging out of a slot and back onto it turns the outline red, and
     releasing there fires nothing.
3. Plug in a gamepad: the key line should read **X use L2 aim**, L1/R1
   should move the selection, and X should fire. On a keyboard it should
   read Q, and 1–3 should select.
4. In a live round with a rival nearby, holding an Aimed item: the rival
   gets a faint highlight when in front of you, and a strong one while
   right-click (L2) is held - which switches to first person - and you
   look at them. Q hits the highlighted
   rival. On touch, the highlight follows a drag from the slot.
5. In a live Studio round (`DebugForceRoundState` to Race): the HUD mounts,
   the arrow points at your nearest unfinished station, completing a task
   ticks its row and moves the arrow on, and the HUD goes away at
   Qualified.

## Not verified yet (device pass needed)

- **Gradient direction.** Whether `UIGradient.Rotation` 90/270 puts the
  opaque end at the top/bottom edge. If a band fades the wrong way, swap
  the two rotations in `SIDES`.
- **Glyphs.** 🐌 👁 ⏩ ▲ ▼ ○ are emoji or Unicode stand-ins, like P6-2's.
  The arrow has to point straight up at Rotation 0.
- **ButtonX, L1/R1, L2.** That no default or core binding claims them on
  any controller layout.
- **First-person aim.** That holding right-click / L2 with an Aimed item
  drops into first person, the mouse turns the view while WASD moves,
  and releasing restores the previous third-person zoom (the brief
  minimum-zoom raise in RaceHUDController).
- **Touch drag from a slot.** That a drag starting on a slot doesn't also
  turn the camera. A touch that starts on an Active GuiButton normally
  doesn't.
- **CountdownRing at 3 digits.** A 300s race shows `300` in a 64px ring.
  Check it fits at the minimum scale.

## Open items handed on

- **Late join mid-race.** `TaskAssignmentState` goes out at race start and
  on completions, not on join. A player who arrives mid-race has no race
  to be in anyway (RoundService only re-sends `RoundState`), but any
  future rejoin feature needs to re-send the route and the inventory.
- **Lock-on feel.** Cone width, range and the lock-on slack are
  placeholders (`GameConfig.powerUp*`). The drag dead zone (12px) and
  cancel radius (half a slot) are constants in `RaceHUD.luau`. All of
  them need a playtest pass on a real phone.
- **Qualification floor.** The line gap counts tasks only. It ignores
  `qualificationFloorPercent`, so a racer in the top 3 below the floor
  still shows as qualifying until the result arrives.
- **Toasts.** Only "No target" and "Cooling down" are toasted. Other
  refusals are internal, and the player can't act on them.
