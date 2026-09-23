# Don't Steal Bro! — UI Foundation (P6-1)

The decisions every screen inherits: tokens, the global scale, safe areas,
input mode, and where on a phone things are allowed to go.

| File | Role | Tested |
|---|---|---|
| `src/client/UI/Tokens.luau` | Raw tokens: hex colours, spacing, radii, type scale, elevation, display-order bands, motion | Headless (`tests/Theme.spec.luau`) |
| `src/client/UI/ColorVision.luau` | WCAG contrast, Machado-2009 CVD simulation, OKLab distance | Headless |
| `src/client/UI/Layout.luau` | Scale maths, usable rect, touch-target padding, thumb zones | Headless |
| `src/client/UI/Theme.luau` | Tokens as `Color3`/`UDim`/`Font`, plus `applyText` | On device |
| `src/client/Controllers/UIScaleController.luau` | Live scale, usable rect and input mode; `attachScale`; `createScreen` | On device |
| `src/client/UI/Screens/LayoutHarness.luau` | Device test screen | Screenshot |

UI code requires **Theme**, never Tokens directly.

## Scale vs Offset

Architecture §5.1 says "Scale, not Offset", and §5.2 adds a global `UIScale`
that lets you "author once". Taken literally, those two conflict: a `UIScale`
also multiplies Scale-sized children, so a root sized `fromScale(1, 1)` under
a 0.8 `UIScale` covers only 80% of the screen. The split used here:

- **Regions** (where a cluster sits on screen) are positioned in **Scale**,
  as fractions of the usable rect: `Layout.THUMB_ZONES`, or a HUD corner.
  Regions don't get a `UIScale`.
- **Contents** (buttons, cards, text) are sized in **reference pixels**
  taken from the tokens, under a root that has `attachScale(root)` on it.

**For P6-2:** its prompt says "all sizing in Scale, never Offset". Read that
as "never a hand-typed Offset". Offsets taken from `Theme.spacing` under
`attachScale` are the intended way to size things, and they're what makes
the 44-point touch target actually hold.

## Global scale

`scale = clamp(shortAxis / 360, 0.75, 2.0)`, where `shortAxis` is the
**shorter side of the usable rect**. The rect is taken after insets, so a
notch doesn't count as space the UI can use.

- **Why the short axis.** It runs out first in either orientation, and
  rotating the phone doesn't change the scale.
- **Why 360.** Mobile-first: the smallest phone we support is the reference,
  so phones sit near 1.0 and bigger screens only ever scale up. The
  architecture doc's example (1280×720, clamp 0.6–1.5) would put a 390-point
  landscape phone at 0.54, which then gets clamped up to 0.6. At that point a
  layout designed for 720 points overflows the screen by about 10%.
- **Why the 0.75 floor.** A 270-point short axis still fits. Below that the
  layout crops at the edges instead of shrinking text past legibility.
- **Why the 2.0 ceiling.** The ceiling is hit at a 720-point short axis
  (tablets, desktop). Beyond that, the UI keeps its size and bigger screens
  get more space around it.
- **Touch targets.** A hit area of `Layout.minTouchRef(scale, 44)` reference
  pixels renders at 44 points: 44 at scale 1 and 59 at the floor. Pad the
  hit area to that size; the visual can stay smaller.

## Safe areas

These insets come from the notched-screen release (see Sources below):

- **Interactive UI:** `ScreenInsets = CoreUISafeInsets`. This keeps content
  clear of hardware cutouts and the Roblox top bar. It's Roblox's default,
  but `createScreen` sets it explicitly anyway.
- **Backdrops and scrims:** `ScreenInsets = None` and
  `ClipToDeviceSafeArea = false` (`createScreen(name, { fullBleed = true })`).
  This way a modal's dim layer covers the notch strip too. Never put a
  button on a full-bleed screen.
- **The usable rect** is `GuiService:GetInsetArea(Enum.ScreenInsets.CoreUISafeInsets)`,
  falling back to viewport minus `GetGuiInset()` if that comes back empty.
  It updates on `ViewportSize`, `TopbarInset` and `SafeZoneOffsetsChanged`.

## Input mode

