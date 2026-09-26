# Don't Steal Bro! — Hub Tag Contract (P5-4)

The hub counterpart of `map-kit-spec.md`: which CollectionService tags
hub code can rely on. `scripts/build-hub.luau` builds a gray-box hub that
meets it and checks the counts on every run; a hand-built hub must meet it
too. Everything lives under `Workspace.Hub` in the **hub place**. No hub
geometry is ever cloned into a match server.

## Tags

| Tag | Instance class | Count | Attributes |
|---|---|---|---|
| `HubZone` | Model | exactly 5 | `ZoneId` (string), `ApproachPoint` (Vector3) |
| `HubSpawn` | SpawnLocation | exactly 1 | — |
| `HubQueueCountdown` | BasePart | exactly 1 | — |
| `HubStorePodium` | BasePart | exactly 3 | `Slot` (1–3) |
| `HubLeaderboardSurface` | BasePart | exactly 3 | `Period` (`"Daily"`, `"Weekly"`, `"AllTime"`) |
| `HubPracticeArea` | BasePart (volume) | exactly 1 | — |
| `HubPracticeItemSpawn` | BasePart | 4–8 | — |
| `HubSoftBarrier` | BasePart | 1+ | — |

`ZoneId` is one of `SpawnPlaza`, `QueuePad`, `StoreFront`,
`Leaderboards`, `PracticeArea`. `ApproachPoint` is where a player stands
to use the zone. Walk times are measured to it, and wayfinding can reuse it.

## Rules

- **The `HubPracticeArea` volume** is invisible, with
  `CanCollide`/`CanTouch`/`CanQuery` all off, so it never blocks movement
  or camera and click rays. It marks where practice pickups live; held
  items work anywhere in the hub (`practice-area.md`).
- **No queue pad.** Joining the queue is the `QueueJoinIntent` UI intent
  (the Play card, `MatchmakingService`), so the hub has no floor pad to
  stand on and no no-effect zone. The `QueuePad` zone is just the
  countdown board.
- **No map vote wall.** The map vote is a per-player overlay shown after
  a match forms (`voting.md`), because several groups vote at once on one
  server, so the hub has no vote zone or board.
- **Display surfaces** (`HubQueueCountdown`, `HubLeaderboardSurface`) face the player with their **Front** face,
  where client UI mounts its `SurfaceGui`.
- **Readability from spawn:** the queue countdown sits within 15° of the
  spawn's facing, which fits a portrait phone's horizontal field of view
  without turning, and the sight line to it is clear. Every zone's
  `ApproachPoint` is at most **8 s** of straight-line walking from spawn
  at `StarterPlayer.CharacterWalkSpeed`.
- Exactly one `SpawnLocation` should exist in the hub place. The builder
  warns about any outside `Workspace.Hub`.

## Doors

Proximity doors work anywhere (hub or a race map); adding one is tagging
it, never editing code (`DoorService`, `DoorController`, `DoorLogic`).

| Tag | Instance class | Needs |
|---|---|---|
| `ProximityDoor` | Model | a direct `BasePart` child named `Hinge` (usually invisible, non-colliding); optional `OpenAngle` attribute (degrees) |

- The door swings about the **Hinge's up axis**, so put the Hinge on the
  panel's hinged edge, upright.
- It opens when anyone comes within `GameConfig.doors.openRadius` (ground
  distance), swings **away from them**, and closes once nobody is within
  `closeRadius`. While open, its colliding parts don't collide.
- The server only sets `Open`/`OpenSide` attributes; each client tweens
  the swing. Parts that stream in late are posed on arrival.
