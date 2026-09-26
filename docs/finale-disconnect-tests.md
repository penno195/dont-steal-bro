# Finale disconnect & forfeit — Studio test plan (P3-7)

Companion to `src/server/FinaleRoster.luau` (the rules, as pure
decisions — its header is the canonical version of *why* the
before/inside-the-Studio split exists) and
`src/server/Services/DecisionService.luau` (which applies them).

P3-7's six cases are decisions plus plumbing. The decisions are covered
headlessly in `tests/FinaleRoster.spec.luau` — 26 cases, including the
one the task singles out ("prove this with a test" for case 5). What a
unit test *cannot* prove is that a real Roblox disconnect, at a real
moment, actually reaches those decisions and that the profile write
genuinely beats ProfileStore's session release. **That is what this
document is for, and none of it has been run yet** — no map exists, so
no round can reach the Studio in Studio. Run it the first time one can.

## Setup, once

1. Open the place, **Test → Clients and Servers → 2 players**, Start.
2. Studio test mode (`GameConfig.studioTest`) loads `GrayBoxTest` and
   starts the round by itself. Set its `minHumans = 2` for this test so
   the round waits for both clients. With test mode off, do it by hand
   from the **server** command bar:
   ```lua
   local Loader = require(game.ReplicatedStorage.Shared.Loader)
   local map = game.ServerStorage.Maps.GrayBoxTest:Clone()
   map.Parent = workspace
   Loader.get("TaskService").debugLoadStationsFromMap(map)
   Loader.get("NPCService").debugLoadFromMap(map)
   Loader.get("RoundService").debugForceTransition("Loading")
   ```
3. Two humans plus four NPCs fill the round. Let the race run, or force
   qualification; what matters is reaching `DecisionStudio` with **both
   humans among the three qualifiers**, so a closed window is always a
   qualifier leaving. Check with:
   ```lua
   print(Loader.get("TaskService").getLastQualificationResult())
   ```
   If a human didn't qualify, re-run — the cases below depend on it.
4. Note both humans' streaks before each case, so you can tell a
   preserved streak from a reset one:
   ```lua
   for _, p in game.Players:GetPlayers() do print(p.Name, Loader.get("DataService").getStreak(p)) end
   ```

**Reading the result.** After each case, the leaver has gone, so their
profile can't be read live. Check the server output instead — every
branch prints — and re-join that client to read the persisted streak.

## Case 1 — leaves between the race ending and the Studio starting

The narrow window: after `Qualified`, before `DecisionStudio`.
`GameConfig.roundTimers.qualifiedSeconds` is 3 seconds by default, which
is tight. Widen it first:

```lua
-- server, BEFORE the race ends
Loader.get("RoundService").debugForceTransition("Qualified")
```

**When to close the window:** the instant the qualification result
prints and before the Studio's Intro phase broadcast. If you keep
missing it, temporarily raise `roundTimers.qualifiedSeconds` to 15 in
`GameConfig.luau`.

**Expect:**
- Server prints `N qualifier(s) left before the Studio - running with M finalist(s)`.
- A `DecisionRosterChange` with `reason = "Withdrawn"` and
  `replacedById` set to the 4th-place finisher — who is an NPC in a
  two-human lobby, so confirm the promoted id is negative.
- The Studio runs with **three** finalists, one of them the promotion.
- The remaining human's streak is untouched by the departure.

**Variant 1b, no alternate.** Force `alternate` to be absent by having
only three finishers meet the floor (let the other three NPCs idle by
not loading stations for them, or force qualification early). Expect
`replacedById = nil`, a **two-finalist** Studio, and a `TwoShare` /
`OneStealOneShare` / `TwoSteal` branch at the reveal — the two-player
branch, not a three-player branch with an empty seat.

## Case 2 — leaves during Negotiate

**When to close the window:** any time during the 20-second Negotiate
phase, after the `DecisionPhaseChanged` broadcast naming it.

