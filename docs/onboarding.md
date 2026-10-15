# Don't Steal Bro! — First-Round Onboarding (P6-8, part 2)

A new player has to understand the loop in under 60 seconds: race to
finish tasks, grief your rivals, top 3 reach the finale, then Steal or
Share. On their first visit to the Hub they get a short intro and the
offer of a guided practice round (design-decisions.md, "the first-time
tutorial"). In any round, a short tip appears the first time each
thing happens to the player, so every tip explains something already
on their screen.

Code: `UI/OnboardingLogic.luau` (copy and queue, pure, tested),
`Controllers/OnboardingController.luau` (events and the card),
`UI/Screens/PayoffExplainer.luau` (How it works), and
`DecisionLogic.explainerRows` (the explainer's words, from `prizeFor`).

## The hub intro

On a player's first visit to the Hub (between rounds, no menu open,
not queued, loading screen gone), a modal steps through four cards,
then the offer. `HubIntroController` draws it; the copy and the
"is it due" check are `OnboardingLogic.INTRO`, `INTRO_OFFER` and
`introDue` (tested).

| # | Title | Body |
|---|---|---|
| 1 | Race your tasks | Follow the arrow, finish your tasks. Top 3 go to the finale. |
| 2 | Mess with rivals | Grab power-ups and slow the others down. They'll do it to you too. |
| 3 | Steal or Share | The top 3 pick in secret. Steal only pays if you're the only one. |
| 4 | Your streak | Win and it goes up. Lose once and it's back to 0. |
| Offer | Want a practice go? | A quick round against bots. Finish it for a Rookie Cap, 100 coins and a Freeze. **[Try a practice round] [Skip]** |

Every card has Next and Skip. Any way out (Skip, Try, close, B, tap
outside) sets the `introSeen` setting, so it shows once. Skip pulses
the Play button (not under reduced motion). Try queues the guided
tutorial round (below).
**Settings → Show the intro** (Hub only) clears `introSeen` and the
intro opens again once the menu closes. "Reset to defaults" leaves
`introSeen` alone. Like the tips, it's display-only: the reward is the
server's own once-per-account flag.

## The guided round

Try sends a `Tutorial` queue intent. `MatchmakingService` gives the
player a solo practice ticket that leaves on the next tick with
`GameConfig.tutorial`'s 5 bots, on its map (Factory) with no vote. The
group record carries `tutorial`; only the record can make a round a
tutorial (`TeleportLogic.isTutorial`), never TeleportData. A party
member is asked to leave the party first.

On the match server `TutorialService` owns what changes (owner's
answers, design-decisions.md "the first-time tutorial"):

- **No race clock** (`RoundService.setRaceTimed`). The race ends when
  the third racer finishes.
- **Easy bots.** Each is slowed by `botDurationScale` /
  `botMoveSpeedScale` (`TutorialLogic.easyProfile`), and a bot is held
  on its last task while finishing would take a top-3 seat the player
  still needs (`TutorialLogic.botMayFinish`, tested). Bots use no
  power-ups, and bot finalists always Share.
- **The reward** is paid when the round reaches Results with the
  player still there, once per account (`DataService.claimTutorialReward`).
- The client sees Workspace attribute `TutorialMatch`.

On the client (seam 4):

- **Step prompts** (`OnboardingController`; copy and order are
  `OnboardingLogic.STEPS`, tested). Each step first opens as a **pop-up
  in the middle of a dimmed screen** with its picture (a Studio
  screenshot, `picture`), and the round is **frozen** until "Got it"
  (owner, 2026-10-15): the client sends `TutorialPause`, and
  TutorialService stops the bots (`NPCService.setPaused`) and anchors
  the player, only during a tutorial race. Then the step stays in the
  tip card's corner as a reminder until the player does it; taps
  don't close it. A station's prompt showing counts as reaching it, so
  "Do the task" pops up before the mini-game opens. One is up at a
  time, through the race. Each step is a fact that stays true once it is, and
  the prompt is the first one not yet true, so a step done early is
  skipped. Copy picked by the owner 2026-10-15:

  | # | Done when | Title | Body |
  |---|---|---|---|
  | 1 | a task view opens (`TaskChallenge`) | Head to a station | Follow the arrow to your first task. |
  | 2 | one task is done (own route) | Do the task | Finish the mini-game to tick it off. |
  | 3 | a power-up is held | Grab a power-up | Run through one of the glowing orbs. |
  | 4 | a use succeeds (`PowerUpUseResult`) | Use it on a bot | Tap the power-up button. It hits the nearest rival. |
  | 5 | every task is done | Finish your tasks | Top 3 make the finale. Follow the arrow. |

- **The tips stand down** for the whole tutorial round, so the
  player's first real round still teaches the loop and turns them off.
- **No clock**: the race HUD hides its countdown ring whenever
  RoundState has no `endsAt`.
- **How it works** opens by itself for a finalist as the Studio's
  Negotiate (or Choose) phase starts, before they pick.
- **The reward pop-up**: `TutorialService` fires `TutorialRewarded`
  (the grants) to a player whose claim just paid, and `MenuController`
  shows it with the season pass's claim pop-up over Results. A replay
  hears nothing.
- **Settings → Play the tutorial** (Hub only) queues the guided round
  again (`QueueController.startTutorial`).

Studio: set Workspace `DebugPracticeMatch` and `DebugTutorialMatch`
before the round loads, with `studioTest.mapId` on Factory.

## The flow

| When | Tip | Title | Body |
|---|---|---|---|
| Race starts | `race` | Race to finish your tasks | Follow the arrow to each station. Top 3 make the finale. |
| First power-up picked up | `powerUp` | You got a power-up | Hit the power-up button to mess with a rival. Or save it. |
| First time you're hit | `hit` | Someone got you | It wears off soon. Your turn next time you grab a power-up. |
| First time you're on or below the line, once anyone has finished a task | `line` | Only the top 3 go through | Your place and the gap to 3rd are at the top. Keep moving. |
| You qualified | `finale` | You made the finale | You and 2 others each pick Steal or Share. In secret. |
| You didn't | `missed` | Not this time | Only the top 3 play the finale. Watch how it goes down. |
| Negotiate (finalists) | `negotiate` | Talk it out | Make deals, make promises. Nobody has to keep them. **[How it works]** |
| Choose (finalists) | `choose` | Pick in secret | Hold Steal or Share. Nobody sees it until everyone's in. **[How it works]** |
| Results | `streak` | That's your streak | Win and it goes up. Lose once and it's back to 0. |

The 60-second loop is `race` → `powerUp` → `finale` → `choose`. The
other tips fill in whatever happens to that player.

**Rules** (`OnboardingLogic`, tested):

- One tip at a time.
- Each tip shows at most once.
- A tip only shows during its own part of the round. A queued race tip
  is dropped when the Studio starts, never shown late.
- A tip stays up for about 3 words a second plus 2 seconds (4 to 9
  seconds in total), or until it's tapped.

**The card:** it sits in the top-right corner (in portrait, just below
the full-width info bar), 260 wide, out of the middle of the view. It
used to sit upper-middle, and the first playtest found it in the way
every time it appeared. Only the card takes
taps, so movement is never blocked. Tapping anywhere on it closes it.
It never takes gamepad focus: mid-race, the stick is steering.

**Voice:** second person, short, a bit of attitude. Nothing like
"Great job!", and nothing that explains what the player can already
see. Titles are 30 characters or fewer and bodies 90 or fewer; the
spec checks both.

## When tips stop

The `tips` setting is stored with the other settings (`SettingsLogic`),
defaults to on, and saves automatically. At the end of a round in which
the player saw `race` plus `choose` or `missed`, the controller turns
it off. A player who joined mid-round keeps the tips for their next
full round. **Settings → Beginner tips** turns them back on, and they
replay from the start. "Reset to defaults" also turns them back on.

Tips are display-only. A client that fakes or hides them changes
nothing but its own screen, so the server doesn't check them.

## How it works (the payoff explainer)

This opens from the (i) on the Studio's payoff table (every round) and
from the `negotiate` and `choose` tips. With three finalists it reads:

> **Steal or Share?**
>
> Everyone picks in secret. All the picks are shown at the same time.
>
> **Everyone shares**: Everyone gets a SMALL prize.
> **One person steals**: The stealer gets the BIG prize. The sharers get nothing.
> **Two people steal**: The one who shared gets a MEDIUM prize. The stealers get nothing.
> **Everyone steals**: Everyone gets nothing.
>
> ★ Stealing only works if you're the only one who does it.
>
> Get a prize and your streak goes up. Get nothing and it goes back to 0.

Each case has a row of small faces, one per finalist: a diamond for
Steal and a pill for Share, the same shapes and colours as the hold
buttons.

**Why it's built this way:**

- **Every prize word comes from `DecisionLogic.prizeFor`**, the same
  function the always-visible table uses, which is itself tested
  against `Outcomes.resolve`. A player who misreads the finale feels
  cheated rather than outplayed, so this sheet must never disagree
  with what the server pays out. If Outcomes is retuned, the sheet
  follows.
- **Cases, not a grid.** A 2×3 matrix makes a 12-year-old
  cross-reference two axes. Four sentences, one per way the table can
  go, read top to bottom.
- **The lesson line** is the one thing to remember, and the spec
  proves it holds for 2 and 3 seats.
- **The streak line** closes it, because that's the stake (Q7).

With a table of fewer than three, `explainerRows` still generates the
right cases. The Studio passes its real seat count.

## Needs a device check

- The tip card doesn't cover the objective arrow or the placement card
  in portrait at 360×640.
- The explainer at 1.3× Text and HUD size on a landscape phone: the
  cases should scroll inside the card, with "Got it" still visible.
- The payoff table's heading row grew from about 14 px to 28 px for
  the (i). Check that the Studio's Choose layout still fits a
  landscape phone.
