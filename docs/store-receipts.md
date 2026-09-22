# Don't Steal Bro! — Store, Receipts and Pay-to-Win (P4-5)

What the store is made of, the exact guarantee `ProcessReceipt` gives,
how to break it on purpose in Studio, and a plain answer on whether the
starting-power-up design crosses the pay-to-win line.

## 1. The pieces

| File | What it owns |
|---|---|
| `src/shared/Config/Store/` | The catalogue. One file per purchasable thing (Ground Rule 2). |
| `src/shared/Config/Validate.luau` | `StoreItemDef`, `StoreConfig`, and the boot-time rules — including the ones that enforce design-decisions.md Q8. |
| `src/server/StoreLogic.luau` | Pure: receipt classification, the PurchaseId cache, grant application, the loadout cap, ownership-cache freshness. |
| `src/server/Services/StoreService.luau` | The Roblox half: `MarketplaceService.ProcessReceipt`, ownership checks, purchase prompts, equip state. |
| `src/server/Services/DataService.luau` | The receipt write gate — the one narrow handle that exposes durability facts. |
| `tests/StoreLogic.spec.luau` | 53 cases over the pure half. |

Everything in `Config/Store/` currently ships `enabled = false` and
`assetId = 0`. Nothing is for sale until somebody creates the pass or
developer product in the Creator Dashboard and pastes its id in — and
`ConfigValidator` refuses to boot a server with an enabled entry that
still has no id, so a half-finished product cannot reach a player.

## 2. The receipt guarantee

`StoreService.processReceipt` returns `PurchaseGranted` in exactly two
situations:

1. The receipt's `PurchaseId` is already in the buyer's **saved**
   profile. The grant happened in an earlier session and is durable.
   Nothing is granted a second time.
2. We applied the grant, wrote the `PurchaseId` alongside it **in the
   same `Profile.Data` mutation**, then watched that write appear in
   `Profile.LastSavedData`.

Everything else returns `NotProcessedYet`, and Roblox re-offers the
receipt later.

That asymmetry is the whole design. Returning `NotProcessedYet` when we
actually did grant costs nothing — the replay is recognised and
confirmed next time. Returning `PurchaseGranted` a moment too early
costs the player their purchase permanently if the server dies before
the save. One error is recoverable, the other is not, so the code only
ever makes the recoverable one.

**"The same write" is literal.** ProfileStore serialises the whole of
`Profile.Data` on each save, so mutating the grant and the PurchaseId
cache together before calling `Save()` means the DataStore holds both or
neither. There is no window where a player is charged and un-granted, or
granted with no record that would stop a second grant.

