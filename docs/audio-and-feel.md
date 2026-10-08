# Audio and game feel (P8-3)

The sound and the physical punch of *Don't Steal Bro!*. Code:
`src/client/UI/AudioLogic.luau` and `FeelLogic.luau` (pure, unit-tested
in `tests/`), `src/client/Controllers/AudioController.luau` and
`FeelController.luau` (the Roblox half), and `UI/Components/Feel.luau`
(the punch hook screens bind to).

Every cue has a real sound (§8). The controller still skips a
placeholder (`rbxassetid://0`) silently, so a cue can be blanked
without breaking anything.

## 1. The emotional brief

The game is built on tension. You race people you'll have to trust in
five minutes, then you find out if they betrayed you. The audio follows
that arc:

| Phase | Feeling | What the audio does |
|---|---|---|
| Hub | Loose, social, waiting | Warm ambience with no pulse. The queue-ready sting is the only sharp sound. |
| Race | Frantic, getting worse | The map's bed plus one shared tension stem that fades in as the clock runs down. Your own successes are bright and short. Being hit is low and ugly. |
| Qualified | Relief or sting | One big cue, and the music gets out of its way. |
| Decision Studio | Suspicion, talk | A sparse, low bed that leaves room for voice chat. |
| Lock-in | Commitment, no way back | A heavy, final click. |
| Reveal | Held breath | The music drops away. A riser, one hit per card, then the outcome. Nothing buries it. |
| Resolution | Triumph or gut-punch | The win and loss cues are clearly different lengths and registers. Loss is not just a sad version of win. |

## 2. Audio map