**Expect:**
- `DecisionRosterChange` with `reason = "Forfeited"`, `replacedById = nil`.
- **No promotion** — this is the Q4 side of the line, not Q3.
- The finale continues; the remaining two negotiate and choose normally.
- At the reveal, the leaver's seat counted as **Share**.
- On re-join, the leaver's streak is **0** and their `losses` stat went
  up by one.

## Case 3 — leaves during Choose, after locking in

**When to close the window:** lock in a **Steal** on client A first
(watch for `DecisionLockedIn` carrying A's id), then close A's window
while Choose is still running.

**Expect:**
- The leaver's **Steal stands** — the reveal shows Steal for them, not
  Share. This is the case a naive implementation gets wrong by
  overwriting every leaver with the default.
- They still forfeit: streak **0**, `losses` +1 on re-join.
- If they were the last unlocked seat, resolution happens immediately
  rather than waiting out the timer.

## Case 4 — leaves during Choose, without locking

**When to close the window:** as soon as Choose begins, before
submitting anything on that client.

**Expect:** identical to case 2's outcome (seat votes **Share**, streak
**0**), but reached during Choose rather than Negotiate.

## Case 5 — leaves during Reveal or Resolve

**When to close the window:** after `DecisionReveal` has fired — i.e.
once the client can see the choices — and before the round transitions
to `Results`. `revealDelaySeconds` is 1 second, so widen it in
`GameConfig.luau` to 10 for this test.

**Expect:**
- Server prints `left after the result was written - no change (P3-7 case 5)`.
- **No** `DecisionRosterChange`.
- The leaver's persisted result is whatever the table gave them. Run it
  **twice**, once where the leaver won and once where they lost, using
  the debug hook to force each:
  ```lua
  Loader.get("DecisionService").debugForceOutcome("SoleSteal")
  ```
  A winner who quits during the reveal must still have their **streak
  incremented and a pending bounty**, not a forfeit. That direction is
  the one worth checking — the losing direction looks correct even when
  the code is wrong.

## Case 6 — the server shuts down mid-finale

**When to trigger:** during Negotiate, with both humans still connected.
Stop the Studio server (the Stop button, which fires `BindToClose`).

**Expect:**
- Server prints `shutdown mid-finale - cleared N forfeit resolver(s); every streak is preserved as it was`.
- On the next session, **both humans' streaks are exactly what they were
  before the round** — no win, no loss.

**The failure this guards against** is the interesting one: without
`handleServerShutdown`, every qualifier still carries the Q4 forfeit
resolver, `PlayerRemoving` fires for everyone as the server goes down,
and all three finalists lose their streaks because Roblox pushed an
update. To see it, comment out the `game:BindToClose(handleServerShutdown)`
line and re-run — the streaks should reset, which is the bug.

**Variant 6b.** Shut down *after* the reveal. Expect `shutdown after the
result was written - the written result stands`, and the real result
persisted — ProfileStore's own `BindToClose` saves `Profile.Data` as it
is (confirmed in its source, `SaveProfileAsync(profile, true, nil,
"Shutdown")`).

## The ordering guarantee, checked directly

"In all cases the profile write must happen before ProfileStore releases
the session." The ordering itself is enforced in one function and
unit-tested (`ProfileLogic.applyLeaveSequence`,
`tests/ProfileLogic.spec.luau`). To confirm it end to end in Studio, add
a temporary print inside the resolver registered in
`beginDecisionStudio` and another on `profile.OnLastSave`, then run case
2: the resolver's print must come first. Remove both afterwards.

## What none of this covers

- **Two qualifiers leaving simultaneously** inside the Studio. The rules
  handle it (each leave is classified independently, and the roster can
  shrink to one — `Outcomes.resolve` has a `SoloFinalist` branch), but
  two windows closing in the same frame is not something this plan can
  stage reliably.
- **A rejoin mid-finale.** A player who leaves and comes back is a new
  session with no seat; they are a spectator for the rest of the round.
  Nothing restores their seat, deliberately — Q4 says the leaver takes
  the loss, and letting them return would undo it.
- **NPC qualifiers leaving**, because they can't. A bot is present for
  the whole Studio; `isPresent` answers from the participant roster for
  negative ids rather than from `Players`.
