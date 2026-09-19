# Don't Steal Bro! — Mini-Task Catalogue (P0-2)

15 mini-tasks forming the pool `TaskService` draws each player's personal
task list from at round start (per `gdd.md`, players race a *subset*, not
all 15, per round). Each task below is exactly one
`src/shared/Config/Tasks/<Name>.luau` definition and at most one
`src/server/TaskHandlers/<Name>.luau` validator, per the architecture doc's
scaling rule — no `RoundService`/`TaskService` changes to add a 16th.

**Scaling beyond 15.** 15 tasks reused identically across 11 maps risks
getting stale fast — this catalogue is a first slice, not the ceiling.
Growing the pool to ~45 is purely additive: more `Config/Tasks/*.luau`
files, more matching `TaskHandlers/*.luau` validators (reusing the shared
challenge helpers noted per-task below where a pattern repeats), and more
entries in each map's accepted-task-ids list (P0-5). No service code
changes. A bigger pool also compounds with the personal-task-list mechanic
above — the random subset a player races each round gets more varied as
the pool grows, which is the actual lever against repetition, not just
raw task count.

**Shared validation principle (Ground Rule 1):** every task's server handler
issues a fresh, randomized challenge when a player interacts with a station
— a target count, a sequence, a timing window, an aim position — and the
client only ever sends *intents* (a tap event, a drag-drop, a stop signal)
against that server-held state. The server never accepts a client-reported
"done." This is what makes every task in this catalogue immune to
"fire one remote, task completes instantly": the remote payload alone,
without the server's privately-held random state, is never sufficient to
pass.

**One-thumb constraint (Ground Rule 3):** every task is screen-space
tap/hold/drag input against 2D UI or a single 3D interact prompt. None
requires simultaneous camera control — the hard constraint from the brief.

## Summary

| id | Display name | Verb | Target time | Mobile |
|---|---|---|---|---|
| `pressure-valve` | Pressure Valve | Tap | 6–8s | 5/5 |
| `vent-purge` | Vent Purge | Tap | 5–7s | 5/5 |
| `alarm-killswitch` | Alarm Killswitch | Hold | 4–6s | 5/5 |
| `crate-winch` | Crate Winch | Hold | 7–9s | 4/5 |
| `cable-splice` | Cable Splice | Drag | 8–11s | 4/5 |
| `lock-tumbler` | Lock Tumbler | Drag | 9–12s | 3/5 |
| `fuse-rewire` | Fuse Rewire | Drag | 8–10s | 4/5 |
| `breaker-sequence` | Breaker Sequence | Sequence | 7–10s | 5/5 |
| `code-playback` | Code Playback | Sequence | 9–13s | 4/5 |
| `morse-relay` | Morse Relay | Sequence | 10–14s | 3/5 |
| `reactor-sync` | Reactor Sync | Timing | 6–9s | 5/5 |
| `conveyor-sort` | Conveyor Sort | Timing | 8–12s | 4/5 |
| `airlock-cycle` | Airlock Cycle | Timing | 5–7s | 5/5 |
| `turret-calibration` | Turret Calibration | Aim | 7–10s | 3/5 |
| `sensor-sweep` | Sensor Sweep | Aim | 8–11s | 3/5 |

---

## 1. Pressure Valve — `pressure-valve`

**Fantasy:** Vent a bursting pipe before the gauge maxes out and blows.

**Verb:** Tap. **Target time:** 6–8s for an average player.

**Failure/retry:** If the gauge fills to 100% before the tap target is met,
it resets to 0% (small time cost, no lockout) and the player can
immediately retry.

**Server validation:** On interact, the server rolls a private target tap
count (18–24) and starts a server-side counter. Each tap is a `Net.Tasks.Tap`
intent; the server increments its own counter only if the elapsed time
since the last accepted tap exceeds a minimum human interval (~70ms),
silently dropping faster taps rather than erroring (so a script macro
gains nothing — it just gets rate-limited to human speed). Completion
fires when the server's counter, not the client's, reaches the rolled
target.

