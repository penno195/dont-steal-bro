# Don't Steal Bro! — Power-ups & Counter-Play Matrix (P0-3)

10 power-ups for the race stage, plus the anti-frustration layer that
governs how they interact. This catalogue is the same item pool referenced
by `design-decisions.md`: Q1's Studio reward packages are drawn from it
(higher streak tiers weight toward rarer power-ups), and Q8's 3-item
pre-game loadout is picked from a player's persistent inventory of it.
Concretely, there are two acquisition paths for the same items:

1. **Field pickup** — spawns on the map during the race, free, skill-based
   (reach it before someone else does). Consumed on pickup, usable
   immediately, no persistent ownership.
2. **Loadout slot** — one of 3 items chosen pre-game from a persistent
   inventory earned via Studio wins, loyalty rewards, event drops, or Robux
   (per Q8: Robux only ever buys something also earnable free, never an
   exclusive item).

Each power-up below is one `src/shared/Config/PowerUps/<Name>.luau`
definition and one handler module, per the architecture doc's scaling
rule — adding an 11th needs no service changes.

## Inventory and aiming

Decided 2026-09-25 after a playtest. This replaces the earlier "one
inventory slot" default, and answers how the two acquisition paths
coexist (`store-receipts.md` §5).

- **Three slots** (`GameConfig.powerUpInventorySlots = 3`), shown as a
  panel in the bottom-right thumb zone. The pre-game loadout starts in
  them, in the order the player picked it, as the race begins. Field
  pickups fill the lowest empty slot. With all three full, a pickup is
  refused and stays on the map (`powerUpFullInventoryPolicy = "Refuse"`).
- **Slots are fixed positions.** Using slot 2 empties slot 2; slot 3
  doesn't slide down. The slot a player has selected never changes under
  their thumb. When the selected slot empties, the HUD moves the
  selection to the lowest slot that still holds something.
- **Selection.** Tap or click a slot to select it. The selected slot has
  a glow outline. On a keyboard, 1–3 select; on a gamepad, L1/R1 cycle.
- **Firing.** **Q** (gamepad **X**) fires the selected item. On touch,
  tapping the selected slot quick-fires it.
- **Discarding.** Drag a held item out of its slot and a bin appears above
  the left end of the slot row. It turns red and grows while you're over
  it, and letting go there throws the item away, freeing the slot for a
  better pickup. Letting go anywhere else fires or cancels as normal. On a
  keyboard, **X** discards the selected item. The client sends only the
  slot index (`PowerUpDiscardIntent`), and the server only ever empties
  one of the sender's own slots. A discard sets no cooldown.
