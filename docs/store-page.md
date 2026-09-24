# Store page, icon and thumbnail brief (P9-1)

The name is fixed: **Don't Steal Bro!** This doc validates the name for
discovery and writes everything that sits around it on the store page. It
does not suggest other names.

Facts this copy relies on, so nothing here promises more than the game
has at launch:

- **Launch content:** wave 1, which is 4 maps (School, Factory, Museum and
  Laboratory) and the 10 power-ups in `Config/PowerUps`. The copy never
  quotes a task count, because the task pool is still growing.
- **Finale talk** is proximity voice for eligible players and text for
  everyone else (`studio-chat-notes.md`). Voice needs age 13+ and a
  verified account, so the copy says "talk", not "voice chat".
- **Robux** can buy power-ups, but every one of them can also be earned
  for free, and loadouts are capped at 3 (design decision 8). The copy
  must never suggest that paying wins, and it says so outright.
- **Titles** go from *Got One* (streak 1) to *Touch Grass* (streak 120) and
  are never taken away. Streaks reset on any loss (decision 7).

Numbers marked **verify** are platform facts I couldn't confirm from an
official source this session. Check each one in Creator Hub at upload
time; don't treat them as settled.

---

## 1. Title validation

### How players will type it

| Typed as | Who types it this way | Risk |
|---|---|---|
| `Don't Steal Bro!` | Someone copying it from a thumbnail or a friend's message | None |
| `Don’t Steal Bro` (curly ’) | **iOS by default.** Smart Punctuation turns `'` into `’`, and most of the audience is on phones | **Medium.** Existing "Don’t Steal…" games use both apostrophes, so we don't know how Roblox search treats `'` vs `’`. **Test it after the first publish** |
| `dont steal bro` | Most people on a keyboard, and most kids | **Medium.** Roblox's own URL slugs drop the apostrophe (`/Dont-Steal-…`), which suggests normalisation, but that isn't a promise about search |
| `dont steal` / `steal bro` | Someone half-remembering the name | **High.** See the collision below |

**The collision that matters:** "Don't Steal the ___" is already a crowded
family of *Steal a Brainrot* follow-ons on Roblox: *Don't Steal the
Brainrots*, *Don't Steal the Bobo*, *Don't Steal LUCKYBLOCK*, *Don't Steal
the Baby Brainrots* and others. None of them is named "Don't Steal Bro",
so **no existing experience owns the exact phrase** (as of 25 Sep 2026,
from a web search, not an in-client search). But anyone who types only
`dont steal` lands among those games, and the name risks being read as
one more of them.

Two things protect against that:

1. **"Bro" is what makes the name distinct, so it must be readable
   everywhere.** Never shrink "Bro" on the icon or the title card. On a
   phone, the fastest cue that this isn't a brainrot game is the word
   "Bro" plus art that shows people on podiums instead of a creature.
2. **The first line of the description has to establish the genre**
   (race, then betrayal). A brainrot searcher who lands here should be
   able to tell within a second that this is a different game.

### Punctuation and truncation

- The name is 16 characters with the punctuation. It fits well within the
  name limit (**verify**: 50 characters) and shows in full on a mobile
  game card. Cards truncate at roughly 20 or more characters depending on
  the device (**verify** on a small Android screen). Nothing important is
  hidden.
- The `!` and `'` characters don't break display. Emoji and exotic
  Unicode in names are what break across devices; plain ASCII
  punctuation doesn't.
- **Store spelling:** use exactly `Don't Steal Bro!` with a straight
  apostrophe. Don't add an emoji or a bracketed tag like `[NEW]`. Names
  stuffed with tags read as low-effort next to the brainrot clones we're
  trying to look different from.
- **Discovery help without renaming:** write the plain spelling
  `dont steal bro` into the description **once**, naturally (see the
  last line of the description below). One natural mention is fine.
  Repeating it, or listing keywords, reads as keyword stuffing and risks
  moderation.

### Tagline

Roblox has no subtitle field, so the tagline goes in two places: the first
line of the description and the trailer's end card.

> **Win the race. Then find out who your friends really are.**

Backup, shorter, for the thumbnail and ad text:

> **First place isn't safe.**

---

## 2. Description

Keep it well under the description limit (**verify**: 1,000 characters).
This draft is about 900 characters. The first line has to work on its own,
because that's all a phone shows before "See more".

```
Win the race. Then find out who your friends really are.

6 players. One race through School, Factory, Museum and Laboratory. Fix fuses, crack codes and purge vents while everyone else is trying to beat you to it.
Grab power-ups to Freeze, Blind or Slow whoever's ahead, or Sprint past them yourself.
Only the first 3 across the line make it to the Decision Studio.

Three podiums, one secret choice: STEAL or SHARE.
All share, everyone's paid. One steals, they take the lot. Two steal, the sharer walks away with the bounty. All three steal, nobody gets anything.
Talk it out first. Promise, bluff, beg. Then choose.

Every win builds your streak and bigger streaks mean bigger bounties. One loss and it's back to zero, but titles like Hot Streak and Menace are yours forever.

Every power-up in the store can also be earned free by playing. No pay-to-win.

(Searching "dont steal bro"? You found it.)
```