| Cue | Trigger | Category | Priority | Ducks music to |
|---|---|---|---|---|
| HubAmbience | no round / `WaitingForPlayers` | Music bed | — | — |
| QueueReady | `QueueState` enters `MatchFound` | SFX | 80 | 0.5 |
| RaceBed | `Loading`–`Qualified` | Music bed (map's `musicTrackId`, else fallback) | — | — |
| RaceTension | stem over RaceBed, 0 → 1 between 60 s and 20 s left | Music | — | — |
| TimerTick | once a second in the last 10 s | SFX | 60 | — |
| TaskStart | `TaskChallenge` | SFX | 50 | — |
| TaskSuccess / TaskStep / TaskFail | `TaskResult`: success, a step that landed, a step that missed (`AudioLogic.taskResultCue` reads the feedback; no feedback = silence) | SFX | 85 / 40 / 70 | 0.6 / — / — |
| PowerUpPickup | inventory count grows | SFX | 60 | — |
| PowerUpUsedByYou | `PowerUpUseResult.success` | SFX | 75 | — |
| PowerUpHitYou | a new debuff in `StatusEffectsChanged` | SFX | 90 | 0.55 |
| Qualified / NotQualified | `TaskQualificationResult` (spectators hear neither) | SFX | 95 / 90 | 0.25 / 0.4 |
| StudioBed | `DecisionStudio` | Music bed | — | — |
| LockIn / OtherLockIn | `DecisionLockedIn` (you / someone else) | SFX | 95 / 60 | 0.5 / — |
| RevealRiser, RevealCard ×n, RevealOutcome | `DecisionReveal`, timed on `DecisionLogic.revealStep` | SFX | 100 | 0.3 / 0.2 / 0.1 |
| RevealHeartbeat | lub + softer dub on each `DecisionLogic.heartbeats` beat under a face-down card; quiet → full card by card (`heartbeatVolume`), with a red edge glow per beat (FeelController) | SFX | 100 | — (the reveal's blanket duck) |
| Win / Loss | at the reveal's result time, for finalists only | SFX | 100 | 0.15 |

Race intensity has three layers. The tension stem fades in, the bed and
stem speed up by up to +5% (`PlaybackSpeed`) over the last 20 s, and
ticks play in the last 10 s. Intensity stops for a player who has
already qualified: the pressure belongs to the people still racing.

**By you vs on you.** These have to be told apart with your eyes closed,
so they differ in register *and* envelope, not just sample:

- **UsedByYou** is a bright, rising, fast-attack whoosh in the upper
  mids. It means "you did that".
- **HitYou** is a low, detuned hit with a short pitch drop. It ducks the
  music and outranks UsedByYou in the voice budget.

Buffs you applied to yourself play UsedByYou only. They never count as
a hit.

**Spatial vs 2D.** Every cue is 2D today. Anything about your own state
has to reach you on a phone speaker whichever way the camera faces. The
one natural spatial cue, a rival's station finishing across the room,
would need the station id in `TaskProgress`. That payload is counts-only
on purpose: carrying station ids would hand every client every rival's
route (see the `TaskProgress` / `TaskAssignmentState` comments in
`Net.luau`). `AudioController.play(cue, part)` supports
spatial cues for when a safe one exists.

## 3. Game feel

Only four moments get a punch. If everything shakes, nothing does.

| Moment | Shake (studs / Hz / s) | Hit-stop | UI punch (peak / attack / release) | Particles |
|---|---|---|---|---|
| Task complete | 0.12 / 18 / 0.18 | 0.06 s | task bar 1.12 / 0.06 / 0.22 | 18, speed 14, `success` |
| Qualified | 0.30 / 14 / 0.45 | 0.12 s | placement card 1.20 / 0.08 / 0.40 | 60, speed 22, `brand` |
| Lock-in | 0.08 / 22 / 0.12 | 0.05 s | locked card 1.08 / 0.05 / 0.20 | — |
| Reveal card (each) | 0.10 / 16 / 0.15 | — | title 1.06 / 0.05 / 0.18 | — |
| Reveal outcome | 0.35 / 12 / 0.60 | 0.15 s | title 1.15 / 0.08 / 0.45 | 40, speed 18, `brand` |

- **Shake** uses `Humanoid.CameraOffset`, so it rides on the default
  camera instead of fighting it. It's two sines at a 1.37 ratio under a
  quadratic decay. When shakes overlap, the stronger one wins; they don't
  add.
- **Hit-stop** pauses your own character's animation tracks. It's local
  presentation only. The server never pauses, so it gives nobody an
  advantage. Overlapping stops extend the one already running.
- **Punch** is a `UIScale` on the element itself, never the screen root.
  The root's scale belongs to UIScaleController, and punching a whole
  screen would push its edges into the notch.
- **Particles** come from one pooled emitter per colour on the root
  part, always fired with `:Emit`, never left running.

**Reduced motion** (Roblox's setting or ours, read when the moment
fires): no shake, no punch and no hit-stop. Each moment gets an
opacity-only full-screen flash in its colour instead. Qualified and the
outcome keep a quarter of their particles at zero speed: a glow that
fades in place rather than a spray.

## 4. Mobile constraints

**Concurrent sounds.** At most 8 one-shot SFX plus 3 music loops (the
bed, the tension stem, and a crossfade tail). Past 8, the lowest-priority
oldest voice is cut if the new cue outranks it; otherwise the new cue is
dropped. Reveal and resolution cues are priority 100 and are never
dropped. Each cue also has a cooldown, and a pool of 3 Sounds per cue, so
a burst of server events can't stack identical sounds. **The 8 is a
PLACEHOLDER**: measure it on the reference Android device with P8-2's
profiling protocol (perf-report.md) and adjust `MAX_SFX_VOICES`.

**On a speaker in a noisy room.** We can't detect it (reading the mic for
ambient level isn't available to us, and players wouldn't expect it), so
every cue is designed for it:

- Phone speakers roll off below ~300 Hz. Every cue carries its meaning
  in 1–4 kHz. The low body of HitYou is extra weight, not the message.
- Short transients over pads: an attack cuts through room noise, a swell
  doesn't.
- Master SFX about 6 dB hotter than the music beds. The default slider
  mix (music 0.6, SFX 0.8) and the ducking push the same way.
- Nothing depends on stereo. Every cue is 2D, and a phone speaker is
  mono anyway.

**Cues that must have a visual equivalent.** Assume the sound is never
heard.

| Cue | Visual equivalent | Status |
|---|---|---|
| TaskSuccess / TaskFail | task view status pulse (TaskViewBase), task bar punch | ✅ |
| TimerTick / race intensity | countdown ring | ✅ |
| PowerUpHitYou | screen-edge treatment (HudLogic) | ✅ |
| PowerUpPickup / UsedByYou | inventory slot fills / empties | ✅ |
| LockIn | locked card and its punch | ✅ |
| Reveal cues, Win / Loss | cards, outcome banner, result panel | ✅ |
| Qualified / NotQualified | placement card punch (qualifiers only); the Results screen comes later | ⚠️ **gap:** no immediate on-screen beat for NotQualified, and Qualified has only the punch. A "You qualified!" / "Not this time" banner at the moment of `TaskQualificationResult` is a follow-up. |
| QueueReady | the menu's queue status | ⚠️ confirm the `MatchFound` state is visually distinct in the queue UI |

## 5. Lifecycle and cleanup

- **Beds** crossfade over 1.5 s when the round state changes. A bed at
  zero is stopped, not left playing silently. The race bed swaps to a
  new map's track only while it's silent.
- **Round end.** `Loading`, `Cleanup` and `WaitingForPlayers` stop every
  one-shot, clear every duck, reset per-round state (qualified,
  debuff history, ticks, inventory count, personal result), and bump a
  round token. Any reveal cue still scheduled with `task.delay` checks
  the token and stays silent.
- **Late reveal packets** join part-way, the same as the visuals. Cues
  more than 0.25 s in the past are skipped, not replayed in a burst.
- **Volume.** Everything routes through the `Music` / `SFX`
  SoundGroups, which SettingsController drives from the player's
  sliders. Ducking and per-cue volume are written on the Sound, so they
  multiply with the slider rather than overwrite it.

## 6. Adding a cue

Add one row to `AudioLogic.CUES`, then call `AudioController.play("Id")`
from whatever triggers it (or add a listener there if it's a network
event). The spec's invariants (volume range, SFX never looped,
reveal/resolution at priority 100) cover the new row automatically.

