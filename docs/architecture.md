# Don't Steal Bro! — Technical Architecture

Companion to `gdd.md`. Attach both to any session working on this game.

These choices shape every phase of the build plan. Changing them after Phase 2
is expensive. Anything marked **assumption** was inferred, not specified by the
designer — confirm before relying on it.

---

## 1. Decisions to lock in week 1

| Decision | Choice | Why |
|---|---|---|
| **Place topology** | One experience, two places: a **Hub** (lobby, store, leaderboards, voting, queue) and a **Match** place (one 6-player round per reserved server). | Match servers stay small and short-lived; the hub holds many players without running game logic. Matchmaking via `TeleportService:ReserveServer` + `MemoryStoreService`. |
| **Maps** | All 11 live in the Match place's `ServerStorage`, cloned in during the loading screen. | Avoids maintaining 11 separate places; a server only ever loads one map. |
| **Toolchain** | Rojo + Git, Wally, Luau LSP, StyLua, Selene, `--!strict` everywhere. | Reviews and merges work properly; types catch data-definition errors at boot. |
| **Persistence** | **ProfileStore** for player data. OrderedDataStore for the all-time board. MemoryStore SortedMaps for daily/weekly. | Session locking prevents streak duplication across teleports. MemoryStore entries expire on their own — no cleanup job. |
| **Networking** | One typed `Net` module declaring every remote in one place. Optionally generated with Blink or Zap. | One place to audit; type safety; bandwidth savings. |
| **UI framework** | React-lua if the team knows React, otherwise Fusion or Vide. | Declarative UI is the only practical way to keep 15+ task screens consistent. |
| **Testing** | Jest-Lua for pure logic; Lune to run it in CI; Studio "Clients and Servers" (6 players) for integration. | Outcome table, pricing, ranking, tie-breaks and streak maths should all be pure and unit-tested. |
| **Authority** | **Server-authoritative for everything.** Clients send intents; the server validates and applies. | Competitive game with a public leaderboard — it will be exploited. |

## 2. Folder skeleton

```
src/
  shared/                      -> ReplicatedStorage.Shared
    Config/
      GameConfig.luau          -- timers, player counts, bounty values, streak rules
      Maps/        School.luau, Factory.luau ...   (one def per map)
      Tasks/       Wires.luau, Keypad.luau ...     (one def per task)
      PowerUps/    Freeze.luau, Speed.luau ...
      Titles.luau              -- streak thresholds -> title + colour
      Outcomes.luau            -- Decision Studio outcome table
    Net.luau                   -- every RemoteEvent/Function declared here
    Types.luau
  server/                      -> ServerScriptService
    Services/  RoundService, TaskService, PowerUpService, NPCService,
               DecisionService, DataService, LeaderboardService,
               StoreService, TitleService, MatchmakingService (hub)
    TaskHandlers/              -- server half of each task (validate)
  client/                      -> StarterPlayerScripts
    Controllers/  InputController, CameraController, EffectsController
    UI/           Components/, Screens/, Theme.luau
    TaskViews/                 -- client half of each task (the minigame UI)
ServerStorage/Maps/<MapName>   -- built in Studio, never synced by Rojo
```

**Scaling rule.** Adding a map, task, power-up or title means adding **one config
file and at most one handler module**. No service code changes. If a new task
requires editing `RoundService`, the abstraction is leaking.

## 3. Round state machine

`WaitingForPlayers → Loading → Intro → Race → Qualified → DecisionStudio →
Results → Cleanup`

Every timer is an absolute server timestamp from `workspace:GetServerTimeNow()`;
clients compute countdowns locally. No per-second remotes. The transition table
is data, not branching code, so it can be unit-tested.

---

## 4. Deep dive: NPC fill

**Spawning.** The Match server reads `npcCount` from TeleportData as a *hint
only* and re-derives it itself: `6 - humansPresentAfterGraceWindow`, with a ~10s
grace window so slow teleports aren't replaced by bots.

**Don't simulate the minigames — simulate the timing.** An NPC:

1. Picks its next station (nearest unfinished, with randomness).
2. Walks there via `PathfindingService`, using the map's `NavNodes` as coarse
   waypoints. Recomputes only when blocked, never per frame.
3. "Works" for a duration sampled from that task's `expectedDuration`, scaled by
   a **skill profile**.
4. Reports completion through the same `TaskService` API a human uses — so
   qualification logic has no NPC branch anywhere.

**Utility-AI griefing.** NPCs pick up power-ups on their route, use debuffs on
the nearest player ahead of them, buffs when their path is long. Same cooldowns
and immunity rules, routed through the same validated server path.

**Fairness knobs.** A skill profile per NPC (Casual / Average / Sweaty) drawn
from a distribution, tuned from real player telemetry. **Soft rubber-banding:**
an NPC never finishes faster than the median human time for that task. Consider
reduced or zero streak credit when more than N seats are NPCs.

**Studio behaviour.** Hidden personality weights — Greedy `{steal 0.7}`, Loyal
`{steal 0.2}`, Chaotic `{0.5}`. Canned bubble-chat bluffs during negotiation
that may or may not match the actual choice; lock-in at a random time in window.

**Performance.** Server network ownership (`SetNetworkOwner(nil)`), simple rigs,
unused Humanoid states disabled, AI tick at 5–10 Hz — never on Heartbeat.

**Presentation.** Generated names that can never collide with real usernames.
Never impersonate real players.

## 5. Deep dive: mobile-first UI