The input mode comes from `UserInputService.PreferredInput` and updates live
through its property-changed signal. `TouchEnabled` is not used because it
reports hardware, not use: it's true on a touchscreen laptop driven by a
mouse. The controller exposes the mode as `getInputMode()` and
`observeInputMode(fn)`, and exposes scale and usable rect the same way. The
reactive surface is plain `observe(fn) -> disconnect`, so it works with
whichever UI framework P6-2 picks.

## Steal / Share accents

| | Steal | Share |
|---|---|---|
| Fill | `#FFB020` amber | `#3A5BD9` blue |
| Label ink | `#12151C` (contrast 9.99:1) | `#FFFFFF` (5.71:1) |
| Silhouette | Diamond (sharp) | Pill (round) |
| Icon key | `grab-hand` | `open-hands` |

The pair was **tested against protanopia, deuteranopia, tritanopia and full
achromatopsia**, using Machado et al. (2009) matrices at full severity,
applied in linear RGB. It never drops below an OKLab distance of 0.29 (the
greyscale case is the smallest). The luminance ratio between the two is
3.1:1, so they stay distinct even in a greyscale screenshot. As a control, a
red/green pair (`#D93A3A`/`#3AA35A`) collapses to 0.05 under deuteranopia,
and the spec asserts that it does. The thresholds live in `Tokens.contrast`,
and every text/surface pairing is checked for WCAG AA.

## Thumb zones

`Layout.THUMB_ZONES` describes a right-handed grip, with zones given as
fractions of the usable rect:

- **Landscape:** Roblox owns the bottom-left (the thumbstick) and the
  bottom-right corner (the jump button). **Primary** actions go left of and
  above the jump button. **Info** goes top-centre.
- **Portrait:** Primary is the lower-middle, above the jump button. The top
  sixth is for info only.

The spec asserts that no Primary or Secondary zone overlaps a reserved one.
`Layout.hitsReserved(rect, usable)` lets a screen check its own buttons the
same way.

## Device test (harness)

1. In Studio, or from the server console on a test server, set the
   `UILayoutHarness` attribute on `ReplicatedStorage` to `true`.
2. On each device in `perf-budget.md` §3, screenshot the result in both
   orientations. Check four things:
   - **Safe area.** The thick green outline (the safe area as the engine
     lays it out) and the thin white one (the controller's computed rect)
     should coincide. If they don't, `readUsableRect`'s coordinate
     assumption is wrong on that device.
   - **Reserved zones.** The red reserved zones should cover Roblox's real
     thumbstick and jump button.
   - **Touch target.** The purple "44pt" square should measure about 7 mm on
     a phone. The readout shows the screen size in mm, so you can check.
   - **Scale.** The "100 ref px" ruler should measure 100 × scale screen
     points.
3. Set the attribute back to `false` to remove the harness.

## Not verified yet (device pass needed)

- **Harness coordinates.** Whether `GetInsetArea` and `AbsolutePosition`
  share coordinate spaces on every platform. DevForum threads report
  inconsistencies; the harness's two outlines are the test.
- **Text under `UIScale`.** Whether `UITextSizeConstraint` limits apply
  before or after `UIScale`. This matters for P6-2's text sizing.
- **Control placement.** Roblox's control positions vary by screen size and
  client version. The zones are approximations until they're screenshot.

## Open items handed on

- **Orientation.** CLAUDE.md's Ground Rule 3 says portrait, but nothing in
  the repo sets `ScreenOrientation`. Roblox phones default to landscape. The
  zones and scale handle both, but which one the game ships in is an owner
  decision.
- **Reduced motion.** `GuiService.ReducedMotionEnabled` exists (in the pinned
  types) for P6-2's reduced-motion setting to read or combine with.
- **Icon atlas.** Icon art (the atlas the Steal/Share icon keys point to)
  belongs to P6-2.

## Sources

- [Notched Screen Support — full release](https://devforum.roblox.com/t/notched-screen-support-full-release/2074324)
- [UserInputService.PreferredInput](https://create.roblox.com/docs/reference/engine/classes/UserInputService#PreferredInput)
- [ScreenGui reference](https://create.roblox.com/docs/reference/engine/classes/ScreenGui)