Why it's built this way:

- **Line 1 is the tagline.** It's a hook that only makes sense if there's
  a twist, and the twist is the whole game.
- **The loop fits in three lines:** race, grief, qualify. Each line names
  concrete things (Freeze, the vent) rather than "exciting mini-games".
- **The finale gets the longest block** because it's what makes the game
  different. It spells out the full payoff table in plain words, including
  the 2-Steal case where the sharer wins. That case is what makes
  "promise, bluff, beg" a real strategy and not just flavour text.
- **Progression is one line** that pairs the pain (back to zero) with what
  you keep (titles).
- **The no-pay-to-win line is required**, not optional. It's decision 8's
  perception safeguard, applied at the point where a player decides
  whether to trust the leaderboard.

Before publishing, check the description against the live content flags.
If any named map, task or power-up is disabled by live-ops, remove it
from the copy.

---

## 3. Genre and discovery settings

Roblox now uses a fixed genre/subgenre list set in Creator Hub. There are
no free-form tags, so the name, the description and the thumbnails do all
the discovery work. Recommended settings (**verify** that the labels match
the current dropdown):

| Setting | Pick | Reasoning |
|---|---|---|
| Genre | **Party & Casual** | Short rounds, friends in a server, betrayal as the punchline. That's how players will *describe* the game, and it's where Among Us-style and minigame-race games are browsed |
| Subgenre | **Minigame** | The race is literally a string of mini-tasks. It's a better fit than Racing (Sports & Racing), because there are no vehicles and the win condition isn't speed alone |
| Not chosen | Strategy, Social, Sports & Racing | Strategy undersells the chaos. Social implies a hangout. Racing is where people expecting karts end up, and they'd leave in the first minute |
| Max players | 6 per server | Matches the round. A larger server just makes matchmaking wait longer |
| Devices | Phone, Tablet, Computer, Console | Mobile-first by design (Ground Rule 3). Only enable Console once `mobile-checklist.md`-style testing covers gamepad |
| Voice chat | On | Needed for the Studio (`studio-chat-notes.md`). Everyone without voice still gets text |
| Maturity questionnaire | Answer honestly | No blood, and griefing is non-violent (freeze, slow, blind). Proximity voice may affect the rating, so answer the questions as they're written rather than guessing the outcome |

---

## 4. Icon brief

**The one emotional idea:** *the moment of doubt about a friend.* Not
winning, not racing: the half-second where you look at your friend and
don't trust them.

**Must read at 150 px:**

- One face or one gesture, never a scene.
- At most two words, and one of them is "BRO". At that size the only
  words that survive are short, heavy, high-contrast ones.
- Strong outline and one dominant background colour, so the icon stands
  out from the neon-green and purple of the brainrot clones in results.
  Use a warm orange or a studio red.
- No creatures, no money piles, no lucky blocks: nothing that looks like
  the "Don't Steal" family.

**Three concepts:**

1. **"DON'T STEAL BRO"**, built on the phrase. Two avatars side by side
   on podiums. One points at the other with a stern "don't" finger. The
   other smiles far too innocently with a hand already behind their
   back. The only text is "BRO!" in a speech bubble from the pointer. This
   is what a player says out loud at the game's best moment, so the icon
   teaches the name.
2. **The hidden button.** A close-up of a hand over two buttons, a green
   SHARE and a red STEAL, and the hand is going for red. No text. It's
   the clearest statement of the core choice, and it needs no language,
   which helps outside English-speaking markets.
3. **Side-eye.** One avatar face filling the frame, eyes cut to the side,
   with a single sweat drop and a spotlight from above. Text: "STEAL?"
   It's the most mysterious of the three and the most likely to earn
   curiosity clicks. It's also the weakest at showing genre, so pair it
   with thumbnail 1 so the race is visible straight away.

Test concepts 1 and 2 against each other with Roblox's icon/thumbnail
A/B testing (**verify** the current Creator Hub feature). Concept 1 is the
favourite, because the icon and the name reinforce each other.

---

## 5. Thumbnail briefs

The five briefs, in carousel order. Each one needs to work on a phone
screen with no caption, so each has one focal point and no more than
four words of text.

