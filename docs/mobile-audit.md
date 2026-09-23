# Don't Steal Bro! — Mobile Usability Audit (P6-7)

An audit of every client UI against the eight P6-7 criteria. The
repeatable version is `docs/mobile-checklist.md`.

## Method

Screens built on the component library (MenuShell, Store, Leaderboards,
Results, Settings, RaceHUD, DecisionStudio, TaskViewBase, Modal, Toast)
were checked at the seams every one of them shares:

- `Base.interactive`, which pads every hit area to
  `Layout.minTouchRef(scale, 44)` and gates hover on `KeyboardAndMouse`.
- `UIScaleController.createScreen`, which applies the safe-area insets.
- `Theme.applyText` / `Base.text`, which apply a `UITextSizeConstraint`
  with the token minimum.

Elements were then read one by one wherever a file bypasses these
seams: a raw `TextButton`, a raw `ScreenGui`, `IgnoreGuiInset`, or a
hand-typed offset under 44. The older raw-Instance UIs (VoteBoard,
PressureValve, FuseRewire) were read in full.

"Landscape phone" below means a usable rect about 390 pt tall, the
tightest short axis a phone gives. The target is still portrait-first,
but nothing locks orientation, so landscape has to work too.

## Findings

| # | Screen | Element | Issue | Sev | Fix |
|---|---|---|---|---|---|
| 1 | Map vote board | Sheet, last card | Raw `ScreenGui` with `IgnoreGuiInset` and the sheet flush to the bottom edge, so the bottom card sits under the home indicator. | **High** | **Fixed.** The sheet is on a `createScreen` safe-area screen and the dim is on a separate full-bleed one. |
| 2 | Map vote board | Whole sheet | Four cards need about 512 px, more than a landscape phone's height, so the title, timer and first card render off the top. | **High** | **Fixed.** The sheet is capped at the screen height and the list is a `ScrollingFrame`. It never scrolls in portrait. |
| 3 | Pressure Valve | Tap zone | Centred at 72% of the screen height: its bottom lands at about 441 on a 390-pt landscape phone, so the tap zone is partly off screen. Also uses `IgnoreGuiInset`. | **High** | **Fixed.** Moved to a safe-area screen and anchored to the bottom with a `spacing.md` margin. |
| 4 | Fuse Rewire | Fuse tray | Same as #3 (the bottom lands at about 395), and uses `IgnoreGuiInset`. | **High** | **Fixed** the same way. Hit tests now share the coordinate space that `InputAdapters.pointOf` relies on. |
| 5 | Decision Studio | Steal / Share hold buttons | If a player is still typing when Choose opens, the on-screen keyboard covers the bottom of a portrait screen, which is exactly where the hold buttons are. | **High** | **Fixed.** `DecisionLogic.keyboardLift` (unit-tested) raises the decide stack above the keyboard's top edge, capped at 60% of the height. |
| 6 | Vote board, Pressure Valve, Fuse Rewire | All | No global `UIScale` and no Theme type scale: `TextScaled` without a min constraint, and targets don't grow on tablets. | Medium | Migrate the two task views onto `TaskViewBase` with `InputAdapters.Tap`/`Drag` (already planned in `task-views.md`), and rebuild the board from `C.*` components. |
| 7 | Fuse Rewire | Drag | Its own drag code: no off-screen cancel, no ghost, no gamepad pick. `InputAdapters.Drag` handles all three. | Medium | Same migration as #6. |
| 8 | Vote board | Colours | Hard-coded `COLORS` table, so it ignores the theme and the colour-blind mode. The tie and winner highlights are colour-only apart from their tag text. | Medium | **Fixed in P6-8.** Colours come from `Theme`, and each highlight has its own stroke weight and a symbol-and-word tag (`accessibility.md`). |
| 9 | Modal | Tap-outside catcher | The catcher is on the safe-area screen, so a tap in the notch strip isn't treated as a dismiss (the full-bleed scrim isn't `Active`). | Low | Harmless: a missed dismiss, never a wrong action. Leave it unless a playtest notices. |
| 10 | Store | Item grid | Not virtualised: every item in a category is built. That's fine at the current catalogue size. | Low | Virtualise with `BoardLogic` (as Leaderboards does) once any category passes about 60 items. |
| 11 | All (text) | Caption at the 0.75 scale floor | The `UITextSizeConstraint` minimum is in reference pixels, so under `UIScale` a caption can render at 7.5 pt. | Low | Only happens on a short axis under 360 pt, which is below the smallest supported phone. Acceptable. |

### Passes worth recording

- **Touch targets:** every `C.*` component, the Settings toggles and
  steppers (56 px rows), and the Decision Studio hold buttons meet 44 pt
  after scaling. `Base.interactive` enforces this centrally.
- **Hover:** hover state is shown only when `PreferredInput` is
  `KeyboardAndMouse`. There is no tap-to-hover stuck state.
- **Scroll performance:** Leaderboards virtualises its 100 rows. Results
  and Settings lists are short and fixed.
- **Safe areas:** every screen made with `createScreen` keeps interactive
  UI out of the notch and top bar, and only scrims use `fullBleed`.

## On-device check still needed

`UserInputService.OnScreenKeyboardPosition` is assumed to be in the same
screen space as `GuiObject.AbsolutePosition`, the same convention the
chat-window rect uses. Verify this on a phone: open chat in Negotiate,
keep the keyboard up into Choose, and confirm both hold buttons sit
fully above it. If they sit about 36 px low, subtract the top-bar
inset in `DecisionStudioController.watchKeyboard`.

## Issues expected to recur

1. **A screen built with a raw `ScreenGui` and `IgnoreGuiInset`** instead
   of `createScreen`. Every pre-P6 UI did this. It is the pattern older
   Roblox tutorials teach, so new code will keep reaching for it.
2. **Fixed-height content sized in portrait** that overflows a
   landscape phone's short axis. Every stack is tested upright, and
   the 390-pt landscape height is easy to forget.