## 7. Verify in Studio

None of this can be checked headlessly. Check it with real assets:

1. The reveal is audible over the Studio bed at max music / min SFX
   sliders.
2. Race the timer down in a debug round and listen: the tension stem
   arrives smoothly, ticks land once per second, and the stem goes quiet
   the moment you qualify.
3. Spam a power-up at yourself from a second client: no stacked hits
   within the cooldown, and the voice count never exceeds 8 (watch
   `SoundService.AudioPool`).
4. Force `Cleanup` mid-reveal: silence, and nothing plays late.
5. Turn on reduced motion: no camera movement, flashes only.
6. Respawn mid-round, then complete a task: particles fire on the new
   character.

## 8. The sounds (next-stages 14a, 2026-10-08)

**Licensing rule:** every sound comes from a library Roblox licenses to
all experiences: Roblox's own `Roblox_UI_*` pack (creator Roblox),
**APMOfficial** (APM Music) and **ProSoundEffects**. Never take a sound
from a random user upload. Those are often ripped from other games
(Minecraft, TF2 and the like) and get taken down, which silently mutes
the cue live. All picks and alternates below were checked to load in a
Match playtest.

Picks were made from library names and descriptions, without listening.
**Audition every one** at `https://create.roblox.com/store/asset/<id>`. To
swap one, change its `assetId` in `AudioLogic.CUES`.