This follows ProfileStore's own documented developer-product pattern
(`ServerPackages/.../docs/devproducts/index.md`, "Another way — Caching
`PurchaseId`s") rather than the simpler official Roblox example, which
returns `PurchaseGranted` before any save is confirmed.

### The orderings, and what each one does

| Situation | What happens | Why |
|---|---|---|
| Normal purchase | Grant, save, confirm | — |
| Same receipt offered twice in one session | Second call finds the id in the saved cache, confirms, grants nothing | `classifyReceipt` → `AlreadyGranted` |
| Server crashes after granting, before saving | Grant is lost; receipt is re-offered next session and granted cleanly | The cache entry died with the grant, so they stay consistent |
| Server crashes after saving, before confirming | Receipt is re-offered; the id is in the saved cache, so it confirms and grants nothing | This is the case the whole cache exists for |
| Buyer leaves mid-purchase | `IsActive()` goes false, `waitForSave` gives up, decline | Next session's re-offer resolves it either way, correctly |
| Profile hasn't loaded yet | Wait up to `receiptProfileWaitSeconds`, then decline | Declining is free; blocking is not |
| Buyer is on another server | Decline immediately | Nothing here to write to |
| ProductId matches no **enabled** config entry | Decline, loudly | Confirming would take the money and hand over nothing. Declining keeps the receipt alive: ship the config and it pays out |
| Product was removed after purchase | Confirms if already granted | Otherwise it loops forever on a receipt nothing can satisfy |

### The one real limit

The PurchaseId cache is bounded
(`GameConfig.store.purchaseIdCacheSize`, 100). A receipt older than the
oldest id still held would be granted a second time if Roblox re-offered
it. 100 purchases between two sessions puts that out of reach in
practice, and `Validate.checkStoreConfig` refuses a cache small enough
to make it plausible. `tests/StoreLogic.spec.luau` tests the limit
explicitly rather than pretending it isn't there.

## 3. What a game pass may grant, and why

A pass is permanent, so its grants are re-applied on **every join**.
That makes cosmetic and title grants safe — both are set insertions that
do nothing the second time — and makes consumable grants a disaster:
currency on a pass is an infinite tap.

`Validate.checkStoreItem` refuses a `GamePass` that grants `Currency` or
`PowerUpStock` at boot, rather than leaving it to review. Consumables
are sold as developer products, which come with receipts.

No shipped product grants a `Title`. The grant kind exists and is
validated, but the title ladder keys off `bestStreak` alone (P4-2), and
a bought title would make "permanent, earned, never revoked" mean two
different things at once. If a purely cosmetic store title is ever
wanted, it should be a separate ladder, not a rung on this one.

## 4. Studio test plan

### Setup

- Settings → Security → **Enable Studio Access to API Services** is
  *optional*. With it off, ProfileStore falls back to an in-memory mock
  store, and `LastSavedData` still updates on save — so the entire
  receipt flow, including the confirm-the-write step, is exercisable
  without touching live data. Verified in the pinned package source
  (`UpdateAsync`'s `elseif DataStoreState ~= "Access"` branch).
- `DataService` already uses a separate store name in Studio
  (`PlayerData_Studio`), so even with API access on, nothing here can
  touch production data.

### The seam

`StoreService.debugSimulateReceipt(userId, productId, purchaseId)` feeds
a synthesised receipt straight into the real `processReceipt`. It is
**Studio-only and has no remote** — it grants items, so a client must
have no path to it at all. Call it from the command bar:

```lua
local Loader = require(game.ReplicatedStorage.Shared.Loader)
local Store = Loader.get("StoreService")
Store.debugSimulateReceipt(game.Players.YourName.UserId, 123456, "test-001")
```

Buying things in Studio for real does exercise `ProcessReceipt`, but it
gives you no control over the `PurchaseId` and no way to ask for the
same one twice — which is exactly what the cases below need.

### Case 1 — a normal grant

1. Enable one developer product in `Config/Store/` and give it a real
   `assetId`.
2. `debugSimulateReceipt(userId, <assetId>, "t-1")`.
3. **Expect:** `PurchaseGranted`, one `Store: GRANT ...` line naming the
   product, the purchase id and what changed, and a `StoreState` push.

### Case 2 — a replayed receipt

1. Run case 1.
2. Run it again with the **same** `purchaseId`.
3. **Expect:** `PurchaseGranted` again, a line saying "already granted in
   an earlier session — confirming, granting nothing", and **no** second
   `Store: GRANT`. Check the player's currency or stock is unchanged.
4. Now run it with a *different* purchaseId and confirm it *does* grant
   again — a replay guard that refuses legitimate repeat purchases is
   its own bug.

### Case 3 — a failed grant (unknown product)

1. `debugSimulateReceipt(userId, 999999, "t-2")` — an id no entry claims.
2. **Expect:** `NotProcessedYet`, a loud warning naming the productId,
   and nothing granted.
3. Now add a config entry with `assetId = 999999`, `enabled = true`,
   restart, and re-run with the same `purchaseId`. **Expect:** it grants.
   That is the recovery path for a real config mistake — the receipt
   waits.

### Case 4 — a failed grant (disabled product)

Same as case 3, but with an entry that exists and has `enabled = false`.
**Expect:** identical behaviour — declined, not consumed. A product
switched off mid-sale must not eat purchases already in flight.

### Case 5 — the buyer leaves mid-purchase

This is the one that needs two hands. In Studio, run a local server with
2 players:

1. In the command bar, start the receipt on Player1 with a deliberately
   long wait: temporarily set `GameConfig.store.receiptSaveRetrySeconds`
   to something large (60) so the save-confirm loop is still spinning.
2. Close Player1's window while it is waiting.
3. **Expect:** `NotProcessedYet`, and a warning saying the grant is
   applied but not confirmed saved.
4. Rejoin as Player1 and re-run the same `purchaseId`. **Expect:** it
   either confirms (if the leave-time save carried the grant) or grants
   cleanly (if it did not) — and in neither case does the player end up
   with two grants or zero.

Step 4 is the important one. Both outcomes are correct; what must never
happen is a double grant, and the PurchaseId cache is what rules it out.

### Case 6 — the profile hasn't loaded yet

1. Set `GameConfig.store.receiptProfileWaitSeconds` to 2.
2. Fire `debugSimulateReceipt` for a UserId that is not in the server.
3. **Expect:** immediate `NotProcessedYet` (no player), not a hang.
4. Then fire it in the same frame a player joins, before their profile
   finishes loading. **Expect:** it waits, then grants — or, if the
   profile is slower than the budget, declines with a warning naming the
   wait it gave up on.

### Case 7 — game passes

1. Enable a pass entry with a real `gamePassId` you own.
2. Join. **Expect:** `syncPasses` grants its cosmetics once, with a
   `Store: GRANT` line and no purchaseId.
3. Rejoin. **Expect:** no second `Store: GRANT` line — the grants
   re-apply and change nothing.
4. `StoreService.ownsPass(player, id)` twice in a row: the second should
   not produce a second web call (watch the output; a failure warns).

### Case 8 — the loadout cap

1. Grant stock via case 1.
2. Fire `StoreLoadoutIntent` for slots 1, 2, 3 — all should take.
3. Fire it for slot 4. **Expect:** refused, with a warning naming the
   cap. There is no client-side path that makes this succeed, which is
   the point.
4. Fire it for an item with no stock, and for a `loadoutEligible = false`
   item. **Expect:** both refused.

## 5. The one seam left open

`StoreService.consumeLoadoutFor(player)` is written, tested and **wired
to nothing**.

It is the only place stock is ever decremented, and the rule it
implements is settled: spend one of each item the loadout names,
re-validated against stock, clear the selection. What is *not* settled
is where it should be called from, because that needs an answer to a
question nobody has answered:

> `powerups.md` describes two acquisition paths — a 3-item pre-game
> loadout and a 1-slot in-round field-pickup inventory
> (`GameConfig.powerUpInventorySlots = 1`, with
> `powerUpFullInventoryPolicy = "Refuse"`). It never says how they
> coexist. Three loadout items do not fit in a one-slot inventory.

Plausible answers include a separate loadout reserve the player draws
from, raising the in-round inventory to 3 for loadout items only, or
handing the loadout out one item at a time as each is used. They have
materially different balance consequences, and this is a design call,
not an implementation detail — so P4-5 does not make it.

This is **not** one of GDD §7's eight questions (those are all resolved
in `design-decisions.md`); it is a gap between two documents that were
written separately. Wiring it up later is a call site, not a redesign.

## 6. Pay-to-win review — the plain answer

**Asked:** does the starting-power-up design cross the line in a
competitive mode?

**Answer: as specified, no. As it would actually ship right now, it is
one config edit away from yes, and the risk is not where the design
document looks for it.**

### What the design gets right

design-decisions.md Q8's rule — *every purchasable item must also be
freely earnable; Robux buys time, never exclusive power* — is the
correct rule, and this task made it structural rather than aspirational:

- `Validate.checkPowerUp` fails boot on a power-up with a `robuxPrice`
  and no free acquisition path.
- `Validate.run` fails boot on a **store product** bundling a power-up
  with no free path, which is the same violation arriving through a side
  door — the power-up's own config looks innocent because it names no
  price.
- `Validate.checkStoreConfig` pins `loadoutSlots` to exactly 3, so the
  cap cannot be raised by editing a number.
- A game pass cannot grant a consumable at all.

So the *mechanical* pay-to-win vector — buy power nobody can earn, or
buy more of it than anyone can carry — is closed at boot, in four
independent places, none of which relies on anybody remembering a rule.

### Where it actually crosses, and it is not the mechanics

Q8 already names the residual risk and then treats it as acceptable:

> "The residual risk is perception and the early-game window, not
> mechanics."

That is half right, and the half it gets wrong matters for *this*
specific game.

**The streak is the entire metagame, it only goes up, and it resets
completely on any loss.** That makes this game's competitive stakes
per-round, not per-season. A player on a streak of 19 going for
Untouchable and a player on their first round are playing for wildly
different amounts, and the leaderboard records the difference
permanently.

In that context, the honest description of a 3-item bought loadout is
not "convenience." It is: **a player can pay, at will, for a material
advantage in the specific round where it is worth the most to them** —
the streak-19 round. Grinders reach parity eventually, but parity across
a season is irrelevant when the thing being protected resets to zero on
a single bad round. A payer who loses their streak buys three Sprint
Boosts and tries again immediately; a grinder waits.

That is not a mechanics problem the config can catch, and it is not
purely perception either. It is a real asymmetry in the rate at which
two players can attempt a high-stakes round.

### What would fix it

Roughly in order of how much they cost:

1. **Cheapest, and I would do this one regardless: exclude bought stock
   from streak-credited rounds above a threshold.** The machinery
   already exists — `threat-model.md` §8's NPC-seat rule already gates
   streak credit on round conditions, and `ProgressionService.
   shouldCreditStreak` is the single place it is asked. Either a round
   entered with a purchased loadout earns no streak credit above some
   streak, or loadouts are simply disabled above it. High-streak rounds
   become skill-only; the store keeps its whole audience, which is the
   80% of rounds where nobody is defending anything.

2. **Rate-limit the advantage rather than the purchase.** Cap loadout
   *uses* per unit time (say, one loadout round per hour) rather than
   capping stock. A payer's stock lasts longer; it does not arrive
   faster. This preserves "Robux buys time" in a form that actually
   holds when the resource being bought is attempts, not items.

3. **Make the free path fast enough to be real.** Q8's rule is only true
   if "also earnable" means earnable on a comparable timescale. There
   are no economy numbers in `docs/` yet — `CurrencySmall`'s 500 coins
   and `SprintBoostStock`'s ten items are marked PLACEHOLDER precisely
   because nothing anchors them. **Whoever sets those numbers is the
   person who decides whether this design is pay-to-win, not whoever
   wrote Q8.** If ten Sprint Boosts cost 79 Robux or forty minutes of
   play, the rule holds. If it is 79 Robux or six hours, the rule is
   decorative.

4. **Cosmetics-only, if any doubt remains.** Passes are already
   cosmetic-only and structurally cannot be otherwise. Extending that to
   the whole store costs real revenue and is the safe answer — Q8
   explicitly notes this direction is cheap to tighten and expensive to
   loosen later.

### The tripwire that must exist either way

Q8's own downstream note already requires it and it is worth restating
as a launch gate: **track paid-vs-free win rate, and specifically
paid-vs-free streak length.** Not aggregate win rate — streak length,
bucketed by whether the player has ever bought stock. If the two curves
separate at the top end, this design crossed the line regardless of what
the config validates.

## 7. Unverified platform assumptions

Same stance as `leaderboard-scale.md` §6. Each of these is believed
correct and was checked against the pinned Roblox global type
definitions (`globalTypes.d.luau`) or the pinned ProfileStore source
where possible, but **signature existence is not behaviour** and the
behavioural ones need confirming against current Roblox documentation
before launch.

| # | Assumption | Status | If wrong |
|---|---|---|---|
| S1 | `MarketplaceService.ProcessReceipt` tolerates the callback yielding until it returns a decision | **Behavioural, unverified.** ProfileStore's own docs state it, based on observation, not documentation | Falls back to a `NotProcessedYet` and a later re-offer — the PurchaseId is already in `Data`, so nothing is lost. This is the assumption to check first |
| S2 | `ProcessReceipt` may only be assigned by one script | Documented by Roblox; enforced here by `claimReceiptAccess` | A second assignment silently wins and receipts route somewhere else |
| S3 | `UserOwnsGamePassAsync(userId, gamePassId)` takes a **user id**, not a Player | **Verified** against `globalTypes.d.luau` | Runtime error on every ownership check |
| S4 | `PromptGamePassPurchaseFinished` passes a `Player`; `PromptProductPurchaseFinished` passes a **number userId** | **Verified** against `globalTypes.d.luau` (`RBXScriptSignal<(Player, number, boolean)>` vs `<(number, number, boolean)>`) | The pass handler would index a number. Not connected for products at all, deliberately |
| S5 | A `PurchaseId` is stable across rejoins for one purchase | Documented by Roblox and load-bearing for the replay cache | The replay guard stops working; duplicates become possible |
| S6 | `Profile.LastSavedData` reflects only confirmed DataStore writes | **Verified** in the pinned ProfileStore source (set in the save path, fired with `OnAfterSave`) | The confirm step confirms nothing and the guarantee in §2 is void |
| S7 | With Studio API access off, ProfileStore's mock still updates `LastSavedData` | **Verified** in the pinned source | §4's test plan needs API access enabled |
| S8 | `GetProductInfo` is deprecated in favour of `GetProductInfoAsync` | **Verified** in `globalTypes.d.luau` | Only relevant if a store UI ever fetches live prices; nothing here does |

S1 is the one that would change the design. If `ProcessReceipt` turns
out to have a hard timeout, the fix is to grant, save, and return
`NotProcessedYet` unconditionally on the first offer — accepting one
guaranteed re-offer per purchase in exchange for the same durability
guarantee. That is a change to `waitForSave` alone.