**Mobile feasibility:** 5/5 — a single large tap zone, no drag precision
needed, thumb never leaves the same spot.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Jammed fire alarm hammer |
| Factory | Steam relief valve |
| Museum | Burst sprinkler valve |
| Laboratory | Coolant pressure bleed |
| Mall | Fire-suppression valve |
| Construction Site | Jackhammer air valve |
| Space Station | O2 scrubber vent |
| Bunker | Blast-door pressure equalizer |
| Aircraft Carrier | Boiler steam valve |
| Prison | Cell-block klaxon silencer |
| Deserted Island | Geyser vent stone |

## 2. Vent Purge — `vent-purge`

**Fantasy:** Clear a toxic gas buildup by punching an extractor fan control
in a burst before you're forced to step back.

**Verb:** Tap. **Target time:** 5–7s.

**Failure/retry:** A rising "gas" meter forces the player to release and
back off if it isn't cleared in time; meter and tap progress both reset,
retry is immediate.

**Server validation:** Same pattern as Pressure Valve — server-rolled tap
target (distinct range, 14–20) and server-side minimum-interval
enforcement — but the *gas meter* is also server-authoritative and ticks up
on a fixed server heartbeat independent of client frame rate, so a low-FPS
or throttled client can't stall the failure clock in its favour.

**Mobile feasibility:** 5/5 — identical ergonomics to Pressure Valve; kept
distinct as a reskin-only variant to give re-use without asset fatigue.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Chemistry-lab fume extractor |
| Factory | Exhaust scrubber fan |
| Museum | HVAC purge switch |
| Laboratory | Biohazard containment vent |
| Mall | Food-court grease extractor |
| Construction Site | Dust extraction fan |
| Space Station | Airlock decontamination purge |
| Bunker | NBC filtration override |
| Aircraft Carrier | Engine room smoke extractor |
| Prison | Tear-gas ventilation override |
| Deserted Island | Smoke-signal bellows |

## 3. Alarm Killswitch — `alarm-killswitch`

**Fantasy:** Hold down a stiff breaker to kill a blaring alarm before time
runs out.

**Verb:** Hold. **Target time:** 4–6s.

**Failure/retry:** Releasing early resets progress to 0; no penalty beyond
the lost time, retry immediately.

**Server validation:** `Net.Tasks.HoldStart`/`HoldStop` intents bracket the
hold; the server times the interval itself using its own clock
(`workspace:GetServerTimeNow()`), not a client-reported duration, and
requires a server-rolled minimum hold length (4.5–6.5s) with no upper
bound exploit available since holding longer than needed just wastes the
player's own time.

**Mobile feasibility:** 5/5 — press-and-hold is the most reliable one-thumb
gesture on touch, no drag precision.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Stuck fire-alarm pull |
| Factory | Emergency stop breaker |
| Museum | Silent-alarm override |
| Laboratory | Containment klaxon breaker |
| Mall | PA system cutoff |
| Construction Site | Site siren breaker |
| Space Station | Hull-breach alarm silence |
| Bunker | Air-raid siren cutoff |
| Aircraft Carrier | General-quarters silence |
| Prison | Riot alarm breaker |
| Deserted Island | Signal-drum lash release |

## 4. Crate Winch — `crate-winch`

**Fantasy:** Hold a winch lever to hoist a crate into position without
letting it swing loose.

**Verb:** Hold (with a light balance element). **Target time:** 7–9s.

**Failure/retry:** A "sway" meter creeps up while held past a safe rate;
if it maxes, the crate drops back to start height. No hard lockout, retry
continues from a partial reset rather than fully zeroing, to keep the
"balance" skill element from feeling punishing.

**Server validation:** The server owns the crate's height and sway values
entirely; the client's hold intent only tells the server *that* the button
is down, and the server integrates height/sway itself on a fixed tick.
There's no client-reported position ever trusted.

**Mobile feasibility:** 4/5 — still a single hold gesture, but the
sway-management adds a light attention cost; noted as the ceiling of what
"Hold" can ask for one-thumb.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Stage-set counterweight |
| Factory | Overhead pallet winch |
| Museum | Exhibit crate hoist |
| Laboratory | Isolation chamber lift |
| Mall | Loading-dock hoist |
| Construction Site | Material hoist |
| Space Station | Cargo bay winch |
| Bunker | Supply crate lift |
| Aircraft Carrier | Elevator cargo winch |
| Prison | Laundry cart hoist |
| Deserted Island | Vine-and-pulley lift |

