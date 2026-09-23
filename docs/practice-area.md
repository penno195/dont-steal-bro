# Don't Steal Bro! — Hub Practice Area (P5-5)

Waiting players pick up the real items in the hub and use them on each
other. `PracticeService` has **no** power-up or effect logic of its own.
It switches `EffectContext` into practice mode, and the real
`PowerUpService` and `StatusEffects` run under that flag. Why that
matters is written at the top of `src/server/EffectContext.luau`: a
copy would drift, and practice would then teach players the wrong game.

## What the practice flag changes

Nothing else differs from a round: the same items, ranges, cooldowns,
stacking rules and hard-control immunity.

| | Round (default) | Practice |
|---|---|---|
| Who can pick up, cast, be hit | everyone | only inside `HubPracticeArea`, outside `HubQueueNoEffectZone`, and not Departing |
| Effect duration | as defined | × `durationScale`, capped at `maxEffectSeconds` |
| Active effects per player | unlimited | `maxActiveEffects` (a refresh doesn't count) |
| PowerUpService audit, `Telemetry.powerUpUsed` | written | skipped (`EffectContext.recordsStats()`) |
| MovementWatch | scores Race samples | skips anyone in the practice area |
| `PowerUpService.beginRace` | runs | **asserts**: a round can't start in practice mode |

Leaving the area, entering the queue pad's no-effect zone, or being
matched clears every effect and held item within `zoneCheckSeconds`.
`MatchTeleportService` also clears the whole group the moment it
departs, so a frozen player is thawed and travels anyway.

## Config (`GameConfig.practice`)

```lua
practice = {
	durationScale = 0.5, -- a 2.5s Freeze lands as 1.25s
	maxEffectSeconds = 2, -- nothing lasts longer than this, whatever the item
	maxActiveEffects = 1, -- one effect per player at a time
	itemSpawnRarities = { "Common", "Uncommon", "Rare" }, -- so every tier shows up to try
	respawnMultipliers = { Common = 0.25, Uncommon = 0.25, Rare = 0.25 }, -- 4x faster than a round
	zoneCheckSeconds = 0.2,
},
```

All values are placeholders, to be tuned in playtest.
`Validate.checkPracticeConfig` enforces a `durationScale` in (0, 1] so
practice can never outlast the real thing, a whole cap of at least 1,
and a zone check of at most 1 s.

## Why practice can't reach a match server

1. Practice state is plain memory on the hub server. Nothing saves it.
2. The only data that travels is TeleportData, and `TeleportLogic.buildHint`
   carries exactly `v`, `groupId`, `mapId` and `npcSlots`.
   `tests/TeleportLogic.spec.luau` fails if a field is ever added.
3. A match server never enters practice mode. `PracticeService` activates
   only on the hub place (or in Studio with `hubPlaceId = 0`) and only if
   `Workspace.Hub` has a `HubPracticeArea`.
4. If practice mode ever did reach a server that starts a round,
   `EffectContext.assertRound` stops the round in `beginRace`.
5. A new character starts clean: `StatusEffects` clears everything on
   `CharacterAdded`.

## Test steps

Headless (CI): `tests/EffectContext.spec.luau` (Round mode changes
nothing; gating, scaling, cap, round assertion), the practice block in
`tests/Config.spec.luau`, and the TeleportData check in
`tests/TeleportLogic.spec.luau`.

In Studio, with the gray-box hub from `scripts/build-hub.luau`, on a local
server with 3 players:

1. **Pickups spawn.** A glowing pickup appears above every
   `HubPracticeItemSpawn`, colours cycling Common → Uncommon → Rare.
2. **Real items work, shortened.** Player A picks up Freeze and uses it on
   B inside the area. B is frozen for about 1.25 s, not 2.5 s.
3. **Cap.** With B holding one effect, a second, different item on B is
   rejected (`practice effect cap reached`). The same item again refreshes.
4. **No effects outside.** C stands just outside the area. A's aimed item
   finds no target. A walks out holding an item: the inventory empties
   within 0.2 s and a use is rejected (`outside the practice area`).
5. **Queue pad.** Freeze B, and have B walk into the no-effect zone
   before it ends (or teleport B's character there with the command bar).
   The freeze clears and B can't be targeted while there.
6. **Frozen when the match is ready.** Freeze B in the area, then queue B
   into a group. Once the group forms (B's ticket is Departing), B is
   thawed within 0.2 s and can't be hit again. On published places,
   `MatchTeleportService` also thaws B at the moment the group departs.
   Studio has no teleport, so only the Departing check runs there.
7. **Nothing recorded.** During steps 2–6 the Output shows no
   `PowerUpService AUDIT` lines, and `PowerUpService.getAuditLog()` is
   empty.
8. **No round in practice mode.** In the same place, force Race with
   RoundService's debug interface: it errors with "practice rules are
   active on a server running a round".
9. **Match server is clean** (published places): arrive on the match
   server from a practice scuffle. The command bar shows
   `EffectContext.mode()` is `"Round"` and `StatusEffects` has no active
   effects for anyone.
