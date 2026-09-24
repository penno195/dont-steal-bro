# Don't Steal Bro! — Playtest Protocol (P8-4)

The closed-beta playtest kit. It's built to run with friends on a
Discord call, not in a usability lab. You need one moderator, six
players, and about 75 minutes.

What's in here:

1. [Moderator script](#1-moderator-script)
2. [Observation sheet](#2-observation-sheet)
3. [Post-session survey](#3-post-session-survey)
4. [Issue templates](#4-issue-templates) (the files live in `.github/ISSUE_TEMPLATE/`)
5. [Triage rubric](#5-triage-rubric)

---

## 1. Moderator script

### Before the call (T-24h)

- [ ] Publish the beta build and **write down its place id and version**.
      Every issue needs them.
- [ ] Six players. Aim for at least **two on phones**, and one of those
      on a cheap Android if you can. Game rules are mobile-first, so a
      session with only PC players misses the most important test.
- [ ] At least **three players who have never played**. Returning
      players can't test onboarding.
- [ ] Ask everyone to turn their camera on if they're happy to. Faces
      tell you far more than the survey will. If they won't, voice is
      fine. Listen for laughs, groans and sudden quiet.
- [ ] Ask **two new players** to screen-share for the whole session.
      You can't watch six screens, so watch those two closely and
      spot-check the rest.
- [ ] Open a copy of the observation sheet (section 2), one tab per
      player.
- [ ] In the beta server, open the Developer Console (F9 → **Server**
      log). Each round prints `RoundService: round <id> begins`. Copy
      that id onto the sheet at the start of every round. Testers can't
      see it, so the round id on every issue comes from you.

### Setup (5 min) — what to say

Read this more or less as written:

> "Thanks for coming. This is an early build, so things will break.
> Breaking it is useful. Please say what you're thinking out loud while
> you play, even stuff like 'where do I go' or 'what just hit me'.
> You're not being tested; the game is. I'm going to be annoyingly
> quiet and not answer questions about how it works, because I need to
> see whether the game explains itself. If you're properly stuck for
> more than a minute, say 'stuck' and I'll help.
>
> Please don't give each other tips in the first round. After that,
> anything goes, including lying to each other."

Then send the join link and wait for everyone to be in the hub.

### Do NOT explain (this tests onboarding)

Don't answer any of these before or during round 1. If someone asks,
say "What do you think it means?" and write the question down word for
word. That question **is** the finding.

- What the game is about, or what "Steal or Share" means.
- That only the **top 3** reach the finale.
- How to pick up, use or target a power-up.
- That the **streak resets on any loss**, including failing to qualify.
- What bounty is, or how it depends on your streak.
- That you can talk and make deals in the Studio, and that promises
  aren't binding.
- The payoff table (who gets what for each Steal/Share combination).
- What the steal/share history on each finalist means.

From round 2 on, you can answer anything, but still write down each
question and when it was asked.

### Moments to watch (faces and voices)

These are the moments where the design either works or doesn't. When
one comes up, stop typing and **look at the players**. Write down what
you see in a few words ("frowned, went quiet", "laughed", "said 'wait
what'").

| # | Moment | Who to watch | What you're looking for |
|---|---|---|---|
| M1 | Round start, first 10 seconds | New players | Do they move straight away, or spin the camera looking for where to go? |
| M2 | First power-up pickup | Whoever picks one up | Do they use it straight away, save it, or not notice they have it? |
| M3 | First time someone gets hit | The victim | Annoyed-and-laughing is good. Silent, or "that's so unfair", is a finding. |
| M4 | The first player finishes all tasks | Everyone else | Do they speed up or give up? Do they know they're now racing for 2 seats? |
| M5 | Missing the top 3 by one place | 4th place | Their reaction to losing their streak. This is the most important face in the game. |
| M6 | Studio intro and negotiation | The 3 finalists | Do they talk? Do they understand what's at stake before the timer runs? |
| M7 | Choice lock-in | The 3 finalists | Hesitation, fast lock-in, changed mind. Ask afterwards; don't interrupt. |
| M8 | The reveal | All 6 | The payoff moment. Shouting is good. Confusion ("so who won?") is a bug in the results screen. |
| M9 | Back in the hub, 5 seconds later | All 6 | Do they queue again straight away? |

### During play

- Say nothing except the stuck rule. Never say "good job".
- Note every "wait, what?", "how do I...", and "that's broken".
- If something crashes or softlocks, write the time and the round id.
  Don't stop the session for it unless everyone is stuck.
- Play **4 to 6 rounds**. Round 1 tests onboarding. Rounds 2+ test
  whether it's still fun once people know how it works.

### Debrief (15 min) — questions to ask

Ask on the call before the survey, while it's fresh. Ask the question,
then wait. Don't fill the silence.

1. "Explain the game to me as if I'd never seen it." (If they can't
   explain the finale, onboarding failed.)
2. "When did you first feel lost?"
3. Finalists: "Why did you pick Steal/Share? Did anything anyone said
   change your mind?"
4. Non-finalists: "How did it feel to lose your streak? Would you queue
   again because of it or in spite of it?"
5. "Which power-up felt unfair to be hit by? Which one felt useless?"
6. "Which task station did you hate?"
7. Phone players: "Was anything hard to reach or tap with one thumb?"
8. "What would you tell a friend about this game in one sentence?"

Then post the survey link and end the call.

### After the call (same day)

- [ ] Fill any gaps in the observation sheets.
- [ ] Turn every "that's broken" into an issue, using the right template
      (section 4).
- [ ] Triage them (section 5).
- [ ] Compare the sheet's times with telemetry. `RoundStarted` and
      `TaskCompleted` give each player's time to their first station
      exactly, keyed by the same round id.

---

## 2. Observation sheet

Use **one row per player per round**. Copy this table into a
spreadsheet; the columns match the tables in `docs/telemetry-schema.md`
where they can.

**Session header:** date · build version · place id · moderator

| Field | How to record it |
|---|---|
| Round # | 1, 2, 3... |
| Round id | From the F9 server log (`<serverId>:<n>`) |
| Map | Map name |
| Player | Nickname |
| Device | PC / Mac / iPhone / iPad / Android phone (model if known) / Console |
| New or returning | New = never played before this session |
| Time to first task station | Seconds from round start until they **reach** a station (not finish it). Screen-sharers only; others come from telemetry later. |
| Tasks completed | e.g. 4/6 |
| Placement | 1–6 |
| Power-ups picked up | Number |
| Power-ups used | Name → target (e.g. "SlowField → Sam"). Write "held" if they ended the round still holding one. |
| Times hit | Number, plus notes if any hit caused a strong reaction |
| Understood the finale before it started? | **Yes / Partly / No.** Base this on what they said. "Yes" means they said something showing they knew only the top 3 go through and roughly what Steal/Share does, before the Studio opened. If you're not sure, it's "Partly". |
| Finale choice | Steal / Share / — (didn't qualify) / Left |
| Their stated reason | Their own words, from the debrief or what they said out loud. Don't paraphrase. |
| Result | SoleStealer / LoneSharer / AllShare / AllSteal / didn't qualify |
| Questions asked | Word for word, with the time |
| Moments (M1–M9) | e.g. "M5: swore, laughed, requeued" |
| Bugs seen | Short note plus the time. It becomes an issue later. |

---

## 3. Post-session survey

Ten questions. Send it straight after the call. Make it anonymous, so
friends are more honest.

These questions ask about specific moments, not whether they "liked" the
game. Friends will say they liked it. What we need to know is where they
got confused.

| # | Question | Answer type |
|---|---|---|
| 1 | In your first round, how long did it take to know what you were supposed to be doing? | Right away / Under 30s / 30s–2 min / Longer / I never really knew |
| 2 | Before your first finale, did you know that picking Steal could leave you with nothing? | Yes / I guessed / No / I never reached a finale |
| 3 | Describe what happens when two players pick Steal and one picks Share. | Open. **Grade this yourself** against `docs/payoff-table.md`. Don't trust how confident they sound. |
| 4 | Was there a moment you felt the game was unfair to you? What happened? | Open |
| 5 | How annoying was it to be hit by a power-up? | 1 (didn't bother me) – 5 (made me want to quit) |
| 6 | Did you ever have a power-up and not know what it would do? | Yes, often / Once or twice / No |
| 7 | When you missed the top 3 and your streak reset, did you want to play again straight away? | 1 (no, I wanted to stop) – 5 (yes, right away) · plus "N/A, it never happened" |
| 8 | Which task station was the most confusing or fiddly? Why? | Open |
| 9 | What device did you play on, and was anything hard to press or read? | Device dropdown + open |
| 10 | If this came out tomorrow, would you play it without us asking you to? | Definitely not / Probably not / Maybe / Probably / Definitely |

**How to read the results:**

- Q1, Q2 and Q3 test onboarding. If more than one new player gets Q3
  wrong, that's a usability finding against the finale explainer.
- Q5 over 3 and Q7 under 3 together mean "streak loss feels bad, not
  tense". That's the biggest design risk this game has.
- Q10 is the only "did you like it" question. Treat anything below
  "Probably" as a no.

---

## 4. Issue templates

The templates are GitHub issue forms in `.github/ISSUE_TEMPLATE/`:

| File | Use it for |
|---|---|
| `bug.yml` | Something behaves differently from the spec, crashes, softlocks, or loses data |
| `balance.yml` | It works as designed, but the design feels unfair, too strong or pointless |
| `usability.yml` | A player didn't understand something, or couldn't do something on their device |

Every template asks for the **place id, build version, device and round
id**. Without the round id, we can't find the server log or telemetry
for that round. Blank issues are turned off so the fields can't be
skipped.

The moderator files the issues, not the testers. Testers can post in the
Discord channel, and the moderator converts their posts.

---

## 5. Triage rubric

### Severity

| Sev | Name | Definition | Examples |
|---|---|---|---|
| **S0** | Critical | Money, data or trust. Players lose something permanent, or the server can be made to do something it shouldn't. | Streak or bounty lost or duplicated; a Robux purchase not granted, or granted twice; a client can finish tasks, qualify or set another player's choice without earning it; a finale result that doesn't match `docs/payoff-table.md`. |
| **S1** | Major | The round can't finish, or a player can't play it. | Server softlock; the finale never starts; a task station can't be completed on phone; a crash; a player stuck in geometry with no respawn. |
| **S2** | Moderate | It works, but badly enough to change who wins or to make people quit. | Power-up hits the wrong target; placement shown wrongly on the HUD; a tip that covers the thumb zone; audio missing on a key moment. |
| **S3** | Minor | Cosmetic or rare, and doesn't affect the outcome. | Clipping, typos, a sound playing twice, a UI element misaligned on one aspect ratio. |

If you're unsure between two levels, pick the higher one. It's cheaper
to downgrade later than to find out at launch.

### What blocks launch

- **Any open S0.** No exceptions.
- **Any open S1** that happens on a phone, or in more than 1 in 20
  rounds.
- Any **usability finding** where more than half the new players in a
  session failed the same thing. For example: they didn't understand the
  top-3 rule, or didn't know they could talk in the Studio.
- Survey Q10 average below "Maybe" across two or more sessions. This
  doesn't mean the game is broken, but it does mean launching it isn't
  worth it yet.

S2 and S3 don't block launch on their own. More than ten open S2s is a
sign the build isn't ready, and needs a decision from the owner.

### When does a balance complaint become a bug?

A balance complaint stays a **balance** issue while the game does what
the design says and players just don't like the result. It becomes a
**bug** as soon as any of these is true:

1. **The number is wrong.** The game doesn't match the shipped config.
   For example, a power-up lasts 8 seconds when its config says 5, or a
   bounty tier pays out the wrong package. File it as a bug and link the
   config file.
2. **A design guarantee is broken.** `docs/design-decisions.md` §7 says
   every attack must have counter-play. That's what makes a full streak
   reset fair. If an attack can't be dodged, blocked or recovered from,
   the guarantee is broken, so it's a bug (S2 at least).
3. **It's an exploit.** Winning through something the design didn't
   intend, such as a path through geometry, a task shortcut, a timing
   trick or stacking effects that the loadout cap should block. Exploits
   are S0 if they touch progression or money, and S1 otherwise.
4. **It's the same complaint three times.** If three separate sessions
   raise it with the same cause, it stops being a matter of opinion.
   Convert it to a bug, linking all three reports, so it gets fixed
   rather than discussed again.

Anything else stays in balance. It gets looked at in batches, with
telemetry (`PowerUpUsed`, placement data) next to it, not one complaint
at a time.