## 5. Cable Splice — `cable-splice`

**Fantasy:** Drag loose cable ends to their matching sockets to restore
power.

**Verb:** Drag. **Target time:** 8–11s.

**Failure/retry:** A wrong socket match doesn't fail the task outright —
the cable snaps back to its start position and the player can retry that
one connection; the whole task only fails (partial reset) if a server-set
attempt cap per cable is exceeded, discouraging blind trial-and-error.

**Server validation:** The server randomly assigns the correct
cable→socket mapping per attempt (not a fixed puzzle) and only accepts a
completion when every cable's *server-recorded* socket assignment matches;
the client's drag is purely a UI convenience — the actual "drop" intent
sent to the server is a (cableId, socketId) pair the server checks against
its own private mapping, so reading the client's UI state doesn't reveal
the right answer without also successfully performing the drag.

**Mobile feasibility:** 4/5 — drag-and-drop works well one-thumb on touch,
but socket hit-boxes need generous tolerance so a large thumb doesn't
obscure the drop target; flagged for playtest sizing.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Overhead projector cabling |
| Factory | Control panel wiring |
| Museum | Exhibit power cabling |
| Laboratory | Instrument patch panel |
| Mall | Sign/lighting junction box |
| Construction Site | Generator feed lines |
| Space Station | Conduit patch bay |
| Bunker | Comms relay patch panel |
| Aircraft Carrier | Bridge systems patch bay |
| Prison | Cell-block power junction |
| Deserted Island | Salvaged radio wiring |

## 6. Lock Tumbler — `lock-tumbler`

**Fantasy:** Drag a set of pins to their release heights to pick a jammed
lock.

**Verb:** Drag. **Target time:** 9–12s.

**Failure/retry:** Releasing a pin outside its (server-hidden) tolerance
band doesn't fail the task — it just doesn't lock in, so the player
re-drags; a hard fail only occurs on a server-tracked time-out, resetting
all pins.

**Server validation:** Each pin's correct height band is rolled server-side
per attempt; the client sends a continuous drag-position stream, and the
server itself decides when a pin has settled within tolerance and locks it
— the client cannot claim "locked" directly.

**Mobile feasibility:** 3/5 — the lowest-rated task in the set: several
independent drag targets at once asks more precision of a single thumb
than the others; keep the pin count low (3–4) and hitboxes generous, or
cut this one if playtesting shows frustration.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Jammed supply-closet padlock |
| Factory | Tool-crib combination lock |
| Museum | Display-case tumbler lock |
| Laboratory | Restricted-cabinet lock |
| Mall | Security-shutter lock |
| Construction Site | Site-office padlock |
| Space Station | Cargo-hold mag-lock override |
| Bunker | Vault door tumbler |
| Aircraft Carrier | Armory lock |
| Prison | Cell tumbler lock |
| Deserted Island | Carved wood-and-vine latch |

## 7. Fuse Rewire — `fuse-rewire`

**Fantasy:** Drag replacement fuses into a blown panel in the right slots
by amperage.

**Verb:** Drag. **Target time:** 8–10s.

**Failure/retry:** A fuse dropped in the wrong slot bounces back to the
tray with no penalty; only a full time-out resets the whole panel.

**Server validation:** Correct amperage-to-slot mapping is rolled per
attempt server-side; each drop is a (fuseId, slotId) intent checked against
the server's private mapping, same pattern as Cable Splice — deliberately
reused so `TaskHandlers` can share one `SlotMatchChallenge` helper module
instead of three near-duplicate implementations.

**Mobile feasibility:** 4/5 — same ergonomics as Cable Splice; fewer,
larger drop targets than Lock Tumbler keeps this one comfortable.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Boiler room fuse box |
| Factory | Main distribution panel |
| Museum | Climate-control fuse panel |
| Laboratory | Equipment fuse rack |
| Mall | Escalator fuse panel |
| Construction Site | Site power fuse box |
| Space Station | Power distribution node |
| Bunker | Backup power fuse rack |
| Aircraft Carrier | Damage-control fuse panel |
| Prison | Cell-block fuse box |
| Deserted Island | Salvaged battery bank |