| Cue | Pick | Alternates |
|---|---|---|
| HubAmbience | 80257380636383 APM "Game Lobby" (182 s), owner's pick, volume 0.25 | 1844644501 APM "Ballroom Fox"; 1845880323 APM "Sly Sophie" (123 s); 15675069601 Roblox_UI_Loop_Calm_Music |
| RaceBed | 1837768143 APM "Big League (c)" (122 s) | maps can each set their own `musicTrackId` (all are still placeholders) |
| RaceTension | 9043365842 APM "HEARTBEAT 02 96BPM": no key, so it sits on any bed | 9043366464 APM "TICK TOCK 06 120BPM" (would compete with TimerTick) |
| StudioBed | 1843943906 APM "Tension Repeat Drones 40" | 9112795463 PSE "Hollow Rumble 1" (drone loop) |
| QueueReady | 15675043410 Roblox_UI_Tonal_Stinger | 1840084286 APM "Musical Doorbell (d)" |
| TimerTick | 9114212929 PSE "Dvd Player Button 13" (hard click) | 15675032796 Roblox_UI_Small_Click |
| TaskStart | 15675059323 Roblox_UI_Bright_Click | — |
| TaskSuccess | 9048770070 APM "Seven Leaf Clover - Hit3" (mallets) | 15675016548 Roblox_UI_Piano_Hello |
| TaskStep | 9114380768 PSE "Fat Beeps Bubble Like Bursts 1" (unauditioned) | 15675032796 Roblox_UI_Small_Click |
| TaskFail | 9113085665 PSE "Alarm Buzzer 3" | 15675075163 Roblox_UI_Delete |
| PowerUpPickup | 15675055424 Roblox_UI_Cute_Pop | — |
| PowerUpUsedByYou | 9120733055 PSE "Whoosh Rising Swish Airy 1" | 9120733724 (same set, other pitch) |
| PowerUpHitYou | 9113520887 PSE "Body Hit With Rubber Glove 7" | 9113572282 PSE "Boxing Hits 10"; 1841250549 APM "Bludgeon" |
| Qualified | 1837769261 APM "Time Attack (sting)" | 9047102381 APM "Game Day Warrior Sting 1" |
| NotQualified | 9125449274 PSE conch-shell honk (weak, deflating) | 9047060880 APM "Slow Fuse Sting" |
| LockIn | 9119727134 PSE "Switch Impact On Flip Up Large Metal 2" | 9120371230 PSE "Vehicle Door Bump Slamming Metal Door 9" |
| OtherLockIn | 9114214262 PSE "Dvd Player Button 4" | — |
| RevealRiser | 9043343295 APM "REVERSE NOISE HARD END 09", `startAt` 1.1 s | 1837834352 APM "REVERSE HARD STOP-Metal Build 02" (4.0 s: use `startAt` 1.0) |
| RevealHeartbeat | 9114457494 PSE "Fist Hit Sofa 1": a muffled thud, played twice per beat (unauditioned) | 9114036353 PSE "Deep Impacts 3"; 9113041746 PSE "Acoustic Whomps 2" |
| RevealCard | 9038652624 APM "Big Hair Rock - Hit 3" | 9116710746 PSE "Metal Impacts Hard Clanking Hits 5" |
| RevealOutcome | 1835333323 APM "Angry Heavy Hitter Hit" | 1839696994 APM "Fatal Impact" |
| Win | 9038758612 APM "Tomorrow Begins Today - Stinger" (13 s, bright) | 9047296345 APM "Welcome Home Sting" |
| Loss | 110140058364323 APM "Pathos and Persistence - Sting 2" (5 s, low) | 9048284985 APM "Dirty Secrets - Sting 1" |

**`startAt`** (`CueDef`) starts a one-shot partway into its asset. The
riser's hard stop is 4.1 s in, and the first card turns 3.0 s after the
riser starts (`DecisionLogic` `lead`), so the riser starts at 1.1 s. If
`lead` changes, change `startAt` with it.

**Finding more:** the Creator Store's v2 search API
(`apis.roblox.com/toolbox-service/v2/assets:search?searchCategoryType=Audio&query=...`)
returns creator names and durations, so the results can be filtered
down to the three libraries above. Keyword search ranks popular user
uploads first, so the licensed sounds sit deep in the results. Search
ProSoundEffects with its own literal vocabulary ("Whoosh Rising Swish",
"Alarm Buzzer"). Abstract game words like "level complete" find
nothing there.
