# Mobile Screen Checklist

Run against every new or changed screen before it merges. The P6-7
audit that produced it is in `docs/mobile-audit.md`.

## Code checks (grep-able)

- [ ] The ScreenGui comes from `UIScaleController.createScreen`: no
      `Instance.new("ScreenGui")` and no `IgnoreGuiInset`.
- [ ] `fullBleed = true` only on a screen with nothing interactive on it
      (scrims and backdrops).
- [ ] Every tappable element goes through `Base.interactive` or a `C.*`
      component. For a raw `TextButton`, justify it in a comment and
      size it to at least `Env.minTouchRef()`.
- [ ] Contents sit under a root with `attachScale`, sized from
      `Theme.spacing`/`Theme.type`, with no hand-typed offsets.
- [ ] Text uses `Base.text` or `Theme.applyText`, never a bare
      `TextScaled` without a min constraint.
- [ ] No state depends on `MouseEnter`/`MouseLeave` except when gated on
      `PreferredInput == KeyboardAndMouse`.
- [ ] Any list that can pass about 30 rows is virtualised (`BoardLogic`).

## Device checks

Use the LayoutHarness viewports, or a real phone.

- [ ] **Portrait, 360×640:** the primary action is in the bottom third
      and reachable by one thumb.
- [ ] **Landscape, about 390 tall:** nothing is cut off, and anything
      taller than the screen scrolls or reflows.
- [ ] **Notched phone:** nothing interactive sits under the cutout, the
      home indicator, or the Roblox top-bar buttons.
- [ ] **Smallest text:** legible at scale 1.0 on the 360-pt reference.
- [ ] **Thumb accuracy:** no action needs a target under 44 pt, a
      precise drag endpoint, or two fingers.
- [ ] **On-screen keyboard:** if the screen can be up while the player
      is typing, open the keyboard and confirm the primary action is
      still visible.
- [ ] **Longest realistic list:** scroll it on a low-end Android phone
      with no dropped frames.
- [ ] **Reduced motion:** any repeating or alternating animation checks
      `Env.reducedMotion()` itself (`Env.animate` alone makes an
      alternating target *snap*, which is worse). See `accessibility.md`.
- [ ] **Colour:** every state shown by colour also differs in shape,
      icon, word or stroke weight.
- [ ] **Gamepad:** the screen calls `Focus.enter` (or mounts through
      `MenuShell`), so the D-pad works the moment it opens.
