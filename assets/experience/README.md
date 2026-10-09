# Experience page: icon and thumbnails

Made 2026-10-06 for next-stages step 14c. Every image is a Studio capture
of the real launch maps, taken in Match_Area under each map's own
lighting preset. The text overlays were drawn in Studio with the game's
own font (Builder Sans ExtraBold) and Theme colours, so they match the
in-game UI.

| File | Size | Shows |
|---|---|---|
| `icon.png` | 512×512 | Two finalists in the Decision Studio over STEAL / SHARE |
| `thumb-1-steal-or-share.png` | 1920×1080 | Three finalists on the Decision Studio podiums: "DON'T STEAL BRO!" and STEAL or SHARE |
| `thumb-2-school-race.png` | 1920×1080 | School atrium. "RACE THROUGH TASKS", 6 players · 4 maps |
| `thumb-3-factory-sabotage.png` | 1920×1080 | Factory at the Emergency Stop. A shove, plus STUNNED and BLINDED labels |
| `thumb-4-museum-final.png` | 1920×1080 | Museum Rotunda T-Rex. "TOP 3 MAKE THE FINAL" |
| `thumb-5-lab-streak.png` | 1920×1080 | Lab reactor core. "BUILD A WIN STREAK", one loss resets it all |

Upload order is the table order: the steal-or-share hero goes first.

## Uploading (owner)

Creator Hub → Creations → *Don't Steal Bro!* → **Configure → Places** →
the start place (the Hub, 96878739507497, marked with a star):

- **Icon:** set the media type to Image, then Change, then `icon.png`.
- **Thumbnails:** add the five `thumb-*` files in order. The page holds
  up to 10.

Both go through moderation before they appear.

## Roblox's thumbnail rules, and how these meet them

- **Text only describes gameplay.** Every caption describes a real
  mechanic. None of them is a promotion or a subjective claim ("best",
  "#1" and the like).
- **No misrepresented mechanics.** The Factory shot first had an ice
  block for Freeze. The game has no ice block, so it was redone with the
  real effect: the 120×28 STUNNED or BLINDED label that
  `EffectLabelController` draws 2.5 studs above the head, at its real
  offset and in its real colour. The poses are set by hand, but no
  effect is shown that the game doesn't have.
- **No enhanced graphics.** These are plain viewport captures. The one
  exception is the Museum shot, which has a light contrast lift
  (ColorCorrection +0.12 contrast, −0.04 brightness), because its
  preset washes out a still image.

## Re-shooting

The staging was throwaway `execute_luau` run in Match_Area's Edit DM.
Each map was cloned into `Workspace.ThumbStage`, and its
`Config/LightingPresets` entry was applied through `LightingLogic.plan`.
The rigs are R6, built with `CreateHumanoidModelFromDescription` from the
owner's avatar with the shirt removed and the body recoloured in Theme
colours. Poses rotate the `Motor6D.C0` joints, with every part
unanchored except the root. The captions are a ScreenGui in StarterGui
inside a 16:9 `UIAspectRatioConstraint` frame. A 1920×830 capture was
centre-cropped to 16:9 and scaled to 1920×1080. All staging was removed
afterwards, and Match_Area's Lighting, StarterGui and camera FOV were
restored.

Camera spots, as (position → look-at):

- Decision Studio hero: (34, 21.5, −50) → (34, 23, −28)
- Icon: FOV 17, (34, 23.4, −60) → (34, 21.4, −36)
- School: (0, 6, 44) → (0, 6, 0)
- Factory: (−40, 6.5, −50) → (−44, 5, −16)
- Museum: (−18, 6.5, 6) → (16, 7, −7)
- Laboratory: (0, 20, 42) → (0, 25, 0)

Studio captures leave out BillboardGuis, so the effect labels were
projected with `WorldToViewportPoint` and drawn on the ScreenGui instead.