## 8. Breaker Sequence — `breaker-sequence`

**Fantasy:** Flip a bank of switches in the exact order a control panel
flashes at you.

**Verb:** Sequence (tap in order). **Target time:** 7–10s.

**Failure/retry:** A wrong tap replays the sequence once more from the
start (server re-flashes it) rather than hard-failing, up to a
server-tracked retry cap before a full task reset.

**Server validation:** The server generates the sequence (4–6 switches,
randomized order) and sends it to the client purely for display; each tap
intent references a switchId, and the server checks it against its own
sequence index — a client can't shortcut this by replaying a previous
round's sequence since it's freshly rolled every attempt.

**Mobile feasibility:** 5/5 — discrete taps on fixed large buttons, the
easiest "Sequence" implementation to get right on a small screen.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Gym scoreboard breaker bank |
| Factory | Assembly-line switch bank |
| Museum | Gallery lighting bank |
| Laboratory | Equipment power sequencer |
| Mall | Storefront lighting bank |
| Construction Site | Floodlight switch bank |
| Space Station | Systems startup sequencer |
| Bunker | Blast-door power sequencer |
| Aircraft Carrier | Flight-deck lighting bank |
| Prison | Block lighting sequencer |
| Deserted Island | Signal-fire relay switches |

## 9. Code Playback — `code-playback`

**Fantasy:** Watch a keypad flash a code, then re-enter it from memory.

**Verb:** Sequence (memory + tap). **Target time:** 9–13s.

**Failure/retry:** A wrong digit ends the attempt and the server flashes a
new (shorter, easier) code as a soft catch-up mercy after 2 consecutive
fails, so the task doesn't become a hard wall for players with average
short-term recall under race pressure.

**Server validation:** Same rolled-sequence pattern as Breaker Sequence,
reusing the same `TaskHandlers` helper — the only difference is the
client-side view hides the sequence after a display window instead of
leaving it visible, which is a `TaskViews` presentation detail, not a
server-trust difference.

**Mobile feasibility:** 4/5 — fine on a large numeric keypad; rated below
Breaker Sequence only because the memory element adds real difficulty
variance across players, not an input ergonomics problem.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Locker override keypad |
| Factory | Machine safety-interlock keypad |
| Museum | Archive room keypad |
| Laboratory | Cold-storage keypad |
| Mall | Stockroom keypad |
| Construction Site | Site-office safe keypad |
| Space Station | Airlock override keypad |
| Bunker | Vault keypad |
| Aircraft Carrier | Weapons-locker keypad |
| Prison | Control-room keypad |
| Deserted Island | Carved rune lock (numeral stand-ins) |

## 10. Morse Relay — `morse-relay`

**Fantasy:** Listen to (or watch, captioned) a short pulse pattern and tap
it back on a signal key.

**Verb:** Sequence (rhythm). **Target time:** 10–14s.

**Failure/retry:** Timing tolerance is generous on the first playback and
tightens slightly on retries, capped at a floor so it never becomes
unfair; a failed attempt gets one free replay of the pattern before a full
reset.

**Server validation:** The server generates the pulse pattern (a list of
tap/gap durations) and the tolerance window per attempt; each tap intent's
server-received timestamp is compared against the server's own expected
window — never the client's self-reported timing — so a script tapping
with mathematically perfect intervals still has to beat real network
jitter tolerance, not an easier client-side check.

**Mobile feasibility:** 3/5 — rhythm-based input is inherently harder on
touch than a discrete-choice sequence; ship with a visual pulse (not
audio-only) so it doesn't exclude players without sound, and flag for
playtest whether the tolerance window needs widening on mobile input
latency specifically.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Radio-club Morse key |
| Factory | Emergency signal buzzer |
| Museum | Antique telegraph exhibit |
| Laboratory | Comms test rig |
| Mall | PA test signal key |
| Construction Site | Site radio relay |
| Space Station | Deep-space comms relay |
| Bunker | Backup comms key |
| Aircraft Carrier | Signal lamp relay |
| Prison | Tap-code cell wall |
| Deserted Island | Coconut signal drum |

