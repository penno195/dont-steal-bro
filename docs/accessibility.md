# Don't Steal Bro! — Accessibility Pass (P6-8, part 1)

A pass over every client UI against the five P6-8 requirements. Most
of the groundwork landed with P6-1 to P6-7: the Steal/Share pair is
CVD-simulated in CI, every component has `SelectionOrder`, and reduced
motion collapses every transition. This pass found the places that
slipped through, fixed them, and records what can't be fixed.

The onboarding flow and the payoff explainer are P6-8 part 2.

## 1. Colour-blind-safe signalling

**Rule:** every state has a non-colour cue: a shape, an icon, a word
or a stroke weight. Colour-blind mode (the Settings toggle, stored in
`Env.colorBlindMode`) adds *words* where the only other cue is an icon.
It never repaints anything.

| Where | State | Non-colour cue |
|---|---|---|
| Decision Studio | Steal vs Share | Diamond vs pill silhouette, a different icon, and the label always shown. The pair keeps an OKLab distance of ≥ 0.29 under all four simulations (`tests/Theme.spec.luau`). |
| Decision Studio | Seat verdict | The word WINS / LOSES in its own chip. |
| Decision Studio | Result tone | The headline copy says win or loss. |
| Race HUD | Qualification line | Check / ! / down icon plus a signed gap. **New:** colour-blind mode shows IN / EDGE / OUT in place of the icon (`HudLogic.lineWord`). |
| Race HUD | Buff vs debuff chip | A pill vs a square, plus the category icon. |
| Race HUD | Status-effect screen edge | Which sides it's on, and hard control pulses (`HudLogic` edge table). |
| Countdown ring | Urgency | The number, plus a "!" suffix when critical. |
| Map vote board | Your vote / tied / random pick / winner | **New:** each has its own stroke weight (2 / 3 / 5 / 5) and a tag with a symbol and a word: "✓ Your vote", "Tied", "🎲 Random pick", "★ WINNER". The fallback banner is prefixed "⚠". Colours now come from `Theme` (mobile-audit #8). |
| Store | Purchase flow | ✓ / … / ⚠ prefix and the message text. |
| Store | Rarity | The rarity name is printed on the tile. |
| Leaderboards | Stale data | "⚠" plus a sentence. |
| Toasts | Kind | A different icon per kind. |
| Task views | Good / bad feedback | Status-line text plus an icon. |

## 2. Reduced motion

Two inputs, either of which turns it on: Roblox's
`GuiService.ReducedMotionEnabled` and the in-game toggle.
`Env.animate` and `Env.duration` snap every transition. Looping and
flashing effects are stopped explicitly.

**Fixed in this pass:**

- **Countdown ring pulse.** `Env.animate` drops the spring but keeps
  following its target, so a target that alternated every second
  became a hard 8% jump every second: worse than the smooth beat it
  replaced. The ring now skips the pulse entirely under reduced
  motion, and "!" plus colour carry the urgency.
- **Tie roulette on the vote board.** At its fastest it switched cards
  20 times a second. Under reduced motion it's skipped: the tied cards
  hold a static highlight and the winner's tint is set without a tween.
  The banner and the "Tied" tags already say the pick was random among
  the tied maps.
- **Nametag Pulse and Rainbow.** Under reduced motion both fall back
  to the static Glow. `NametagController` rebuilds the tags when the
  setting flips (`Env.observe`).

**Already compliant:** the Race HUD's hard-control edge pulse,
Decision Studio's choice reveal, and every component transition.

The game has no screen shake and no camera effects, so there was
nothing to remove there. Any future shake must check
`Env.reducedMotion()`: see the checklist addition below.

## 3. Text scaling

Every label is `TextScaled` inside a fixed box. Raising `MaxTextSize`
does nothing to text that already fills its box, and raising
`MinTextSize` just clips it. So text scales with the whole UI, through
the HUD scale, and the boxes grow with it.

**New:** Roblox's own `GuiService.PreferredTextSize` feeds the same
multiplier (`SettingsLogic.effectiveHudScale`): Large 1.1×, Larger
1.2×, Largest 1.3×. It can raise the player's "Text and HUD size"
setting but never lower it, the same way reduced motion ORs with
Roblox's toggle. `UIScaleController` recomputes when it changes.

## 4. No information by sound alone

Audited every `Sound` use. The only gameplay sound is
`TaskViewBase`'s feedback cue, and it always fires with a visual
status-line flash. No countdown, reveal or alert is audio-only.

## 5. Controller navigation

Every interactive element already had a `SelectionOrder`. But order
only matters once something has focus, and only `Modal` and
`TaskViewBase` ever set focus. So on a gamepad the menus and the vote
board opened with nothing selected, and the D-pad did nothing until
the player found Roblox's UI-select button.

**New: `UI/Focus.luau`.** `Focus.enter(root)` focuses the root's
lowest-order selectable element when the input is a gamepad. It does
this again if a controller is picked up while the screen is open, and
the exit function it returns hands focus back on close. It's used by:

- `MenuShell`, which covers Store, Leaderboards, Results and Settings.
  If the body is still loading, focus lands on Close, and D-pad up
  reaches the content once it arrives.
- The vote board. Its cards now have `SelectionOrder = index`.
- `TaskViewBase`, which already did this and now shares the helper.

Per-screen order:

| Screen | Order |
|---|---|
| Menus | Body content (tabs, then list, top to bottom), then Close (1000). B / Escape also closes. |
| Settings | Rows top to bottom, then Reset (200), then Close. |
| Vote board | Cards top to bottom. |
| Task views | The task's own grid (`InputAdapters` wires `NextSelection*`), trapped in a `SelectionGroup`. |
| Modal | Trapped in the card: primary action first. B dismisses. |
| Decision Studio | Steal / Share are held with Q/E or X/Y, not focus-and-A (a hold can't be a focus action). Chat uses Roblox's own focus. |
| Race HUD | Power-up use is a bound action. Nothing else is interactive. |

## What can't be made accessible, and why

1. **Screen readers.** Roblox exposes no accessibility name or
   announcement API for experience GUIs (none in the pinned
   `globalTypes.d.luau`). A blind player can't be served by anything
   this codebase controls.
2. **Timed and reaction tasks.** Pressure Valve needs a timed tap, and
   Code Playback shows digits briefly to memorise. The timing *is* the
   task in a race. Reduced motion keeps Code Playback's digit flashes,
   because they're the information, not decoration. No UI change can
   help here. The only lever is the task pool, so when new tasks are
   added, weigh including some that aren't reaction-timed.
3. **Voice in the Decision Studio.** Roblox voice has no captions.
   Text chat runs alongside it in the same phase, so nothing *needs*
   voice. But a deaf player can't follow a rival who only talks.
4. **Text scaling beyond 1.3×.** Every screen is laid out and
   touch-audited up to `HUD_SCALE_MAX`. Past that, the portrait column
   overflows a phone. Largest maps to exactly the cap.
5. **Vision-category power-ups.** Their effect *is* reduced vision.
   Making them readable to a low-vision player would remove the
   mechanic. The HUD still names the effect and its timer.
6. **Roblox core UI** (top bar, chat window, system menus) follows
   Roblox's own settings, not ours.
7. **Still pending, not impossible:** the raw-Instance Vote board,
   Pressure Valve and Fuse Rewire have no type-scale minimum text size
   (mobile-audit #6). They'll get one with their migration onto the
   component library.

## Checklist additions

These three items are now in `docs/mobile-checklist.md`:

- [ ] Any repeating or alternating animation checks
      `Env.reducedMotion()` itself. `Env.animate` alone makes an
      alternating target *snap*, which is worse.
- [ ] Any state shown by colour also has a shape, icon, word or
      stroke-weight difference. If it's icon-only, colour-blind mode
      shows a word.
- [ ] A new full-screen or sheet UI calls `Focus.enter` (or mounts
      through `MenuShell`).
