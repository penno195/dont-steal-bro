# Don't Steal Bro! — First-Round Onboarding (P6-8, part 2)

A new player has to understand the loop in under 60 seconds: race to
finish tasks, grief your rivals, top 3 reach the finale, then Steal or
Share. There's no tutorial level and no wall of text. The first round
is a real round, and a short tip appears the first time each thing
happens to the player. So every tip explains something already on
their screen.

Code: `UI/OnboardingLogic.luau` (copy and queue, pure, tested),
`Controllers/OnboardingController.luau` (events and the card),
`UI/Screens/PayoffExplainer.luau` (How it works), and
`DecisionLogic.explainerRows` (the explainer's words, from `prizeFor`).

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

**The card:** it sits in the upper-middle of the screen, clear of the
top-centre info bar and the bottom thumb zone. Only the card takes
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