## 11. Reactor Sync — `reactor-sync`

**Fantasy:** Stop a sweeping needle inside a narrow "safe" band to
synchronize a reactor.

**Verb:** Timing (tap-to-stop). **Target time:** 6–9s.

**Failure/retry:** Missing the band doesn't fail outright — it costs a
server-tracked attempt out of 3 before the sweep speed resets to the
(easier) starting speed, so a bad first attempt doesn't spiral.

**Server validation:** The server runs the needle sweep itself
(position as a function of server time, not a client animation) and the
stop intent's server-received timestamp is mapped through that same
function to get the actual stop position — the client's own rendered
needle is just a visual interpolation of server state, so reading client
memory for "needle position" doesn't help an exploiter place a stop with
certainty when latency jitter is added server-side.

**Mobile feasibility:** 5/5 — one tap to stop a moving element is a
proven mobile-friendly pattern (rhythm games, golf-swing meters).

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Science-fair generator sync |
| Factory | Turbine phase sync |
| Museum | Planetarium projector sync |
| Laboratory | Particle collider sync |
| Mall | Backup generator sync |
| Construction Site | Site generator sync |
| Space Station | Reactor core sync |
| Bunker | Backup reactor sync |
| Aircraft Carrier | Engine-room turbine sync |
| Prison | Generator room sync |
| Deserted Island | Waterwheel alignment |

## 12. Conveyor Sort — `conveyor-sort`

**Fantasy:** Tap items as they pass on a belt, sorting the right ones
before they fall off the end.

**Verb:** Timing (reactive tap). **Target time:** 8–12s.

**Failure/retry:** Missing or wrongly tapping an item doesn't fail the
task — it costs one of a server-tracked mistake budget (2–3); exceeding
the budget resets the belt run, not the whole task's earlier progress.

