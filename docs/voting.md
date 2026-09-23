# Don't Steal Bro! — Map Voting (P5-3)

How a formed group picks its map on the hub, why every hub server and
the match server agree on the winner, and what the board shows. Code:
`src/server/VoteLogic.luau` (pure, tested by `tests/VoteLogic.spec.luau`),
`src/server/Services/VoteService.luau` (the MemoryStore wrapper) and
`src/client/Controllers/VoteBoardController.luau` (the board). Config:
`GameConfig.vote`.

## Where the vote happens

Per group, on the hub, **after** formation commits and **before** anyone
teleports. `teleport.md` required exactly this: the match server loads
the map named in the group record, so the vote has to be finished and
written there before the first player arrives.

A group can span several hub servers, so the vote can't live on any one
of them. It lives in the group record (`MatchGroups_v1[groupId]`), which
is also the match server's manifest:

| Field | Written by | When |
|---|---|---|
| `ballot` | the former | at commit, 3–4 maps (`ballotSize`) |
| `mapId` | the former, then the locker | provisional pick from the ballot at commit; the winner at lock |
| `votes` | each voter's own hub server | compare-and-set per vote (`castVote`) |
| `result` | whichever owner locks first | once; `{ winner, tied }` |

**The hub's physical board wall (P5-4) can't show this.** Several groups
from the same hub server vote at once, each on its own ballot, so the
ballot is a per-player screen overlay. The wall is signage.

## The flow

1. **Ballot.** The former calls `VoteService.drawBallot(members)` before
   claiming anyone. It draws `ballotSize` distinct enabled maps, weighted
   against the members' recent maps (below), and picks one of them
   uniformly as the provisional `mapId`. Fewer than two enabled maps
   gives an empty ballot, and the vote is skipped.
2. **Voting.** Every hub server holding members runs one session per
   group (`runVote`, called by the departure handler once its players
   are `Departed`). It polls the record every `pollSeconds`, pushes the
   board to its own players, and writes their votes.