1. **Layout in Scale, not Offset.** Root frame per screen with a
   `UIAspectRatioConstraint`; `ScreenGui.ScreenInsets = CoreUISafeInsets` to
   clear notches and Roblox's top bar.
2. **Global `UIScale` controller.** Watch `workspace.CurrentCamera.ViewportSize`,
   set scale from the shortest axis against a reference resolution
   (e.g. 1280×720), clamped ~0.6–1.5. Author once; scales everywhere.
3. **Detect input mode, not device.** `UserInputService.PreferredInput` with a
   change listener — `TouchEnabled` is true on touchscreen laptops.
4. **Thumb zones.** Primary actions bottom-right, clear of the jump button.
   Informational HUD top-centre/left, below the menu inset. Minimum touch target
   ~44×44 points after scaling. Steal/Share lock-in needs hold-to-confirm.
5. **Mini-games.** Full-screen modal on mobile; camera input frozen while open;
   one-thumb interactions only; hit areas larger than visuals; auto-close if the
   player is knocked away from the station.
6. **Text.** `TextScaled` + `UITextSizeConstraint` (min/max). One or two fonts.
7. **Power-up aiming on mobile.** Smart targeting (nearest valid target in a
   forward cone) by default, hold-and-drag override optional.
8. **Testing.** Studio emulator for iteration; a mandatory real-device pass on a
   small Android phone, a notched iPhone and a tablet at every milestone exit.

## 6. Deep dive: Decision Studio networking

**Principle.** Clients never learn anyone's choice until the reveal packet.
Choices live only in a server-side Lua table — never in Attributes, ValueObjects
or anything else that replicates.

```
Server → Qualifiers   StudioPhase { phase = "Intro",     endsAt = t+5  }
Server → Qualifiers   StudioPhase { phase = "Negotiate", endsAt = t+45 }   -- chat open
Server → Qualifiers   StudioPhase { phase = "Choose",    endsAt = t+15 }
Client → Server       SubmitChoice("Steal" | "Share")
Server → Qualifiers   PlayerLocked { userId }                               -- no choice content
Server → Qualifiers   StudioPhase { phase = "Reveal", choices = {...},
                                    outcome = {...}, revealAt = t+1 }
```

**Validation in `SubmitChoice`:** sender is a qualifier; `phase == "Choose"`;
payload is exactly `"Steal"` or `"Share"`; not already locked (**locks are
final**); rate limit holds. Anything else is dropped silently and logged.

**Resolution order — this exact order matters for dodge-proofing:**

1. Deadline hits, or all 3 locked.
2. Anyone missing takes `Config.DefaultChoice` (**assumption:** `"Share"`).
3. Compute the outcome with a pure function.
4. **Write results to profiles first.**
5. Then broadcast the reveal; clients animate from the shared `revealAt`.
6. Transition the round state.

A player who leaves after qualifying has the forfeit applied in
`PlayerRemoving` **before** ProfileStore releases their profile.

**Outcome table** — data-driven, handles any qualifier count:

```lua
--!strict
-- Config/Outcomes.luau
local Bounty = require(script.Parent.GameConfig).Bounty

export type Choice = "Steal" | "Share"
export type Outcome = { winners: {number}, bounty: number, tag: string }

local function resolve(choices: {[number]: Choice}): Outcome
    local stealers, sharers = {}, {}
    for userId, c in choices do
        table.insert(if c == "Steal" then stealers else sharers, userId)
    end
    local n, s = #stealers + #sharers, #stealers

    if s == 0 then
        return { winners = sharers, bounty = Bounty.AllShare, tag = "AllShare" }        -- 3 Share
    elseif s == n then
        return { winners = {}, bounty = 0, tag = "MutualDestruction" }                  -- 3 Steal
    elseif s == 1 then
        return { winners = stealers, bounty = Bounty.SoleStealer, tag = "SoleStealer" } -- 1 Steal, 2 Share
    else
        return { winners = sharers, bounty = Bounty.LoneSharer, tag = "LoneSharer" }    -- 2 Steal, 1 Share
    end
end

return { resolve = resolve }
```

Unit-test every combination for n = 1, 2 and 3, and assert the design invariant
`SoleStealer > LoneSharer > AllShare > 0`.

**Proximity chat.** Voice via the Audio API (`AudioDeviceInput` → `AudioEmitter`
on the character, `AudioListener` on the camera) requires opted-in, eligible
users — **many mobile players won't have it, so the finale must work fully in
text.** Text via `TextChatService` with a proximity `TextChannel` whose
`ShouldDeliverCallback` checks distance, plus bubble chat. Roblox filtering
applies automatically.

## 7. Risk register

| Risk | Mitigation |
|---|---|
| Friends collude with 3× Share to farm streaks | Solo streak queue, re-match cooldown with the same players, telemetry alerts on repeated identical groups |
| NPC lobbies used to farm streaks | Reduced credit above an NPC threshold, rubber-band floor, analytics watch |
| Dense stylized maps crash or stutter on low-end phones | Budgets set in P0-6, StreamingEnabled, validator enforcing counts, real-device gates |
| Griefing feels unfair rather than fun | Immunity windows, diminishing returns, visible counter-play, telemetry on time spent disabled |
| Backdoors in asset packs | Validator strips and flags all foreign scripts; never insert unreviewed packs into a live place |
| Scope creep from 11 maps + many tasks | Launch with 4 maps and ~8 tasks; the rest ship in content waves |

## 8. Schedule assumption

Roughly **6–8 months** to a Wave 1 launch for a 2–4 person team. Most variance
comes from task count and map art throughput. Scale to actual headcount.