| # | Moment | Shot | On-image text | Must show |
|---|---|---|---|---|
| 1 | **The race** | Wide, low angle down a School corridor. Six avatars mid-sprint, one reaching for a glowing fuse box, task markers visible over two stations | **"RACE."** | That it's a race with objectives, not an obby. Six players, all visibly competing |
| 2 | **Grief moment** | Mid-shot. One player frozen solid in an ice block with a shocked face, the player who froze them running past and waving | **"SORRY BRO"** | Griefing is funny, not cruel. The frozen player's face has to read at a glance |
| 3 | **Qualification** | Over-the-shoulder at the finish. Third place diving across the line, fourth place a step short with arms up in despair, a big "3/3" on the HUD | **"TOP 3 ONLY"** | The cutoff exists and it's tense. The HUD should look real (use the `race-hud.md` placement readout) |
| 4 | **The three podiums** | Symmetrical, straight-on shot of the Decision Studio. Three avatars on lit podiums, eyeing each other, spotlight cones, dark studio | **"STEAL OR SHARE?"** | The finale is a stage. The symmetry is what makes this the most recognisable image in the set |
| 5 | **The reveal** | Close-up. Two avatars' reveal cards flip to SHARE (green), one flips to STEAL (red). The stealer grins, confetti of bounty on their side, the two sharers mid-gasp | **"BRO."** | The betrayal lands. This is the image that sells the game, so it should also be the first frame players see if A/B testing supports putting it first |

Production notes:

- Shoot on the real wave-1 maps with the real HUD and podiums. Don't show
  maps that haven't shipped: wave 2 and 3 thumbnails come with their own
  releases (P9-3).
- Posed avatars in varied, readable skins. **No Founder cosmetics in more
  than one thumbnail**, so paid items don't look like the default look.
- A consistent colour grade across all five: warm race shots and a cool,
  spotlit studio. The contrast itself tells the two-act story.
- Test 5-first against 1-first ordering. The expectation is that the
  betrayal leads with more clicks, and the race leads with better
  retention from people who understand what they're getting.

---

## 6. Trailer beat sheet (30 s)

The title card lands at the betrayal, not at the start. The hook is a
friend's promise in the first 3 seconds.

| Time | Beat | Picture | Sound |
|---|---|---|---|
| 0.0–3.0 | **Hook** | Tight on two avatars on podiums, one leaning over: text bubble "we both share ok?" and the other: "obviously bro" | Dead quiet, a single heartbeat. The only line is the promise |
| 3.0–5.0 | **Rewind** | Hard whip cut, "30 SECONDS EARLIER" in a quick stamp | Record-scratch into the race track |
| 5.0–12.0 | **The race** | Fast cuts: sprint through School, a Fuse Rewire snapping into place, a Code Playback solved, a vent purge blasting steam. 6 players, constant motion | Driving beat, task-complete stings timed to cuts |
| 12.0–17.0 | **The grief** | Freeze lands on a leader mid-stride, Blind whites out a screen, Slow Field catches two players at once, and the two "bros" from the hook sail past together | Beat drops out for the freeze *shatter* SFX, then kicks back |
| 17.0–20.0 | **Qualify** | The two bros dive across the line 2nd and 3rd, and fourth place is locked out by a gate slamming | Crowd roar, gate *clang* |
| 20.0–24.0 | **The Studio** | Three podiums, spotlights snap on one at a time, the promise bubble from 0:00 repeated, and three hands hovering over STEAL/SHARE | Music cuts to a low drone, the same heartbeat as the hook |
| 24.0–26.5 | **The betrayal** | Reveal: SHARE, SHARE… **STEAL**. The "obviously bro" avatar grins | Silence, then one bass hit on STEAL |
| 26.5–29.0 | **Title card** | **DON'T STEAL BRO!** slammed over the betrayed friend's face, tagline beneath: "Win the race. Then find out who your friends really are." | The betrayed friend's line, text or VO: "bro…" then the logo sting |
| 29.0–30.0 | **CTA** | "Play free on Roblox" plus the icon | Sting tail |

Notes:

- The hook uses **text bubbles** instead of voice lines, so the trailer
  doesn't suggest every player gets voice (see the facts at the top).
- The betrayer and the betrayed are the same two players from the hook.
  That's the whole joke, so casting has to make them recognisable across
  cuts (distinct colours).
- The payoff comes in the last 4 seconds. Where Roblox autoplays video
  muted, the on-screen text has to carry the story without sound.

---

## Checklist before publishing

- [ ] Check that the name shows untruncated on a small Android phone card
      and in desktop search results.
- [ ] Search in the client for `dont steal bro`, `Don't Steal Bro` and
      `Don’t Steal Bro` (curly, typed on iOS). Record which ones find us.
      If the curly form fails, add it once to the description.
- [ ] Check the description against the current limit and the live
      content flags.
- [ ] Confirm the genre/subgenre labels in Creator Hub.
- [ ] Shoot the thumbnails on wave-1 builds with the shipped HUD.
- [ ] Set up an icon A/B test: concept 1 vs concept 2.