3. **Lock.** At the deadline (`formedAt + voteSeconds`, clamped so a
   former whose clock runs ahead can't stretch it), or as soon as every
   listed member has voted, an owner compare-and-sets the result and the
   winning `mapId` into the record. The transform refuses if a result
   already exists, so the first locker's winner stands and nobody can
   re-roll a tie. Everyone else reads that result back.
4. **Reveal.** The board shows the winner for `revealSeconds`, each
   player's recent maps are updated, and `runVote` returns the map. The
   teleport then proceeds as in `teleport.md`.

In Studio (nothing to teleport to) the default departure handler runs
the same vote, so it can be tested there.

## The rules the prompt asked for

- **3 to 4 maps, never all 11.** `ballotSize` is validated to 3 or 4.
- **One vote per player, changeable until the lock.** A vote is keyed
  by UserId and replaces the player's previous one. `castVote` refuses
  after `result` is set.
- **Ties: uniform random among the tied maps**, via `Random.new()`
  (`VoteLogic.pickWinner`, injected so the specs can seed it).
- **Players who don't vote aren't counted.** With no votes at all, every
  ballot map is tied on zero, so the pick is uniform over the ballot.
- **Recent maps are weighted down.** Each player's last `recentMapsCap`
  maps are kept in `RecentMaps_v1` (TTL `recentMapsTtlSeconds`), read
  onto their queue entry at join. A map's *exposure* is the average over
  members of `recentDecay^(i-1)` for the map's position `i` in their
  history (0 if absent). Its weight is `1 − (1 − recentFloorWeight) ×
  exposure`. With the defaults, a map every member just played is drawn
  at 1/5 the weight of a fresh one, and one they played two rounds ago
  at 3/5. Averaging means one regular can't keep a map off the ballot
  for five newcomers, and the floor means a small map pool always fills.

## Why a client can't cheat it

`MapVoteIntent` carries only `{ mapId }`, schema-checked (string, 1–64
chars) and rate-limited (4, refilling 1/s) by NetGuard.

| Attempt | Why it fails |
|---|---|
| Vote for a map not on the ballot | `castVote` → `NotOnBallot` |
| Vote in another group | The group is found from the server's own session for the sender. The payload names no group. |
| Vote twice, or as someone else | The voter is the sender's UserId, and a vote replaces their previous one |
| Vote after the lock | `castVote` → `Locked` |
| Spam votes to hammer MemoryStore | NetGuard's rate limit; an unchanged vote writes nothing |
| Read the access code from the board | `boardState` copies map ids, counts, voter ids and timing out field by field |
| Learn groupmates' streaks | Never sent (design-decisions.md Q7). Voter avatars are only groupmates the player is about to meet anyway. |

## Failure cases

- **Two owners lock at once.** Per-key compare-and-set: the second
  transform sees `result` and refuses. Both then read the same winner.
- **A MemoryStore outage during the vote.** Votes fail silently, and
  the board keeps showing the last good state. If no result can be
  written or read by `deadline + lockGraceSeconds`, each owner travels
  on the record's provisional map. The board says the votes couldn't be
  counted rather than presenting it as a win. The match server loads
  whatever its manifest read finds, which is always a ballot map. In the
  worst case, one owner gives up and another locks a moment later, so
  some players saw a different map named than the one they get. That
  only happens during an outage, and nobody lands on an invalid map.
- **A voter disconnects.** Their vote still counts: they cast it as a
  member. They're a no-show on the match server as usual.
- **More members depart on a later tick.** They join the existing
  session for that group on this server and see the live board.
- **The former crashes after commit.** The ballot and provisional map
  are already in the record. Any owner can lock.
- **A record from before this change.** It decodes with an empty
  ballot, so the vote is skipped and its `mapId` is used as before.

## Timing (enforced by `Validate.checkVoteConfig`)

- `pollSeconds < voteSeconds`, so there is at least one live count.
- `voteSeconds + lockGraceSeconds + revealSeconds` plus the worst
  teleport retry chain must be under `matchmaking.groupRecordTtlSeconds`,
  or the match server could boot after its manifest expired.
- `recentFloorWeight` in (0, 1]. A value of 0 would ban recent maps
  outright.
- `RecentMaps_v1` must not share a name with a matchmaking store.

**MemoryStore cost per group**, on top of `matchmaking.md`'s budget:
about `voteSeconds / pollSeconds` reads per owner server, one update per
vote (≤6, plus changes), one lock update, one recent-map read per join
and one write per player. That is small next to the queue page reads.

## The board

Implemented by `VoteBoardController`. It is a bottom sheet over a dimmed
screen, built for one thumb in portrait:

- **Header:** "Vote for the map" and a countdown in seconds, from the
  server's `secondsLeft`. A one-line hint below: "Tap a map. You can
  change your vote until time runs out."
- **Cards:** 3–4 full-width cards, 88px tall, stacked vertically in the
  lower half of the screen. No scrolling. Each card shows the map's
  thumbnail (`MapDef.thumbnailAssetId`), `displayName`, a live vote
  count and up to six voter head shots. The player's own vote gets a
  blue border and a "Your vote" tag. Tapping a card sends
  `MapVoteIntent`, and the server echoes the new state straight back.
- **Outright win:** the title becomes "<Map> wins!", and the winning
  card gets a gold border, a gold tint and a "WINNER" tag.
- **Random tie-break:** this has to look different, so players can see
  the pick was random and not rigged. The title is "It's a tie!", with
  a purple (never gold) banner: "🎲 TIE - PICKED AT RANDOM between the
  tied maps". Every tied card is tagged "Tied". A purple highlight
  cycles over **only the tied cards**, slowing down over about 2s, and
  lands on the winner, which gets "🎲 Random pick". The server chose the
  winner before the reveal was sent. The roulette only plays it back.
- **Fallback:** "Heading to <Map>", with an orange "We couldn't count
  the votes this time" line.
- The server closes the board after `revealSeconds`, and travel
  messaging continues through `QueueState`.

## Verify before launch

- `Players:GetUserThumbnailAsync(userId, HeadShot, Size48x48)` is
  confirmed in the pinned `globalTypes.d.luau`. Check the current
  recommended pattern (the `rbxthumb://` content URL avoids a yield).
- `MapDef.thumbnailAssetId` has no fixed format yet. The board accepts
  a bare id or a full content URI.
- The `Random` methods VoteLogic calls (`NextNumber()`,
  `NextInteger(min, max)`) are standard, but aren't checked by the
  type checker, because `Random.new()` is cast to VoteLogic's
  structural `Rng` type.

## Studio verification

With `hubPlaceId = 0`, MemoryStore enabled, and at least two
(preferably four or more) MapDef files enabled:

1. Six players join. A board with 4 maps appears within a tick of
   `MatchFound`. Tapping moves your blue border, and the counts and
   avatars update on every client within `pollSeconds`.
2. All six vote: it locks immediately, without waiting for the timer.
3. Split 3–3 across two maps: the tie reveal plays, and the log's
   `map …` in the "group formed" warning matches the highlighted card on
   every client.
4. Nobody votes: at 0s a random ballot map wins with the tie treatment.
5. Replay with the same accounts: the previous map shows up on the
   ballot noticeably less often.
