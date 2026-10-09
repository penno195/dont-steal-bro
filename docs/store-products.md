# Store products: creation checklist (next-stages step 11)

Products and passes belong to an experience, so the experience has to
exist first. Owner: the user account (decided 2026-10-03).

## 1. Publish the experience (owner, in Studio)

1. Open the Hub place (`Desktop/Lobby.rbxl`), then **File > Publish to
   Roblox As… > Create new experience**. Owner: your user account. Name:
   *Don't Steal Bro!*. This makes the Hub the start place.
2. In the Creator Dashboard, keep the experience **Private** for now.
3. Open `Match.rbxl`, then **File > Publish to Roblox As…**, pick the
   same experience and **add it as a new place**.
4. Send Claude the **experience (universe) id**, the **Hub place id** and
   the **Match place id**. The place ids are for step 12. Products don't
   need them.

*Done 2026-10-03:* experience (universe) `10769223744`, Hub place
`96878739507497`, Match place `126392243548802`. The Match id was
confirmed from the open Studio file, and the Hub id is the remaining one.
They go into `GameConfig` (`hubPlaceId`, `matchPlaceId`) in step 12,
where teleporting gets tested.

## 2. Create the products (owner, Creator Dashboard)

Creator Dashboard > the experience > **Monetization**. Paste names and
descriptions exactly as below; they match what the in-game store shows.
Each product's icon is `assets/store/<key>.png`, where `<key>` is the
`key` in its config file (e.g. `currency-small.png`). The icons come from
`scripts/make-store-icons.ps1`; re-run it after changing the art.
The same file is the in-game store picture: each config's `imageAssetId`
is that PNG uploaded as an Image (Studio MCP `upload_image`, PNGs served
from localhost). Coin offers have no Dashboard entry but get a picture the
same way. After changing the art, re-upload and paste the new id.

### Developer Products (Monetization > Developer Products)

| Config file | Name | Price (R$) | Description |
|---|---|---|---|
| `CurrencySmall.luau` | Small Coin Pouch | 79 | 75 coins. The same coins you earn from playing - these just arrive sooner. |
| `CurrencyLarge.luau` | Large Coin Chest | 249 | 250 coins. The same coins you earn from playing - these just arrive sooner. |
| `SprintBoostStock.luau` | Sprint Boost x10 | 249 | Ten Sprint Boosts for your loadout. Also earned free from Studio wins and found on every map. |
| `StarterLoadoutBundle.luau` | Starter Loadout Bundle | 349 | Five each of Sprint Boost, Slow Field and Push-Trip. Every one of them is also earned free by playing. |
| `NavigationRound.luau` | Navigation | 99 | A path to your nearest unfinished station, for the rest of this round. *(Added 2026-10-08; sold only from the in-match toggle.)* |
| `StreakBuyBack1.luau` | Save Your Streak (1) | 99 | Lost your streak of 1? Buy it back and carry on from 1. *(Added 2026-10-08; offered only after a loss, never in the store grid. Icon: `assets/store/streak-buy-back-1.png`.)* |
| `StreakBuyBack2.luau` | Save Your Streak (2) | 119 | Lost your streak of 2? Buy it back and carry on from 2. *(Added 2026-10-08; offered only after a loss, never in the store grid. Icon: `assets/store/streak-buy-back-2.png`.)* |
| `StreakBuyBack3.luau` | Save Your Streak (3) | 149 | Lost your streak of 3? Buy it back and carry on from 3. *(Added 2026-10-08; offered only after a loss, never in the store grid. Icon: `assets/store/streak-buy-back-3.png`.)* |
| `StreakBuyBack4.luau` | Save Your Streak (4) | 179 | Lost your streak of 4? Buy it back and carry on from 4. *(Added 2026-10-08; offered only after a loss, never in the store grid. Icon: `assets/store/streak-buy-back-4.png`.)* |
| `StreakBuyBack5.luau` | Save Your Streak (5) | 209 | Lost your streak of 5? Buy it back and carry on from 5. *(Added 2026-10-08; offered only after a loss, never in the store grid. Icon: `assets/store/streak-buy-back-5.png`.)* |
| `StreakBuyBack6.luau` | Save Your Streak (6) | 239 | Lost your streak of 6? Buy it back and carry on from 6. *(Added 2026-10-08; offered only after a loss, never in the store grid. Icon: `assets/store/streak-buy-back-6.png`.)* |
| `StreakBuyBack7.luau` | Save Your Streak (7) | 269 | Lost your streak of 7? Buy it back and carry on from 7. *(Added 2026-10-08; offered only after a loss, never in the store grid. Icon: `assets/store/streak-buy-back-7.png`.)* |
| `StreakBuyBack8Plus.luau` | Save Your Streak (8+) | 299 | Lost a streak of 8 or more? Buy it back and carry on from where you were. *(Added 2026-10-08; offered only after a loss, never in the store grid. Icon: `assets/store/streak-buy-back-8-plus.png`.)* |

