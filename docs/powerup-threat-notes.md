# Power-up service — threat notes & Studio integration test (P2-7)

Companion to `powerups.md` (the 10-item catalogue) and
`src/server/Services/PowerUpService.luau` (the actual implementation,
whose own header comment is the canonical, always-in-sync version of the
exploit list below — read that first if the two ever seem to disagree).

## Every way a client could try to cheat this

| # | Attack | What blocks it |
|---|---|---|
| 1 | **Infinite use** — spam the use remote past its cooldown | `PowerUpLogic.isOnCooldown` against a server-held `lastUsedAt` timestamp the client never sends |
| 2 | **Retargeting after the fact** — send an intent, then redirect it to a different target | No such step exists — target resolution and effect application happen in one synchronous server call per intent |
| 3 | **Using someone else's power-up** — claim another player's inventory | The acting player comes from `NetGuard`'s authenticated connection, never the payload; inventory is keyed by that real `Player` |
| 4 | **Range spoofing** — claim to be closer than you are | The payload carries no position or distance at all; range/cone are computed server-side from real `Character` positions |
| 5 | **Double-claiming a pickup** — two players touch the same pickup near-simultaneously | `live.claimed` is set synchronously, before any yield, in `tryClaimPickup` |
| 6 | **Using an empty/out-of-range slot** — reference a slot with nothing in it, or someone else's slot | `slotIndex` only ever indexes the caster's own server-held array; empty/out-of-range is rejected before anything else runs |

## What's out of scope here (and whose job it is)

- **The actual gameplay effect** of any power-up (speed change, freeze,
  vision obscure, etc) — P2-8, Status Effects. Until that's built, every
  validated use logs `"no effect resolver wired in yet (P2-8)"` via
  `PowerUpService.setEffectApplier`'s default.
- **The anti-frustration stacking rules** (post-effect immunity,
  diminishing returns, the 15s rolling hard-control cap) — also P2-8,
  which owns every active effect on a character and is the only place
  those rules can be enforced centrally.
- **Movement/position sanity-checking** (is this Character.Position
  even physically plausible right now) — P2-9, a separate service by
  design.

## Studio integration test — two clients

Requires P2-3's gray-box map (`ServerStorage.Maps.GrayBoxTest`, built via
`scripts/build-graybox.luau`) — its `PowerUpSpawn` tags/attributes are
already what `debugLoadSpawnPointsFromMap` reads.

1. **Start a 2-client test.** Studio → Test tab → "Clients and Servers",
   2 players. Build the gray-box map first if it isn't already present.

2. **Load spawn points and start the race**, from the server's own
   command bar:
   ```lua
   local Loader = require(game.ReplicatedStorage.Shared.Loader)
   Loader.get("PowerUpService").debugLoadSpawnPointsFromMap(game.ServerStorage.Maps.GrayBoxTest)
   Loader.get("RoundService").debugForceTransition("Race")
   ```
   Expect: a colored Neon ball at every `PowerUpSpawn` point (grey =
   Common, green = Uncommon, blue = Rare), and a server Output line for
   each spawn point PowerUpService loaded.

3. **Pickup, server-confirmed.** Walk client 1's character into a
   pickup. Expect: the ball disappears immediately, and (if you've
   connected a quick client-side print to `PowerUpInventoryChanged` via
   `Net.onClientEvent`) client 1 sees its own inventory update. A
   respawn timer should fire later (`GameConfig.powerUpRotationTimers`,
   scaled by the point's rarity) and a new ball appears at the same
   point.

4. **Full-inventory behavior.** With the default `powerUpInventorySlots
   = 1`/`powerUpFullInventoryPolicy = "Refuse"`, have client 1 walk into
   a second pickup while still holding the first. Expect: the second
   pickup is refused and **stays in the world** (touch it again to
   confirm it's still claimable — by client 2, say). Temporarily flip
   `GameConfig.powerUpFullInventoryPolicy` to `"Swap"` and repeat:
   expect the first item evicted and the second one now held.

5. **Use validation, from either client's command bar (or a temporary
   LocalScript)**:
   ```lua
   local Net = require(game.ReplicatedStorage.Shared.Net)
   Net.fireServer("PowerUpUseIntent", {})
   ```
   Expect a server Output `AUDIT` line naming the player, the power-up
   id, and `Applied` (or a `Rejected` reason). Fire it again immediately
   — expect `Rejected (on cooldown)`.

6. **Targeting.** Pick up (or temporarily grant via
   `Loader.get("PowerUpService")`'s inventory, or just walk over a
   pickup rolled to) an `Aimed` or `Nearest` item (Freeze, Blind).
   With client 2 standing within `powerUpUseRangeStuds` and in front of
   client 1 (within `powerUpTargetConeDegrees`), fire the use intent
   from client 1 with no `targetPlayerId`. Expect the audit line to name
   client 2's `UserId` as the target. Move client 2 out of range or
   behind client 1 and repeat: expect `Rejected (no valid target)`.

7. **Double-claim race (best-effort manual check).** With both clients
   standing on either side of the same pickup, have both walk in as
   close to simultaneously as you can manage. Expect exactly one
   `PowerUpInventoryChanged` event fires (check both clients' Output) —
   never both.

8. **Audit log retrieval.** From the server command bar:
   ```lua
   for _, entry in Loader.get("PowerUpService").getAuditLog() do
   	print(entry.at, entry.playerName, entry.powerUpId, entry.result, entry.reason)
   end
   ```
   Expect every use attempt from steps 5–6 present, in order.
