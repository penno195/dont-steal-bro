# Don't Steal Bro! — Menu Screens (P6-6)

The store, leaderboards, results and settings screens. They're built from the
P6-2 component library, and each one reads a `Store` of Vide sources. None of
them touches a remote.

| File | Role | Tested |
|---|---|---|
| `UI/StoreScreenLogic.luau`, `UI/BoardLogic.luau`, `UI/ResultsLogic.luau`, `shared/SettingsLogic.luau` | Pure view logic: tabs, rarity, item state, purchase-flow reducer, board view and virtualisation maths, beat sequencing, settings bounds | Headless (`tests/MenuScreens.spec.luau`) |
| `UI/Screens/MenuShell.luau` | The shared frame: title, body, Close at the bottom, B/Escape to close, a loading/empty/error message block | On device |
| `UI/Screens/Store.luau`, `Leaderboards.luau`, `Results.luau`, `Settings.luau` | The four screens | On device |
| `Controllers/MenuController.luau` | Remotes → sources, the purchase flow and its clock, the launcher, one-menu-at-a-time, auto-opening Results | On device |
| `Controllers/SettingsController.luau` | Settings source, applies each setting, throttled `SettingsIntent` | On device |

## Where each screen's data comes from

| Screen | Data | Freshness |
|---|---|---|
| Store | Catalogue, cosmetic/power-up/title registries | Static config |
| | `StoreState` (currency, stock, owned, equipped, passes) | **Live**, targeted; pushed on profile load and after every change |
| | `StorePurchaseResult` + `MarketplaceService.Prompt*PurchaseFinished` | Per request. They only move the spinner; ownership comes from `StoreState` alone |
| Leaderboards | `LeaderboardState` (all-time), `PeriodBoardState` (daily/weekly) | **Cached** server-side, broadcast every 60–120 s, kept by MenuController for the session. There's no request remote. Staleness comes with the entries |
| Results | `RoundRecap` (reason, streak before/after, bounty, streak credit) | **Per round**, targeted, sent on entering Results |
| | Tally: placement, tasks from `TaskQualificationResult`, power-ups from own successful `PowerUpUseResult`s | Counted locally, display only |
| Settings | `SettingsState` | **Live**, targeted; applied locally first, then the server's copy wins |

## Screen notes

- **Layout.** Every screen is one column, 344 reference px wide and as tall
  as the usable rect, centred over an opaque backdrop. The primary action
  sits at the bottom, where the thumb already is: Close/Continue, and on the
  store the Buy button.
- **Store.** Tapping a card only selects it. Only the panel's Buy button
  buys, so a tap while scrolling can never open a prompt. Rarity shows as a
  coloured edge *and* the word. While any purchase is in flight, every Buy
  button is disabled. Failed and Delayed show the flow's message word for
  word, with an OK button.
- **Leaderboards.** The list is virtualised: the canvas is the full height,
  but only the rows in view plus 4 either side are built, keyed by entry so a
  row that stays in view isn't rebuilt. The viewer's own row is pinned under
  the list. If they're off the board it says "Not in the top 100 yet", not a
  made-up rank.
- **Results.** Opens itself once `DecisionStudioController.isActive()` goes
  false. Beats are revealed on the ResultsLogic clock with the streak last,
  and touching the list shows them all at once. A racer whose recap is late
  sees "Confirming your streak". After 6 s that becomes "Couldn't load your
  streak", never an endless spinner. Spectators get no streak beat.
- **Settings.** Steppers instead of sliders, because a precise horizontal
  drag is hard for a thumb and impossible on a gamepad. Toggles spell out
  On/Off. The form isn't shown until the saved values arrive, so the player
  never edits defaults they didn't choose.
- **Launcher.** Store, Boards and Settings buttons sit on the right edge at
  45% height. They're hidden during Loading/Intro/Race/Qualified/DecisionStudio
  and while a menu is open.

## What each setting drives

| Setting | Effect |
|---|---|
| `reducedMotion` | `Env.setReducedMotion`. It adds to Roblox's toggle and can't turn it off |
| `hudScale` | `UIScaleController.setUserMultiplier`, clamped ≥ 1 so targets stay ≥ 44 pt |
| `colorBlindMode` | `Env.colorBlindMode`. Nothing reads it yet (see open items) |
| `musicVolume`, `sfxVolume` | `Volume` of the `Music` / `SFX` SoundGroups in SoundService |
| `voiceEnabled` | `Muted` on the player's own `AudioDeviceInput` |

## Decisions made here

- **No 3D item preview yet.** The prompt asks for a viewport preview. Every
  sellable item is still a placeholder (`enabled = false`, asset id 0), so
  there's no model to render. The panel shows a tile with the rarity edge
  instead. When assets exist, swap the `Preview` frame in `Store.luau` for a
  `ViewportFrame`; nothing else changes.
- **Client copy of the cosmetic slot map.** `StoreEquipIntent` needs the slot
  name, and `CosmeticLogic` lives in ServerScriptService.
  `StoreScreenLogic.slotFor` is a copy, and the spec asserts it matches the
  server's for every category.

## Not verified yet (device pass needed)

- Whether a client may write `AudioDeviceInput.Muted` on its own device. The
  write is in a `pcall`; if it isn't allowed, the setting still saves but does
  nothing.
- Scroll feel of the virtualised board on a low-end Android device with 100
  rows. Watch for pop-in on a hard fling (raise `OVERSCAN` if so).
- The Results slide-in (CanvasGroup) on low-end devices, and its plain
  appearance under reduced motion.
- The launcher's position against Roblox's jump button and chat in both
  orientations.

## Open items handed on

- **Audio routing.** Nothing plays sound yet. Whatever does must route
  through the `Music` and `SFX` SoundGroups, or the volume settings do
  nothing.
- **Colour-blind mode consumers.** The source exists. P6-8's accessibility
  pass decides what extra labels each screen shows when it's on.
- **Loadout editing.** `StoreLoadoutIntent` exists, but no screen sets
  loadout slots yet. It isn't in P6-6's list; it belongs with the pre-round
  lobby.
