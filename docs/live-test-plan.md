# Live test plan: offline payouts and receipt redelivery

Next-stages step 13. Both tests run on the **published** places, because
Studio has no MemoryStore, no real `ProcessReceipt` redelivery and no
cross-server profile messages.

You need two accounts: **Owner** (the admin) and **Alt**. Read server
lines in F9 → Server (owner only).

## Before you start

1. Put Owner's user id in `GameConfig.liveOps.adminUserIds`, sync, and
   republish both places. Without it, `/liveops` commands do nothing.
2. Check `/liveops status` replies in the server log.

## Test A: a leaderboard payout to an offline player

What it proves: the snapshot, the payout message
(`ProfileStore:MessageAsync`) and its delivery on the winner's next
join all work when the winner is offline at the rollover.

Since 2026-10-04 you don't need a server running at midnight. A
server that boots into a new period pays the previous one if nobody
did (the catch-up in `LeaderboardService`).

1. **Day 1, before 00:00 UTC.** As Alt, win one live round. Alt is now
   on the Daily board. Write down Alt's coin balance after the round,
   then leave. Don't play as Alt again until step 3.
2. **Day 2, after 00:00 UTC.** As Owner, join the Hub so a fresh server
   starts (any server that boots today does it). Within about two
   minutes the server log should show:
   - `LeaderboardService: Daily <day 1> was never snapshotted - catching up`
     (or nothing, if a server was already up at midnight and did it)
   - `LeaderboardService: froze Daily <day 1> with N entries - awarding top N`
   - `LeaderboardPayout: queued Daily <day 1> rank R to user <Alt id> ...`

   If you see `already snapshotted by another server`, some other server
   did the payout. That is also a pass. Find its `queued` line in that
   server's log instead, or go to step 3.
3. As Alt, join. **Expect:** coins = the step 1 balance + the Daily
   band for Alt's rank (#1: 75, #2–3: 50, #4–10: 25). The server Alt
   joins logs the grant (`LeaderboardPayout` audit line).
4. Rejoin as Alt once more. **Expect:** no second grant.

Weekly works the same way across Monday 00:00 UTC. It's optional, since
the code path is the same.

**Fail cases to look for:** no `froze` line on any server (catch-up
didn't run: check for a `catch-up ... failed` warning), `FAILED to
queue`, or the coins arriving twice.

## Test B: receipt redelivery

What it proves: a purchase whose `ProcessReceipt` returns
`NotProcessedYet` is granted exactly once when Roblox redelivers it.
The kill switch is the cleanest way to force that, and it refunds
nothing, so this costs Alt one Small Coin Pouch (79 R$).

1. Owner and Alt in the **same** Hub server.
2. As Alt, open the store and tap the Small Coin Pouch. Leave the
   Roblox purchase prompt open, **don't confirm yet**. Note Alt's coins.
3. As Owner, type `/liveops kill store`. It applies on this server
   straight away.
4. As Alt, confirm the purchase. Robux are charged. **Expect:** no
   coins. The store is closed, so `ProcessReceipt` defers the receipt.
5. As Owner: `/liveops flag store on`, `/liveops promote`.
6. As Alt, leave and rejoin (Roblox redelivers pending receipts on
   join). **Expect:** +75 coins, once.
7. Rejoin again. **Expect:** no second grant.

If step 2's prompt closes before Owner can type, swap roles: Owner buys
and Alt watches, with Alt's id temporarily in `adminUserIds` too.
Remove it afterwards.

## Results

Record date, pass/fail and anything odd here, then tick step 13 in
`next-stages.md`.

| Test | Date | Result | Notes |
|---|---|---|---|
| A: offline payout | | | |
| B: receipt redelivery | | | |
