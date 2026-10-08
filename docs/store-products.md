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
| `StreakBuyBack1.luau` | Save your streak (1) | 99 | Keep the streak you just lost. *(Added 2026-10-08; offered only after a loss, never in the store grid.)* |
| `StreakBuyBack2.luau` | Save your streak (2) | 119 | Keep the streak you just lost. *(Added 2026-10-08; offered only after a loss, never in the store grid.)* |
| `StreakBuyBack3.luau` | Save your streak (3) | 149 | Keep the streak you just lost. *(Added 2026-10-08; offered only after a loss, never in the store grid.)* |
| `StreakBuyBack4.luau` | Save your streak (4) | 179 | Keep the streak you just lost. *(Added 2026-10-08; offered only after a loss, never in the store grid.)* |
| `StreakBuyBack5.luau` | Save your streak (5) | 209 | Keep the streak you just lost. *(Added 2026-10-08; offered only after a loss, never in the store grid.)* |
| `StreakBuyBack6.luau` | Save your streak (6) | 239 | Keep the streak you just lost. *(Added 2026-10-08; offered only after a loss, never in the store grid.)* |
| `StreakBuyBack7.luau` | Save your streak (7) | 269 | Keep the streak you just lost. *(Added 2026-10-08; offered only after a loss, never in the store grid.)* |
| `StreakBuyBack8Plus.luau` | Save your streak (8+) | 299 | Keep the streak you just lost. *(Added 2026-10-08; offered only after a loss, never in the store grid.)* |

### Pass (Monetization > Passes)

| Config file | Name | Price (R$) | Description |
|---|---|---|---|
| `Season1Pass.luau` | Season 1 Pass | 199 | Unlock Season 1's premium track: founder cosmetics, coins and power-ups as you win. Only wins until the season ends count. |
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
| `Season1Pass.luau` | 2006972979 | on sale on Roblox, disabled in config |
| `NavigationRound.luau` | 3717313833 | enabled |
| `NavigationPass.luau` | 2021852267 | enabled |

Navigation's art is in `assets/store/navigation-round.png` and
`navigation-pass.png` (the coin offer shares the round's image). Keep
`NavigationRoundCoins.luau` enabled: Validate refuses to boot with Robux
Navigation on sale and no coin round.

Streak buy-back (design-decisions.md Q7): eight products, one per price
tier, all `assetId = 0` and disabled until created. Enable all eight
together: Validate refuses enabled tiers with a gap, so a streak can't be
left without a price. They have no art yet (`imageAssetId = 0`).

## 4. Test (step 13)

Studio's purchase prompts are test purchases and grant nothing real.
Receipt redelivery and real grants get checked on the published place in
step 13.
