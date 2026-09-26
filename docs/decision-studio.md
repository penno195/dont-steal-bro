# Don't Steal Bro! — Decision Studio UI (P6-5)

The client side of the finale: three finalists (or two, or one) meet,
negotiate, lock in Steal or Share, and watch the reveal. Built on P6-2's
components over P3-2's `DecisionService` phase machine.

| File | Role | Tested |
|---|---|---|
| `src/client/UI/DecisionLogic.luau` | Pure: payload parsing, reputation line, payoff table, hold-to-confirm, stage, reveal timeline, result copy, chat inset | Headless (`tests/DecisionLogic.spec.luau`) |
| `src/client/UI/Screens/DecisionStudio.luau` | The screen, plus `confirmer` (the hold machine's Heartbeat driver). Reads a `Store` and never touches a remote | Preview screenshot |
| `src/client/Controllers/DecisionStudioController.luau` | Remotes → sources, the choose intent (with resend), talk polling, chat-window tracking, mounting | On device |
| `src/client/UI/Screens/DecisionStudioPreview.luau` | The real screen on a scripted finale loop | Screenshot |
| `src/server/Services/DecisionService.luau` | Two additions: reputation in `DecisionParticipants`, and the new targeted `DecisionPersonalResult` | Existing server tests + on device |

## A deviation from the task prompt: no streaks, no titles

The P6-5 prompt asks for the intro to show "the three finalists revealed
with their titles and current win streaks." **It doesn't.** The prompt
predates `design-decisions.md` Q7, whose condition 1 keeps streak off every
in-round surface. Q7's applied case (P4-2) names the Decision Studio by
name as the place titles are hidden: "three finalists reading each other's
rungs would learn who most needs the win." Showing them here would break
the rule the harsh reset depends on.

Decided with the project owner in this session: **the intro shows each
finalist's steal/share reputation instead** (Q5's "stolen 62% of the last N
decisions"). That is the information design-decisions.md actually wants in
front of a bluffer: a behavioural record, not a stake size. It is recorded
in design-decisions.md as Q7's second applied case, which also closes Q5's
open detail.

The prompt also asks for "the deliberate design reason for showing
streaks here." The reason for showing reputation is Q5's own: it adds real
information to a blind choice without changing the game theory, and it
gives returning players a record worth protecting. Streak would add a
different kind of information: who has the most to lose. That turns the
Studio into targeting, which is exactly what Q7 exists to prevent.

## Stages

One screen whose parts show and hide (`DecisionLogic.stage`), so a phase
change never rebuilds the seats mid-sentence:

| Stage | Seats show | Middle | Bottom |
|---|---|---|---|
| Intro | name, reputation | "MEET THE FINALISTS", countdown | payoff table; Steal/Share dimmed so the thumb learns where they are |
| Negotiate | + 🎙 Speaking / 💬 Typing… | "NEGOTIATE", countdown | same |
| Choose | + 🔒 Locked / Deciding… | "CHOOSE", countdown | payoff table; Steal/Share live, hold to lock |
| Locked | same | "LOCKED IN" | payoff table; your choice under a lock, "FINAL", "Waiting for N more" |
| Reveal | cards flip one by one; then WINS / LOSES | the outcome line, same on every screen | result panel |

A spectator (in the room but not a finalist) sees everything except the
buttons, with "You're watching this one."

**Reputation line.** Lifetime counts from the profile's `steals`/`shares`,
since the profile keeps totals, not a window. Under 10 decisions it reads
"Stole 2 of 5". A percentage of five is noise that reads like a verdict.
From 10 up it reads "Steals 62% of 40". 0/0 reads "No history yet", and
the server sends 0/0 for an NPC, so the line can't be used to spot a bot.
(The missing headshot can, but the bots stand in the room in plain sight;
DecisionService already treats "which one is the NPC" as public.)

**Payoff table.** Always visible until the outcome shows. Words only: BIG,
MEDIUM, SMALL, ✕ NOTHING. Never the VU numbers, which are an internal
balancing unit that payoff-table.md says a player never sees. It adapts
to the seat count (3, 2 or 1). `tests/DecisionLogic.spec.luau` checks it
against `Outcomes.resolve` for every combination of choices at every seat
count, so the table can't tell a player something the resolver won't do.

## Choose: hold to confirm

A mis-tap here is unforgivable, so a lock takes **0.8 s of unbroken hold**
(`DecisionLogic.TIMING.holdSeconds`):

- A white fill rises through the button while you hold. Letting go early,
  or sliding more than 24 px off the button, cancels.
- A second thumb on the other button is ignored, not switched to. The
  first deliberate hold owns the lock.
- On completion the two buttons disappear, replaced by your choice under
  🔒 and the word **FINAL**. It reads "Locking…" until the server's
  `DecisionLockedIn` echo for you arrives. There is no undo in the UI or
  on the server.
- If no echo arrives in 1.5 s, the **same** choice is resent, up to twice.
  The server keeps the first submission and silently drops repeats, so a
  resend can't change anything.
- Keyboard: hold **Q** (Steal) / **E** (Share). Gamepad: hold **X** / **Y**.
  These are bound through ContextActionService, which doesn't fire while a
  TextBox has focus, so typing "q" in chat can't start a lock. A is jump
  and B is back, both too easy to hit by accident.

P6-4's `InputAdapters.Hold` isn't used: it binds A/Space globally for a
single target, and two hold targets on one screen would both fire from one
key.

Other seats show only 🔒 Locked, never which way.

## Reveal: synced to the server's timestamp

`DecisionReveal` carries `revealAt` (server time). Every step is a pure
function of `Clock.now() - revealAt` (`DecisionLogic.revealStep`). There is
no client-side timer, so two clients whose packets landed 0.4 s apart
show the same card at the same moment. A packet that lands late joins the
timeline part-way; it never restarts it.

| t after revealAt | |
|---|---|
| 0–1.0 s | a beat of silence |
| 1.0 s, 2.4 s, 3.8 s | seat 1, 2, 3 flip to Steal/Share (server's seat order, the same on every screen) |
| 5.0 s | the outcome line ("One thief walks away") and WINS / LOSES on each seat |
| 7.2 s | the personal result panel |

**Reduced motion** (`Env.reducedMotion`: the OS setting or the in-game
toggle): the same timeline, but each card cuts straight to its face instead
of flipping. The stagger stays because it's timing, not motion, and three
people reacting out loud need to see the same card at the same moment.

**Colour-blind safety.** Every Steal/Share face combines P6-1's
decision-pair colour (amber/blue, which survives all three CVD simulations
and greyscale) with a silhouette (diamond or pill), an icon, and the word.
WINS/LOSES is a word on a badge as well as a stroke colour.

## Result

The personal panel shows the headline for your side of the branch, the
bounty tier in words, and the streak line:

- Win: "MEDIUM bounty", "Streak 3".
- Loss: "No bounty", "**Your 7-win streak ends here**". It's the same size
  as the bounty line, neither hidden in a caption nor blown up into a
  headline. It offers no consolation and takes no cheap shot.
- A round with no streak credit (NPC-heavy) says so, on a win or a loss.

The streak numbers come from the new **`DecisionPersonalResult`**, fired by
`DecisionService.enterReveal` to each human finalist **alone** and **only
after** `DecisionReveal`. It is targeted because a streak is a Q7 number.
It comes after the reveal because "you won" plus your own choice is enough
to work out the others' choices.

The bounty is the outcome tier (BIG / MEDIUM / SMALL). The item package
itself is Q1's `RewardTables`, which doesn't exist yet. When it does, the
result panel is where the per-player item reveal goes.

`DecisionService` moves the round to Results about 1 s after the reveal
packet, but the reveal runs for about 7 s. The Studio screen therefore
stays up through Results until the player taps Continue or the round
leaves Results. **P6-6's results screen should wait on
`DecisionStudioController.isActive()`.**

## Text chat only

A player with no voice can do everything:

- The Negotiate channel is Roblox's own chat window (P3-3). The Studio's
  seats are pushed below that window when it's open
  (`DecisionLogic.chatInset`, read from `ChatWindowConfiguration.
  AbsolutePosition/AbsoluteSize`, capped at 30% of the screen), because
  CoreGui draws over PlayerGui and would otherwise cover the seats.
- Typing shows as 💬 Typing… on the typer's seat for the others
  (`StudioChatController`'s typing status). Speaking shows as 🎙, and a
  voice player's words don't appear in text. That's a real asymmetry, but
  the payoff table and every state are on screen, so nothing about the
  rules or the result is ever voice-only.
- No step depends on hearing a sound. The screen plays no audio.

## Secrecy audit

The requirement: the client never receives another player's choice
before the reveal packet. Here is what this client holds, and when, audited
against a full memory dump of it:

| What | Where it lives | When |
|---|---|---|
| Who the finalists are, and their reputation | `ids`, `reputations` (controller locals) | from `DecisionParticipants` |
| Who has locked | `locked`: a **set of ids** | from `DecisionLockedIn`, which is only ever `{playerId}` |
| Its own choice | `confirm` (a Vide source) | from its own completed hold |
| Everyone's choices | `reveal` | from `DecisionReveal` and nowhere else; `DecisionLogic.parseReveal` is the only function that produces a choice for another id |
| Its own streak before/after | `personal` | from `DecisionPersonalResult`, targeted, fired after the reveal |

- **Attributes / ValueObjects / replicated instances:** none written.
  Everything is Lua locals and Vide sources.
- **Preloaded animations:** none per outcome. Both Steal and Share faces
  are built for every seat at mount, from the same two tokens, so their
  existence says nothing. The reveal is a visibility change, not an asset
  chosen early.
- **`bountyVU`:** `DecisionReveal` does broadcast each winner's VU, and a
  VU is a function of streak tier. `parseReveal` drops it, so this client
  never keeps or shows it. It arrives *after* the result is in, which
  Q7's applied case permits for titles, but a modified client can still
  read it. Consider trimming it from the payload server-side (a one-line
  change, and nothing on the client needs it).
- **Fixed in P6-6: `ProgressionStreakSkipped` fired before the reveal.**
  `ProgressionService.applyRoundResult` fires it during
  `computeOutcomeAndWriteProfiles`, which runs about 0.2 s before
  `DecisionReveal` in an NPC-heavy round. Its `reason` says whether you won,
  and with your own choice that implies the others' choices. It has no
  strategic value, because every choice is already locked and irreversible
  by then. But it was the one pre-reveal channel. P6-6 removed the remote:
  its notice now travels in `RoundRecap`, sent on entering Results.

## Device review

Set `ReplicatedStorage:SetAttribute("UIDecisionStudioPreview", true)`.
The preview loops a whole finale on short timers (Intro 3 s, Negotiate 6 s,
Choose 8 s). Rivals take turns speaking and typing, then lock in at 2 s
and 4 s. You can hold Steal or Share for real. Each loop plays the next
branch (SoleSteal lost, LoneShare won, AllSteal, AllShare, SoleSteal won)
and alternates winning and losing a 7-win streak. Continue skips to the
next loop.

Screenshot at least: portrait 360×640 in each stage; landscape; OS reduced
motion on during a reveal; a colour-blind simulation of the payoff table
and the revealed cards.

## The set (2026-09-25)

Every finale, on every race map, happens on one shared set:
`ServerStorage.Maps.DecisionStudio`, built from the Blocky Cave place by
`scripts/build-decision-studio.luau`. Race maps no longer carry their own
Studio markers; the map validator treats them as optional.

- **Building it.** Run
  `lune run scripts/build-decision-studio "<Blocky Cave.rbxl>" "<out>.rbxm"`
  from the repo root. The script removes the ramp to the upper level (six
  wooden planks and the slate slope, matched by position, and it fails
  rather than guesses if the place changed). It then adds `StudioStage`
  (the `StudioAnchor` centre, three `StudioPodiumSlot` podiums with
  `SlotIndex` 1–3, and a `StudioBoundary`) and `StudioSpectators` (the
  `StudioSpectatorSpawn` lookouts and the `StudioSpectatorArea` box).
  In Studio, use Insert from File on `ServerStorage.Maps`.
- **Adjusting it.** The staging reads only tags, so moving `StudioStage`
  moves the whole podium ring, and each lookout pad can be dragged on its
  own. The positions were computed from the place's geometry rather than
  looked at. Check them in Studio.
- **Loading.** `StudioStageService` clones the set when the race
  resolves (`Qualified`), moves it `decisionStudioStage.offsetStuds`
  along +X so it can't overlap the race map. It is **not** destroyed at
  `Cleanup`. That's when everyone is sent home, and a teleport takes
  seconds, so deleting the floor dropped players into the void. The
  match server shuts down once everyone has left, and the set goes with
  it.
- **Chat box.** During Negotiate, a finalist gets a text field and a
  Send button at the top of the bottom panel. It sends into the
  Negotiate channel, and Enter sends too. Roblox's own chat bar is closed
  by default and easy to miss, especially on a phone. That chat bar is
  also pointed at the Negotiate channel while it's open
  (`StudioChatController`), so typing there reaches the other finalists
  instead of the general channel, which finalists are cut out of.

## After the finale

At `Cleanup`, `MatchTeleportService` sends everyone back to the hub in
one `TeleportAsync`, with `returnReason = "RoundOver"`, and the hub shows
"Round over. Press Play to queue for the next one." (design-decisions.md
Q6: the next round is a fresh queue). Anyone the teleport fails for is
kicked with the same message. In Studio there's no hub and teleports
don't work, so everyone respawns at the place's spawn instead.

## Staging

`StudioStageService`, at the start of Intro:

- **Finalists** (seat order after any Q3 promotion, NPCs included) stand
  on the podium matching their seat, facing the centre, so the three face
  each other. They're held there by anchoring the root part, and released
  when the round leaves `DecisionStudio`.
- **Everyone else** goes to a lookout on the walkway behind the east
  fence, facing the podiums. Anyone whose root leaves the
  `StudioSpectatorArea` box around that walkway is put straight back,
  checked 4 times a second. That covers climbing over the fence onto the
  rocks, dropping off the north end onto the terraces, and walking round
  the corner onto the south walkway.
- **A respawn** mid-finale goes back to the same podium or lookout.
- **Humans** have the spot streamed to them before they're moved
  (`MapStreaming.streamAround`), so nobody lands on unloaded floor.

**Watch-only spectators** (`StudioChat`). Spectators read the Negotiate
channel as members with `CanSend = false`. They hear the finalists'
voices, because each finalist's allow list includes them during
Negotiate. For the whole finale, finalists are out of `RBXGeneral` both
ways, and every spectator's voice denies the finalists. The rules live
in `StudioStageLogic` and are unit-tested.

## Not verified yet (device pass needed)

- **The set's positions** (see "The set"). Check that the podiums sit
  clear on the floor by the waterfall, that every lookout stands clear
  with a view of the podiums, and that no route down remains other than
  jumping, which is caught.
- **`TextSource.CanSend = false`** hides the send box for that channel,
  and bubble chat above the finalists shows to spectators.
- **Lighting.** The race map's lighting preset stays applied in the cave.

- `ChatWindowConfiguration.AbsolutePosition`'s coordinate space. The
  inset assumes it is screen space (with the top bar) and converts it into
  the ScreenGui's space. Check that the seats clear the open chat window
  on a phone.
- `AudioDeviceInput.Active` replicating to other clients, which
  StudioChatController already flags.
- The seat headshot for an NPC (negative id) is a blank disc. Confirm it
  reads as intentional.
- Landscape is a two-column fallback, not a designed layout.

## Open items handed on

- ~~**P6-6:** gate the results screen on `DecisionStudioController.isActive()`.~~
  Done: `MenuController` waits on it before opening Results.
- **Server:** ~~defer `ProgressionStreakSkipped` until after the reveal~~ (done in P6-6, as `RoundRecap`), and
  consider dropping `bountyVU` from `DecisionReveal` (see the secrecy audit).
- **Q1 `RewardTables`:** the per-player item reveal belongs in the result panel.
