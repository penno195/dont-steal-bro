# Don't Steal Bro! — Hub Tag Contract (P5-4)

The hub counterpart of `map-kit-spec.md`: which CollectionService tags
hub code can rely on. `scripts/build-hub.luau` builds a gray-box hub that
meets it and checks the counts on every run; a hand-built hub must meet it
too. Everything lives under `Workspace.Hub` in the **hub place**. No hub
geometry is ever cloned into a match server.

## Tags

| Tag | Instance class | Count | Attributes |
|---|---|---|---|
| `HubZone` | Model | exactly 6 | `ZoneId` (string), `ApproachPoint` (Vector3) |
| `HubSpawn` | SpawnLocation | exactly 1 | — |
| `HubQueuePad` | BasePart | exactly 1 | — |
| `HubQueueNoEffectZone` | BasePart (volume) | exactly 1 | — |
| `HubQueueCountdown` | BasePart | exactly 1 | — |
| `HubVoteBoard` | BasePart | exactly 1 | — |
| `HubStorePodium` | BasePart | exactly 3 | `Slot` (1–3) |
| `HubLeaderboardSurface` | BasePart | exactly 3 | `Period` (`"Daily"`, `"Weekly"`, `"AllTime"`) |
| `HubPracticeArea` | BasePart (volume) | exactly 1 | — |
| `HubPracticeItemSpawn` | BasePart | 4–8 | — |
| `HubSoftBarrier` | BasePart | 1+ | — |

`ZoneId` is one of `SpawnPlaza`, `QueuePad`, `VoteBoard`, `StoreFront`,
`Leaderboards`, `PracticeArea`. `ApproachPoint` is where a player stands
to use the zone. Walk times are measured to it, and wayfinding can reuse it.

## Rules

- **Volumes** (`HubQueueNoEffectZone`, `HubPracticeArea`) are invisible,
  `CanCollide`/`CanTouch`/`CanQuery` all off, so they never block movement
  or camera and click rays. Test containment against their `CFrame`/`Size`
  or use them as the query shape for `GetPartsInPart`. Do not rely on
  `.Touched`.
- **The two volumes must not overlap** on the horizontal plane, or
  practice effects could reach someone standing on the queue pad (P5-5).
- **The queue pad is signage and a zone, not a trigger.** Joining the queue
  is the `QueueJoinIntent` UI intent (`MatchmakingService`). Stepping on
  the pad starts nothing.
- **The vote board wall is signage.** Each group's live ballot is a
  per-player overlay (`voting.md`), because several groups vote at once
  on one server.
- **Display surfaces** (`HubQueueCountdown`, `HubVoteBoard`,
  `HubLeaderboardSurface`) face the player with their **Front** face,
  where client UI mounts its `SurfaceGui`.
- **Readability from spawn:** the queue pad sits within 15° of the
  spawn's facing, which fits a portrait phone's horizontal field of view
  without turning, and the sight line to it is clear. Every zone's
  `ApproachPoint` is at most **8 s** of straight-line walking from spawn
  at `StarterPlayer.CharacterWalkSpeed`.
- Exactly one `SpawnLocation` should exist in the hub place. The builder
  warns about any outside `Workspace.Hub`.