- **Lock-on aim for `Aimed` items.** These aren't skill-shot projectiles.
  The nearest racer inside a cone (`powerUpTargetConeDegrees`, up to
  `powerUpUseRangeStuds`) is highlighted, and that racer is who the shot
  hits. With no aim, the cone points where the character faces, and a
  faint highlight shows who a quick-fire would hit. To aim:
  - **PC:** hold left-click (right-click stays the camera's own look
    control). The camera goes first person, facing whatever was under the
    cursor when you clicked, so clicking on a rival puts them straight
    under the crosshair with no flick (2026-09-30; it used to keep the
    camera's old heading). The cone then points where you
    look: the mouse turns the view (and the character), and WASD still
    moves. The crosshair sits where you look until it locks on. Let go to
    fire: releasing fires if something is locked, and otherwise cancels.
    Q also fires mid-aim. Either way the previous zoom comes back.
    Left-click only aims while an `Aimed` item is selected; a click on the
    HUD never starts an aim. Gamepad: hold L2 the same way, right stick to
    turn.
  - **Mobile:** press a slot and drag out of it. The cone follows the drag
    direction, and releasing fires. Dragging back onto the slot cancels
    (Brawl Stars style).
  - **While aiming**, a laser runs along the floor from the character's
    feet, with a crosshair at its end. (In first person it instead runs
    from hand height to the crosshair, which sits where you look until it
    locks on.) With no lock, it's white and runs
    the full `powerUpUseRangeStuds`, so the reach is visible. When locked
    on, it runs to the target, and the crosshair sits on their body,
    turning green and tightening to a solid dot (a shape change as well,
    so it doesn't rely on colour). The crosshair is drawn on screen above
    the HUD, because its unlocked spot is near the horizon, right where
    the top bar is.
  - Only `Aimed` items (Freeze, Blind, Task Scramble, Push/Trip) aim.
    The key hint shows "LMB aim" / "L2 aim" only while one of those is
    selected.
- **`Nearest` items** auto-target the nearest racer in range, ignoring
  aim. The target kind still exists, but no item uses it since Blind and
  Push/Trip became `Aimed`.
- **Server authority.** The client sends only the slot, the id of the
  racer it locked on to, and a ground-plane aim direction. The server
  re-runs the same `PowerUpLogic` targeting and honours that lock only if
  the racer is still in range and in the cone. It allows
  `powerUpLockOnSlackStuds`/`Degrees` of slack because the client saw
  that racer a round trip ago. Otherwise the use is refused ("No target")
  and the item stays in its slot. Any direction is a legal aim, so the
  cone isn't a security boundary. Range is, and the slack is the most a
  modified client can gain.

## The 10 power-ups

| id | Type | Role | Target | Duration | Magnitude | Cooldown | Rarity |
|---|---|---|---|---|---|---|---|
| `sprint-boost` | Buff | Utility | Self | 6s | +35% move speed | 10s | Common |
| `second-wind` | Buff | Defence | Self | instant + 2.5s immunity | Cleanses all active debuffs | 22s | Rare |
| `task-insight` | Buff | Utility | Self | next attempt (≤15s) | -1 difficulty tier on current task's rolled challenge | 12s | Uncommon |
| `phase-step` | Buff | Defence | Self | 3s | Untargetable by targeted effects; passes through hazards & players | 15s | Rare |
| `overclock` | Buff | Utility | Self | 10s | -50% cooldown on own other power-ups | 20s | Rare |
| `freeze` | Debuff | Attack | Aimed | 2.5s | Full immobilize, can't interact with tasks | 12s | Uncommon |
| `slow-field` | Debuff | Attack | Area | 5s zone | -40% move speed while inside | 15s | Common |
| `blind` | Debuff | Attack | Aimed | 4s | Obscures screen, no movement lock | 12s | Uncommon |
| `task-scramble` | Debuff | Attack | Aimed | instant | Forces current task's challenge to re-roll (~4s added) | 10s | Common |
| `push-trip` | Debuff | Attack | Aimed | 1s stagger | Knockback + brief stun | 7s | Common |

**Role** is the colour family on the HUD slot and pickup orb: Attack red
(exactly the Debuffs, enforced by `Validate.checkPowerUp`), Defence blue,
Utility yellow. Rarity is a small ring on top, never the main colour.
Cooldowns were halved on 2026-09-28, and field respawn timers with them
(`GameConfig.powerUpRotationTimers`: 10/20/35s). Items are consumed on
use, so a cooldown only matters on a duplicate pickup; respawn timers are
the real pacing lever.

### Explaining them in play

A playtest on 2026-09-28 showed players couldn't tell what the power-ups
did, whether they were using one or being hit by one. So:

- **`description`** (required, at most 48 characters, enforced by
  `Validate.checkPowerUp`): one plain line per item, e.g. Freeze's
  "Freezes a rival in place". It has no numbers on purpose, so it can't
  drift out of date when durations are rebalanced.
- **First pickup:** the first time a player holds each type in a
  session, a toast shows `displayName: description`. After that there's
  only the slot icon, so it never nags.
- **Being hit:** the victim is told about **every** item used on them
  (user decision, 2026-10-03, after a two-player test where Task Scramble
  on someone away from a task was spent in silence). The server sends the
  victim alone `PowerUpHitYou` `{ powerUpId, casterName, landed }`:
  - Landed: a red toast reads "Alex used Freeze on you".
  - Reached them but did nothing (a ward, an immunity window, no task to
    scramble, the scramble cap): an amber "Alex used Task Scramble on
    you - no effect".
  - Slow Field: once per zone per player, the first time it catches
    them (landed or warded).
  An item that never reached them (out of range, target gone before a
  throw lands) sends nothing.

### 1. Sprint Boost (Buff, Self)

**Counter-play:** n/a — self buff. **Stacking:** doesn't stack with itself
(reapplying refreshes duration, not magnitude); partially offsets an active
Slow Field (see matrix) rather than fully canceling it.

### 2. Second Wind (Buff, Self)

Instantly clears every active debuff and grants 2.5s of immunity to new
ones. **Counter-play:** n/a. **Stacking:** blocks any debuff that would
land during its immunity window; the dedicated defensive tool in the kit —
this is what makes a pure-defensive 3-item loadout (per Q7) a real choice,
not a trap.

### 3. Task Insight (Buff, Self)

Shrinks the server-rolled difficulty of whichever task the player is
currently engaged with by one tier (e.g. a lower tap-target count on
Pressure Valve, a wider timing tolerance on Reactor Sync) — reads directly
off the same rolled-challenge parameters `tasks-catalogue.md` describes, no
separate difficulty system needed. **Counter-play:** n/a. **Stacking:**
reduces Blind and Task Scramble's effect (see matrix); doesn't stack with
itself.

**As built:** every task handler has an easy tier (`TaskContext.easy`):

| Task | Normal | Easy |
|---|---|---|
| Code Playback | 4 digits | 3 digits |
| Pressure Valve | 18–24 taps | 10–14 taps |
| Vent Purge | 14–20 taps | 8–12 taps |
| Fuse Rewire | 4 fuses | 3 fuses |

Used mid-task, the current attempt restarts on its easy tier. Used
anywhere else, the next attempt started within `durationSeconds` (15s)
rolls easy, and that spends it.

### 4. Phase Step (Buff, Self)

Grants a brief window of being untargetable by anything that requires
locking onto or colliding with the player — Freeze, Blind, Task Scramble,
and Push/Trip all fail to connect. Deliberately does **not** block Slow
Field, since that's a stationary environmental zone, not a targeted cast —
walking through the space still means walking through the slow. **Counter-
play:** n/a. **Stacking:** see matrix; the kit's preemptive defensive tool,
as distinct from Second Wind's reactive cleanse.

### 5. Overclock (Buff, Self)

Halves the cooldown on the player's other equipped power-ups for its
duration — a pure offensive/utility enabler with no defensive property at
all. **Counter-play:** n/a. **Stacking:** every debuff applies fully while
Overclock is active; this is intentional (see anti-frustration note below)
— a purely offensive pick should not also be the safest pick.

### 6. Freeze (Debuff, Aimed)

**Counter-play:** Second Wind cleanses it; Phase Step blocks it if timed
before the cast lands; failing either, the fixed 2.5s duration plus the
post-effect hard-control immunity window (below) bounds the worst case.
**Stacking:** does not extend past its own duration if reapplied — see the
anti-frustration layer for cross-effect stacking rules.

### 7. Slow Field (Debuff, Area)

A stationary, visibly-telegraphed ground zone rather than a direct hit —
the player chooses to walk into it or around it. **Counter-play:** walk
around it (it's static and visible before entry); Sprint Boost partially
offsets the penalty while inside; Second Wind's immunity window blocks
re-entry punishment briefly. **Stacking:** overlapping zones (same or
different casters) stack multiplicatively but are capped at a combined
**-70% floor** — see the anti-frustration section; this cap exists
specifically because Slow Field is the one debuff *not* covered by the
hard-control safety nets below (it's soft, not hard, control).

**As built:** the zone is a translucent red disc dropped at the caster's
feet, `areaRadiusStuds = 15` across (about three times a character's
height) and as tall as it is wide. It lasts `durationSeconds` and slows
everyone inside it except the caster. A racer gets one slow per zone,
which lasts while they stay in and ends 0.3s after they step out, so a
single zone never stacks on itself. Only overlapping zones stack.

### 8. Blind (Debuff, Aimed)

Aimed like Freeze (it auto-targeted the nearest opponent until 2026-09-28)
— obscures vision but never touches movement. **Counter-play:** a blinded
player can still walk to a known task by memory/landmarks since movement
is untouched; Task Insight reduces the effect on task precision; Phase
Step blocks it outright if pre-empted. **Stacking:** reapplying refreshes
duration only, never increases the visual obstruction magnitude.

**As built (2026-09-30):** `BlindController` blurs the 3D world
(`BlurEffect` size 24) and dims it with a black tint at 0.45
transparency. The tint also covers phones whose graphics level drops
post-processing. Both sit under the HUD, so task lists and slots stay
readable. It's driven by the `StatusEffectsVisual` broadcast for your
own id, so it works in races and in the hub practice area. Until then,
the only sign of Blind was a thin HUD edge band, and in the hub there
was nothing at all.

### 9. Task Scramble (Debuff, Aimed)

Forces whichever task challenge the victim is mid-attempt on to re-roll —
costs time, never movement or vision. **Counter-play:** disengaging from
the station before the (telegraphed) cast lands avoids it entirely; Task
Insight halves the added time cost. **Stacking:** a single caster can't
re-apply to the same victim until their own cooldown clears, but a
*different* caster can — this is the kit's other gap in the hard-control
safety net (see below), since it's a soft, non-movement effect and time-
cost, not disable-time, is what compounds.

**As built:** the victim's current attempt restarts from scratch with a
fresh roll, which counts as 4s toward rule 5's 15s cap. If Task Insight
made that attempt easy, it re-rolls easy and counts as 2s. A victim who
isn't mid-task is unaffected. Phase Step and Second Wind's window block it.
Bots have no task view, so it does nothing to them.

### 10. Push/Trip (Debuff, Aimed)

**Counter-play:** Phase Step blocks it; Second Wind cleanses the stagger;
its 1s duration means even a fully unmitigated hit rarely costs real race
position. **Stacking:** classified as hard control (see below) despite its
short duration — it shares the same post-effect immunity window and
rolling disable-time cap as Freeze, not Slow Field's softer treatment.

## Anti-frustration layer

Two effects in this kit — **Freeze** and **Push/Trip** — are classified as
**hard control**: they stop the victim from acting at all, as opposed to
Slow Field/Blind/Task Scramble, which cost time or precision but never
remove agency outright. The following three rules apply only to hard
control, plus one extra rule added below to close a gap the hard-control
rules don't cover.

**1. Post-effect immunity window: 3 seconds.** The instant a Freeze or
Push/Trip effect ends on a player, they become immune to *any* new
hard-control effect for 3 seconds, regardless of caster. Long enough to
guarantee real, unimpeded recovery movement; short enough that it's not a
standing free pass for the rest of the round.

**2. Diminishing returns across the same 20-second window: -50% on the
2nd, -75% on the 3rd, floor 0.5s.** The immunity window already prevents
back-to-back chaining of the *same* effect from *any* caster, but a
different hard-control type landing right after immunity expires (Freeze,
then later a Push/Trip from someone else) isn't covered by it — this rule
bounds that case across effect types and across multiple attackers without
banning legitimate independent use of the kit by different players.

**3. Rolling hard-control cap: 15 seconds of total disable time per
round.** Once a player has accumulated 15 seconds of combined Freeze +
Push/Trip time in a round, any further hard-control effect that would land
on them is automatically downgraded to a Slow Field-equivalent soft
effect instead of applying. This is the actual ceiling the design
constraint asks for: no matter how many opponents pile on, a player can
never be fully disabled for more than 15 seconds of a round — comfortably
under any plausible round length, so "chain-frozen out of the round"
becomes structurally impossible rather than just unlikely.

**4. Slow Field combined-stack floor: -70% movement speed, hard cap.**
Slow Field and Task Scramble are *not* hard control, so none of the three
rules above touch them — which is exactly the gap flagged below. This
floor is the fix for Slow Field specifically: overlapping zones from any
number of casters combine multiplicatively but never exceed a 70% total
speed reduction, guaranteeing a player can always still move, just slowly.

**5. Task Scramble exposure cap: 15 seconds of total added time per
round.** The equivalent fix for Task Scramble, mirroring rule 3 in spirit
but measured in accumulated time cost rather than disable time, since
Scramble never removes agency, only spends it. Once a player has lost 15
seconds cumulative to Scramble re-rolls in a round, further Scramble casts
against them fail outright (the caster's power-up is consumed with no
effect — telegraphed to them as "target is scramble-immune this round" so
it isn't mistaken for a bug).

## Debuff × buff matrix

Whether an active buff blocks, reduces, or fails to affect an incoming
debuff.

| Debuff ↓ / Buff → | Sprint Boost | Second Wind | Task Insight | Phase Step | Overclock |
|---|---|---|---|---|---|
| **Freeze** | Full | Blocked* | Full | Blocked | Full |
| **Slow Field** | Reduced | Blocked* | Full | Full (area, not blocked) | Full |
| **Blind** | Full | Blocked* | Reduced | Blocked | Full |
| **Task Scramble** | Full | Blocked* | Reduced | Blocked | Full |
| **Push/Trip** | Full | Blocked* | Full | Blocked | Full |

`*` Only while Second Wind's 2.5s immunity window is actually active — it's
a short reactive window, not a standing shield, so "Blocked" here means
"blocked if the timing lines up," not "immune whenever equipped."

Read down the Overclock column: every debuff applies fully against it. By
design, the loadout's most purely-offensive pick carries zero defensive
upside — a genuinely defensive loadout (Second Wind + Phase Step, say) is
supposed to trade offense for real safety, per Q7's requirement that a
defensive build be a viable choice, not a strictly worse one.

## Closest to breaking the "always able to do something" rule

**Slow Field.** It's the one debuff that sits entirely outside the
hard-control safety net (rules 1–3 above) by construction, since it's
classified as soft control. Without the multiplicative-stack floor in
rule 4, a player standing at the overlap of three or four opponents'
zones could face a movement penalty approaching total, with no
per-effect cooldown-based mitigation like Freeze gets, and no built-in
disable-time cap to fall back on — the exact "can't do anything about it"
failure state the constraint forbids, just approached through five soft
hits instead of one hard one. Rule 4's -70% floor exists specifically to
close this; flagging it here because it's a case where the danger comes
from the *interaction* of otherwise-reasonable individual numbers, not from
any single power-up's own stats, and it's the kind of gap that's easy to
miss when reviewing each power-up in isolation rather than in combination.
**Task Scramble** has the same root cause (soft effect, no cross-caster
cap) and gets the same fix in rule 5, added for the same reason rather than
because it was flagged in isolation as dangerous.
