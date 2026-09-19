# Don't Steal Bro! — Game Design Document, v1

**Status:** v1, as written by the designer. Section 7 lists the questions that are
still open; task **P0-1** in the build plan resolves them and produces v2.
Until then, treat anything in section 7 as undecided, not as a gap to fill in
with an assumption.

**Title:** *Don't Steal Bro!* — named 19 Sep 2026. Task P9-1 now validates it
for store search and truncation rather than generating options.

**Genre:** Competitive mini-task race with social deduction and PVP griefing.

---

## 1. Core gameplay and loop

- **Server size:** 6 players per round. If the matchmaking timer expires before
  6 humans are found, the server fills the remaining slots with NPCs.
- **The race:** Players compete to complete a series of mini-tasks, inspired by
  *Among Us* and *The Crystal Maze*. The first 3 players to finish their tasks
  qualify for the final round.
- **Combat and griefing:** Players find and use power-ups to buff their own
  metrics (e.g. speed) or to grief opponents (e.g. freeze, slow).

## 2. The climax: Decision Studio

The 3 qualifiers are teleported to a studio with three podiums. Proximity chat
is enabled so they can negotiate, lie and strategise. They then blindly choose
one of two options: **Steal** or **Share**.

| Choices | Outcome |
|---|---|
| 1 Steal, 2 Share | The stealer progresses with a **large** bounty. The 2 sharers lose and reset. |
| 2 Steal, 1 Share | The sharer progresses with a **smaller** bounty. The 2 stealers lose and reset. |
| 3 Share | All 3 progress with the **smallest** bounty. |
| 3 Steal | All 3 lose and reset. |

The 3-Steal branch is a real, reachable state and must be handled explicitly in
the architecture, not left to fall out of generic code.

## 3. Progression and metagame

- **Primary goal:** build and maintain the highest win streak.
- **Penalty:** win streaks reset to zero on any loss.
- **Rewards:** players unlock permanent **Titles** based on their highest
  achieved rank/streak, displayed next to their name. Titles are never revoked
  when a streak resets.

## 4. Lobby and hub world

- **Map voting:** a selection board where players vote on the next map. Ties are
  broken by random selection among the tied maps.
- **Store:** skins, cosmetics and starting power-ups.
- **Leaderboards:** DataStore-backed Highest Streaks — Daily, Weekly, All-Time.
- **Interactive waiting area:** players can pick up standard in-game items and
  use them on each other as a practice mechanic while waiting for a round.

## 5. Environment and art direction

- **Maps required — 11 total:** School, Factory, Museum, Laboratory, Mall,
  Construction Site, Space Station, Bunker, Aircraft Carrier, Prison,
  Deserted Island.
- **Design style:** heavily stylized, dense, highly populated map designs.
- **Production method:** built from purchased/provided asset packs to speed up
  world-building, so **modularity is key** — every map satisfies one tag
  contract (see `map-kit-spec.md`, produced by task P0-5).

## 6. UI/UX and technical requirements

- **Mobile-first UI:** heavy emphasis on ScreenGui usability for mobile players,
  particularly during the mini-games.
- **Architecture:** modular, data-driven Luau, so the number of maps, mini-games
  and items scales without service-code changes.

---

## 7. Open questions — UNRESOLVED (blocks P0-1)

These are not design decisions yet. Do not assume an answer; ask, or resolve
them via P0-1.

1. **What is "bounty"?** A currency, a score multiplier, or streak progress?
2. **Round timeout.** What happens if fewer than 3 players finish before the
   round timer expires?
3. **Qualifier disconnects before the Studio.** Promote the 4th-place finisher
   as an alternate, or run the finale with two?
4. **Disconnect inside the Studio.** What is the leaver's choice counted as, and
   do they take a loss?
5. **Can NPCs qualify?** They must be able to — with 1 human and 5 NPCs, two
   NPCs necessarily reach the Studio. So what is their choice policy?
6. **"Progresses to the next round" — mechanically what?** A fresh match, the
   same server, or a priority re-queue carrying streak and bounty?
7. **Does a loss reset the streak for everyone who fails to qualify**, or only
   for Studio losers?
8. **Are starting power-ups sold for Robux?** If so, how does the competitive
   mode avoid reading as pay-to-win?

## 8. Known design risks

Carried from the architecture review; mitigations are designed in P0-7.

- **Collusion farming.** Three friends who queue together and always Share
  progress forever. The streak leaderboard's credibility depends on stopping it.
- **NPC farming.** A solo player in a bot-filled lobby can farm streaks.
- **Disconnect-to-dodge.** Leaving before a loss is recorded.
- **Griefing overload.** Chain-freezing a player out of a round is the fastest
  route to churn; anti-frustration rules are mandatory, not polish.
- **Density vs. mobile.** "Dense and highly populated" fights the mobile
  performance budget and station readability. Both need explicit budgets.