**Server validation:** Item spawn times, types, and belt speed are all
server-simulated; a tap intent references a specific spawned itemId and
the server checks both correctness (is this a target item) and timing
(did it arrive within the tap zone's server-computed window) — the visual
belt is a client render of server state, not the source of truth.

**Mobile feasibility:** 4/5 — reactive single-target tapping suits one
thumb well; rated just below the top tier since sustained attention across
8–12s of moving targets is a slightly higher skill floor than a single
static input.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Cafeteria tray sort |
| Factory | QA reject-line sort |
| Museum | Artifact crate sort |
| Laboratory | Sample vial sort |
| Mall | Package sort belt |
| Construction Site | Material sort belt |
| Space Station | Cargo sort conveyor |
| Bunker | Supply sort line |
| Aircraft Carrier | Munitions sort belt |
| Prison | Laundry sort line |
| Deserted Island | Driftwood/salvage sort |

## 13. Airlock Cycle — `airlock-cycle`

**Fantasy:** Time a door cycle so you seal the chamber in the narrow gap
between two moving hazard indicators.

**Verb:** Timing (tap-to-commit). **Target time:** 5–7s.

**Failure/retry:** A bad cycle just replays (no penalty beyond the lost
time); the door mechanism is stateless between attempts by design so
this stays the "gentlest" timing task in the set.

**Server validation:** Same sweep-function pattern as Reactor Sync,
reusing the same `TaskHandlers` timing-window helper with a different
speed/tolerance profile — again deliberate reuse rather than a bespoke
implementation.

**Mobile feasibility:** 5/5 — simplest timing task in the catalogue, good
as an early/tutorial-weight task.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Gym door interlock (re-flavoured, no real airlock) |
| Factory | Clean-room airlock |
| Museum | Climate-sealed vault door |
| Laboratory | Biohazard airlock |
| Mall | Pressurized loading dock door |
| Construction Site | Pressure-sealed site trailer |
| Space Station | Hull airlock |
| Bunker | Blast airlock |
| Aircraft Carrier | Watertight hatch cycle |
| Prison | Sally-port double-door |
| Deserted Island | Tide-cave entrance timing |

## 14. Turret Calibration — `turret-calibration`

**Fantasy:** Drag a reticle onto a moving target and hold it there long
enough to lock calibration.

**Verb:** Aim (drag reticle + dwell). **Target time:** 7–10s.

**Failure/retry:** Losing the lock (reticle drifts off target) just resets
the dwell timer, not the whole task; no hard fail state, only elapsed
time cost.

**Server validation:** Target movement path is server-simulated from a
per-attempt random seed; the client streams reticle position intents, and
the server itself checks whether that position falls within its own
computed target-hitbox each tick, accumulating server-side dwell time —
a client claiming "locked" without matching server-side dwell is ignored.

**Mobile feasibility:** 3/5 — dragging a reticle precisely with one thumb
while also seeing the moving target is the most demanding "Aim" case in
the set; keep the target's movement slow and its hitbox generous, and
flag for playtest as a likely candidate to simplify (e.g., a chase-and-tap
variant instead of true drag-aim) if mobile testers struggle.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Robotics-club sensor calibration |
| Factory | Automated arm calibration |
| Museum | Planetarium telescope alignment |
| Laboratory | Laser array calibration |
| Mall | Security camera calibration |
| Construction Site | Survey laser alignment |
| Space Station | Point-defense turret calibration |
| Bunker | Perimeter sensor calibration |
| Aircraft Carrier | Radar dish calibration |
| Prison | Searchlight calibration |
| Deserted Island | Signal-mirror alignment |

## 15. Sensor Sweep — `sensor-sweep`

**Fantasy:** Sweep a directional scanner across a room to find and tag
hidden signal sources before they fade.

**Verb:** Aim (sweep + tap-to-tag). **Target time:** 8–11s.

**Failure/retry:** A signal source that fades untagged simply respawns
elsewhere after a short delay — no fail state, just lost time, since this
is the last task added and deliberately kept low-frustration to balance
Lock Tumbler and Turret Calibration's higher difficulty.

**Server validation:** Source positions and fade timers are rolled and
tracked entirely server-side; a "tag" intent includes a screen-space aim
direction which the server resolves against its own source positions
(with a generous tolerance cone) — the client never learns a source's true
position until the server confirms a tag, so reading client state in
advance doesn't reveal the answer.

**Mobile feasibility:** 3/5 — sweeping a directional UI element with one
thumb is comfortable, but combined with reactive tagging it's a genuine
skill task; still easier than Turret Calibration since there's no
sustained dwell requirement.

**Reskin:**

| Theme | Reskin |
|---|---|
| School | Metal-detector sweep (lost keys) |
| Factory | Leak-detector sweep |
| Museum | Artifact authenticity scanner |
| Laboratory | Contamination scanner |
| Mall | Lost-item scanner |
| Construction Site | Rebar/utility line scanner |
| Space Station | Hull-breach scanner |
| Bunker | Radiation sweep |
| Aircraft Carrier | Sonar contact sweep |
| Prison | Contraband scanner |
| Deserted Island | Buried-cache metal detector |

---

## Build-first shortlist

**1. Pressure Valve.** The simplest possible task: one input type, one
server-side counter, no drag precision or timing-window maths. This proves
the whole `Config/Tasks` → `TaskHandlers` → `TaskViews` plumbing and the
progress-remote round-trip with the least surface area for bugs, so any
integration problems found here are framework problems, not task-specific
ones.

**2. Cable Splice.** The riskiest *input modality* to validate early — drag
gestures behave very differently across phone screen sizes and thumb
reach than taps do, and this task's (source, target) intent pattern is
reused by both Lock Tumbler and Fuse Rewire. Proving it works well one-
thumb on a real cheap Android device early avoids discovering a systemic
drag-ergonomics problem after three tasks are already built on it.

**3. Reactor Sync.** Proves the server-owned-sweep-function pattern (state
as a function of server time, not client animation) that Airlock Cycle
directly reuses and that Conveyor Sort and Turret Calibration are
variations of. It's also the cleanest demonstration of the catalogue's
core anti-exploit principle — the client visual is provably just an
interpolation of server state — which is worth proving once, deliberately,
rather than assuming it holds across every timing-based task later.