### Pass (Monetization > Passes)

| Config file | Name | Price (R$) | Description |
|---|---|---|---|
| `Season1Pass.luau` | Season 1 Pass | 199 | Unlock Season 1's premium track: founder cosmetics, coins and power-ups as you win. Only wins until the season ends count. |
| *(Replaced 2026-10-09.)* | | | The monthly pass is now the `SeasonPass.luau` developer product (3717513986), bought again each month. Take this game pass off sale. |
| `NavigationPass.luau` | Unlimited Navigation | 899 | Switch on Navigation in every round, for good. Shows a path to your nearest unfinished station. *(Added 2026-10-08.)* |

Create the pass and put it **on sale** (a pass with no price can't be
bought). It stays `enabled = false` in config, and Season 1 stays
disabled, until the season questions in `next-stages.md` are answered.
Nobody can find it in-game while it's disabled.

## 3. Wire the ids in (Claude)

Send Claude each product's id, copied from its dashboard row. Claude then:

- sets `assetId` in each config file and flips the four developer
  products to `enabled = true`
- sets the pass's `assetId` and leaves it disabled
- runs the validator and tests, then commits

The price in each config is display only. Roblox charges the dashboard
price. If the two disagree, the store shows the wrong number, so change
both together.

*Done 2026-10-03:*

| Config file | Id | State |
|---|---|---|
| `CurrencySmall.luau` | 3716318892 | enabled |
| `CurrencyLarge.luau` | 3716319109 | enabled |
| `SprintBoostStock.luau` | 3716319307 | enabled |
| `StarterLoadoutBundle.luau` | 3716319616 | enabled |
| `Season1Pass.luau` (removed) | 2006972979 | old game pass, replaced by the monthly developer product below; take off sale on Roblox |
| `NavigationRound.luau` | 3717313833 | enabled |
| `NavigationPass.luau` | 2021852267 | enabled |
| `StreakBuyBack1.luau` | 3717322114 | enabled |
| `StreakBuyBack2.luau` | 3717322285 | enabled |
| `StreakBuyBack3.luau` | 3717322388 | enabled |
| `StreakBuyBack4.luau` | 3717322551 | enabled |
| `StreakBuyBack5.luau` | 3717322840 | enabled |
| `StreakBuyBack6.luau` | 3717322985 | enabled |
| `StreakBuyBack7.luau` | 3717323070 | enabled |
| `StreakBuyBack8Plus.luau` | 3717323241 | enabled |
| `SeasonPass.luau` | 3717513986 | enabled (2026-10-09); purchases refused while no season is live |

Navigation's art is in `assets/store/navigation-round.png` and
`navigation-pass.png` (the coin offer shares the round's image). Keep
`NavigationRoundCoins.luau` enabled: Validate refuses to boot with Robux
Navigation on sale and no coin round.

Streak buy-back (design-decisions.md Q7): eight products, one per price
tier, all `assetId = 0` and disabled until created. Enable all eight
together: Validate refuses enabled tiers with a gap, so a streak can't be
left without a price. Art: `assets/store/streak-buy-back-*.png` (one per tier, made by make-store-icons.ps1); the in-game image ids are already set. Upload the same file as each product's icon.

## 4. Test (step 13)

Studio's purchase prompts are test purchases and grant nothing real.
Receipt redelivery and real grants get checked on the published place in
step 13.
