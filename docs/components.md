# Don't Steal Bro! — Component Library (P6-2)

The reusable UI pieces every screen is built from. They're built on
**Vide** (`centau/vide@0.4.1`), on top of the P6-1 foundation
(`docs/ui-foundation.md`).

```lua
local C = require(script.Parent.Parent.Components) -- src/client/UI/Components
C.Button({ label = "Ready", onActivate = ready })
```

| File | Role | Tested |
|---|---|---|
| `ComponentLogic.luau` | Pure: state precedence, variant colours, hit-area size, ring maths, number formatting, tab stepping, toast queue | Headless (`tests/ComponentLogic.spec.luau`) |
| `Env.luau` | Vide sources for scale, input mode and reduced motion; `animate`, `duration`, `minTouchRef` | On device |
| `Base.luau` | `interactive` (the one hit area), `text`, focus ring, spinner, corner, padding | On device |
| `Icons.luau` | Icon registry by key (glyph stand-ins until there's art) | On device |
| `Button`, `IconButton`, `Panel`, `Modal`, `ProgressBar`, `CountdownRing`, `Toast`, `TaskCard`, `PlayerRow`, `CurrencyPill`, `TabBar` | The components | Gallery screenshot |
| `UI/Screens/ComponentGallery.luau` | Every component in every state, on one screen | Screenshot |

Components create Vide effects and cleanups, so call them inside a Vide
scope (`vide.mount`/`vide.root`), as the gallery, `Modal.open` and the
toast host do. Called outside one, Vide errors.

## Rules every component follows

- **Sizing.** Contents are sized in reference px from `Theme` tokens, under a
  root with `attachScale`. Fills and fractions use Scale. This is the P6-1
  reading of "Scale, never Offset"; see ui-foundation.md "Scale vs Offset".
- **44-point touch targets.** Anything tappable goes through
  `Base.interactive`. Its hit area is `max(visual, Layout.minTouchRef(scale, 44))`.
  The hit area grows and the visual doesn't. The spec checks that this renders
  at ≥ 44 points across the whole scale clamp.
- **States.** `ComponentLogic.resolveState` ranks them: disabled > loading >
  pressed > hovered > idle. Only idle, hovered and pressed fire the action.
  Hover only counts with a mouse, because on touch Roblox fires `MouseEnter`
  with no matching leave. Pressed also shrinks the visual to 0.96.
- **Focus.** Every interactive element is `Selectable` (unless disabled) and
  has a `SelectionOrder` (the `order` prop). Roblox's default selection image
  is replaced by a 3px white `FocusRing` that follows the visual's corner
  radius. A Modal is a `SelectionGroup` that stops at every edge, so focus
  can't leave it.
- **Reduced motion.** It turns on if *either* `GuiService.ReducedMotionEnabled`
  is set or `Env.setReducedMotion(true)` is called. Springs snap, the spinner
  becomes "...", and the countdown pulse stops.
- **Text.** `Base.text` uses TextScaled with a `UITextSizeConstraint` built
  from the type scale's `size` and `min`.
- **Colour is never the only cue.** Every fill/ink pair passes WCAG AA in the
  spec. Selected tabs, toast kinds, task status and countdown urgency each
  also change an icon, weight, label or shape.

### New tokens

`primary` (#7C4DEB), `onPrimary`, `onDanger`. Brand purple fails AA as a
button fill with either ink (4.23:1 with white, 4.31:1 with dark ink), so
`primary` is brand darkened just enough to reach 5.10:1 with white. Danger
takes dark ink (5.24:1), because white on it is only 3.49:1.

## Device review (gallery)

1. Set the `UIComponentGallery` attribute on `ReplicatedStorage` to `true`.
2. On each `perf-budget.md` §3 device, screenshot both orientations. Scroll
   if it doesn't fit.
3. Check the following:
   - Every cell's caption matches what it shows.
   - The disabled cells look the same whatever their variant.
   - The loading cells spin, or show "..." under reduced motion.
   - The **ring · live 20s** cell steps calm → warning (≤10) → critical (≤5,
     pulsing, "!") and starts again. The ring must drain clockwise from
     12 o'clock with no gap or overlap at 6 o'clock.
   - Hover and press have to be done by hand: mouse over and press a button,
     then tap one on a phone.
   - With a gamepad, the white focus ring should move through the cells in
     `order` sequence, and L1/R1 should switch tabs.
   - **Open modal**: the dim covers the notch strip, B, the X and tapping
     outside all dismiss, and focus can't escape. **Toast me** stacks at the
     top.
4. Turn on Roblox's Reduced Motion setting and look again.

## Not verified yet (device pass needed)

- **Ring halves.** The UIGradient-on-UIStroke mask, and whether the
  gradient's rotation direction matches `ComponentLogic.ringRotations`. If
  the arc drains the wrong way, swap the halves' rotations.
- **Gamepad press visual.** Whether `InputBegan` fires with `ButtonA` on a
  selected button (the `Activated` action works either way).
- **Icon glyphs.** Emoji stand-ins rely on Roblox's fallback fonts; some
  could render as boxes on older Android devices.
- **Outer focus stroke.** Whether `BorderStrokePosition.Outer` gets clipped
  inside `ClipsDescendants` parents such as the gallery's scrolling frame.

## Open items handed on

- ~~**Settings store.**~~ Done in P6-6: `SettingsController` calls
  `Env.setReducedMotion` and sets `Env.colorBlindMode` (docs/menu-screens.md).
- **Icon art.** Fill in `image`/`rect` per key in `Icons.luau`. No component
  needs to change.
- **One modal at a time.** A second `Modal.open` replaces the first.
