# Don't Steal Bro! — Threat Model (P0-7)

The leaderboard is the entire product — a win streak on daily, weekly, and
all-time boards is the "headline metagame" per the GDD. Every attack below
is scored by how much it damages that leaderboard's credibility, not just
by raw severity, because a game whose progression can be faked has no
product left even if nothing else is broken.

## Client exploits

### 1. Remote spam

**How it works:** a compromised client fires a `RemoteEvent`/`Function` at
far above any legitimate UI interaction rate — either to degrade the
server for the other 5 real players, or to probe a handler for a race
condition that only shows up under abnormal call cadence.

**Telemetry:** per-player, per-remote call-rate logging (owned by
`NetGuard`) — a spike far beyond what any real touchscreen interaction can
produce is unambiguous.

**Mitigation:** every remote is declared once in `Net.luau` and routed
through `NetGuard`, which enforces a **per-remote** rate limit and payload
shape/type check before the call reaches game logic. Calls past the limit
are silently dropped, not errored — an exploiter shouldn't get a clean
signal of exactly where the wall is. Repeated violations in one session
escalate to a kick.

**Cost:** the rate limit must be calibrated per-remote against that task's
actual max human tap rate — Pressure Valve and Vent Purge (`tasks-
catalogue.md`) are *designed* to be mashed fast, so a single global limit
will false-positive the game's own best players on exactly the tasks meant
to reward speed.

### 2. Forged task completion

**How it works:** a client fires a "task complete" intent without
performing the challenge, or replays a stale valid answer.

**Telemetry:** an "invalid completion attempt" rejection is itself the
signal — the server never trusts a bare "done" claim in the first place
(the foundational rule `tasks-catalogue.md` was built around).

**Mitigation:** none new — this was solved at design time. The only
ongoing work is unit-testing every `TaskHandlers/*` module (Ground Rule 4)
to confirm none of them accidentally trusts client-reported state.

**Cost:** effectively free — the payoff of having front-loaded this
constraint into P0-2 instead of retrofitting it later.

### 3. Speed and teleport hacks

**How it works:** a client-side exploit sets an inflated `WalkSpeed` or
directly overwrites `HumanoidRootPart.CFrame`, finishing the race
impossibly fast or skipping past a `KillZone`/hazard.

**Telemetry:** log the position delta per server tick; flag any delta
exceeding what the character's *server-known* speed × elapsed time could
physically produce, with a latency tolerance band.

**Mitigation:** server-authoritative position sanity-checking — reject
(snap back) any reported position inconsistent with max possible
movement since the last validated tick. `WalkSpeed` itself is never
trusted from the client; only server-applied buffs (Sprint Boost) can
change it, server-side.

**Cost:** this is the prompt's "fundamentally can't fully prevent" case —
a genuinely laggy connection and a small-scale exploit look identical at
the tolerance boundary. Too tight a band snaps back honest players on bad
connections; treat a single violation as a logged near-miss, and only
sustained/repeated violations as bannable.

### 4. Power-up duplication

**How it works:** racing two "consume" intents against the server's
inventory-count update to get two effects from one pickup, or duplicating
a loadout item across pre-game selection.

**Telemetry:** any consume event without a matching prior grant is an
impossible state — flag immediately, not just as anomalous.

**Mitigation:** every inventory mutation goes through a single serialized
per-player queue in `PowerUpService`, not two independently racing
handlers — a double-fired consume intent is processed in order, and the
second attempt simply fails against an already-decremented count. This is
an idempotency fix, not a detection heuristic.

**Cost:** negligible if `PowerUpService` is built serialized from the
start; expensive only if retrofitted after a live incident — this belongs
in the initial design, not a patch.

### 5. TeleportData tampering

**How it works:** `TeleportData` is visible to (and effectively settable
by) a compromised client in some flows; anything read from it and trusted
blindly — streak, NPC-count hints, matchmaking priority — can be forged.

**Telemetry:** cross-check every `TeleportData`-claimed value against the
`ProfileStore`-persisted source of truth on arrival; log mismatches.

**Mitigation:** `architecture.md` already establishes the right pattern
for NPC count ("a hint only, re-derives itself") — this document
generalizes it project-wide: `TeleportData` is **never** authoritative for
anything, full stop. The receiving server always re-reads real state
itself; `TeleportData` may only carry cosmetic hints.

**Cost:** none — a discipline rule, not a trade-off. The only real cost is
forgetting to apply it consistently, which is why it's named explicitly
here rather than left implicit.

### 6. DataStore manipulation through rejoin timing

**How it works:** disconnecting/rejoining at a precise moment to try to
roll back an unwanted write (a just-applied loss) while keeping earlier,
favorable server-memory state.

**Telemetry:** `ProfileStore` session-lock conflicts/forced-releases,
correlated with a pending negative write, are the signal.

**Mitigation:** `ProfileStore`'s session locking (already the chosen
persistence layer) exists specifically to prevent this. The Studio's
outcome resolution must write all three participants' results in one
atomic server step (see Economy §13) rather than leave any window where a
disconnect changes which write lands.

**Cost:** a small, sub-second session-lock wait on teleport/rejoin — an
accepted cost already implicit in choosing `ProfileStore`, not new here.

## Social exploits

### 7. Three friends queueing together and always Sharing

**How it works:** a coordinated group tries to guarantee a low-risk
3-Share every time instead of an honest blind decision.

**Telemetry:** account clusters landing in the same Studio far more often
than random matchmaking odds predict; Studio groups with a 3-Share rate
statistically above the population baseline.

**Mitigation:** already decided in `design-decisions.md` Q4/Q7 — no
party-queue feature, ever, and private servers don't count toward streak.
The residual technical avenue is queue sniping (§11) — this entry's real
mitigation lives there.

**Cost:** none beyond what's already decided.

### 8. Farming NPC-filled lobbies

**How it works:** queuing during low-population windows where lobbies
skew NPC-heavy (Q2/Q5), racking up streak against predictable, sub-human
opposition.

**Telemetry:** streak-gain rate correlated with NPC-seat-count per round;
time-of-day/region clustering of a given account's sessions around
known-low-population windows.

**Mitigation:** `architecture.md` already flags the right lever —
"consider reduced or zero streak credit when more than N seats are NPCs."
This document promotes it from a consideration to a **required launch
mitigation**: no streak credit above a defined NPC-seat threshold. Exact
`N` is a playtest tuning call, but *some* threshold must ship day one.

**Cost:** real friction for legitimately low-population regions/off-hours
— a threshold that's too strict locks honest players out of progress
through no fault of their own. Needs an explicit "queue too thin for
streak credit right now" message, not silent non-progression.

### 9. Alt accounts feeding wins

**How it works:** one person controls multiple accounts, deliberately
loses on "feeder" accounts to guarantee the "main" account's best outcome
— requires the accounts to land in the same lobby, so it shares its core
mechanism with §7 and §11.

**Telemetry:** the same account-co-occurrence statistics as §7/§11, plus
shared device/IP/payment-fingerprint correlation across the co-occurring
accounts.

**Mitigation:** the no-party-queue design already raises the cost of doing
this reliably; fingerprint correlation flags likely-alt clusters for
review; one-sided outcome patterns (same feeder always loses to the same
main, repeatedly) freeze streak credit pending review.

**Cost:** real reputational risk from false positives — genuine friend
groups who occasionally land together by chance, or households sharing a
network, can trip the same fingerprint signals. This must be a
flag-for-human-review system, not an automatic ban, especially pre-launch
when the false-positive rate is completely unvalidated.

### 10. Disconnect-to-dodge a loss

**How it works:** a player about to lose the Studio decision disconnects,
hoping to avoid the personal consequence.

**Telemetry:** rate of disconnects specifically during the Studio decision
phase, segmented by whether the disconnector's post-hoc-computed choice
would have lost anyway. An unusually high rate here — despite the
mitigation below making it pointless — signals the "you still lose
regardless" messaging isn't landing.

**Mitigation:** already fully closed by design — Q4 forces the leaver's
personal loss regardless of computed outcome, and that write is part of
the same atomic resolution step as §6/§13, so there's no timing window
even at the exact right millisecond.

**Cost:** none new — this entry exists to confirm the design actually
closes it, and to specify how to verify that in production telemetry
rather than just on paper.

### 11. Queue sniping

**How it works:** two colluding accounts repeatedly attempt to join the
queue at the exact same instant, hoping matchmaking's placement logic
reliably groups near-simultaneous joins — achieving de facto party
queueing without an explicit party feature.

**Telemetry:** same co-occurrence statistics as §7/§9, plus the more
specific signal of join-timestamp deltas between co-occurring accounts
being suspiciously tight (sub-second) and repeated across many sessions —
genuine chance pairing wouldn't show a tight, repeated pattern.

**Mitigation:** matchmaking must not use naive FIFO/join-order batching
for final 6-slot assignment — shuffle the eligible waiting pool before
grouping, rather than assigning strictly by arrival order. This is what
actually breaks the timing-correlation lever queue sniping depends on;
"no party queue" alone doesn't, since it doesn't prevent two accounts from
trying to time their joins.

**Cost:** genuine randomization can slightly increase average queue wait
versus greedy FIFO grouping — a minor, deliberate UX trade-off that
belongs explicitly in `MatchmakingService`'s design, not something
discovered by accident later.

## Economy exploits

### 12. Receipt replay on developer products

**How it works:** replaying a previously-used purchase receipt (or a
client resending the same receipt ID) to try to get an item granted a
second time without paying again.

**Telemetry:** any `ProcessReceipt` call for a receipt ID already marked
processed should never happen if implemented correctly — its occurrence
at all, not just its rate, is the alarm.

**Mitigation:** the standard, well-established Roblox pattern — persist
processed receipt IDs and check-before-grant idempotently inside
`ProcessReceipt`, only returning `PurchaseGranted` after that record is
durably saved. Never grant based on the client's own claim.

**Cost:** none beyond implementing the standard pattern correctly the
first time — a "do it right on day one" item, not a tunable trade-off.

### 13. Bounty duplication across teleports

**How it works:** rapid Match→Hub→Match teleporting timed around a
Studio reward grant, exploiting the gap between "reward computed" and
"reward durably saved" — a session-lock release/reacquire race that could
either double-grant a reward or silently drop one of two near-simultaneous
writes.

**Telemetry:** any profile showing two reward grants for what should be a
single outcome-resolution event; session-lock forced-releases occurring
unusually close in time to a Studio resolution.

**Mitigation:** resolve and persist all three Studio participants'
outcomes as one atomic server step **before** releasing any of them to
teleport away — a player is physically unable to leave the Studio scene
until their own write is confirmed committed, removing the race window by
construction. Reward grants are also idempotent per round-id: a given
round can only ever grant its outcome once per participant, checked
against a stored round-id ledger, never a blind "add N to balance."

**Cost:** a brief mandatory hold in the Studio scene after the reveal,
before teleport-out is allowed — framed as part of the reveal's dramatic
beat (players are already watching the outcome resolve), not a
loading-spinner delay. A UX framing task, not a technical cost.

### 14. Streak restore after a loss

**How it works:** either (a) the same timing-race pattern as §13 applied
to a streak-reset write, or (b) exploiting a leftover admin/debug remote
that can modify streak if one ever accidentally ships live.

**Telemetry:** (a) same as §13; (b) any successful call to a
streak-modifying remote from a non-server source is itself the alarm.

**Mitigation:** (a) closed by §13's atomic-resolution pattern. (b) closed
structurally by `Net.luau` — every remote is declared in one typed
module, so an admin/debug remote either doesn't exist in production or is
visible for review in the one place anyone would look for it, rather than
an ad-hoc `RemoteEvent` left in a service folder during testing.

**Cost:** none — enforced by an architecture decision already made, not a
new mitigation requiring its own trade-off.

## Ranking, launch gate, and what can't be prevented

Ranked by expected damage to the **leaderboard's** credibility specifically
(not general severity):

| Rank | Attack | Why it ranks here |
|---|---|---|
| 1 | Speed/teleport hacks (§3) | Directly fabricates race placement — the most visible, most "screenshot-and-mock" form of a broken leaderboard. |
| 2 | Collusion/alt-farming family (§7, §9, §11) | Directly inflates the streak number with zero real skill — attacks the exact claim the leaderboard makes. Slower to surface than a speedhack, more corrosive once it does. |
| 3 | Bounty/streak duplication via teleport timing (§6, §13, §14) | A raw economy dupe reads as "the whole leaderboard is fake," not just "one player cheated" — but fully preventable by construction if built correctly from day one. |
| 4 | Farming NPC-filled lobbies (§8) | Inflates streak with reduced-but-real legitimacy; feels like exploiting a loophole rather than cheating, which makes it likely to spread by word of mouth before anyone flags it. |
| 5 | Forged completion / power-up dupe / remote spam (§1, §2, §4) | Real damage to individual matches and trust, but each instance's blast radius is one round, not a straight line to the aggregate leaderboard. |
| 6 | TeleportData tampering (§5) | Low residual risk if the architecture is followed — a "don't break the foundation" item more than an ongoing threat. |
| 7 | Disconnect-to-dodge (§10) | Already fully closed by design; ranked lowest because there's essentially nothing left to exploit. |
| — | Receipt replay (§12) | Real financial risk if missed, but not leaderboard-specific — ranked separately as a must-fix regardless of leaderboard impact. |

**Must exist before launch:** server-side position/movement validation
(§3); `NetGuard` rate limiting and payload validation on every remote
(§1); serialized power-up inventory mutations (§4); the
`TeleportData`-never-authoritative rule plus `ProfileStore` session
locking (§5, §6); no party queue, matchmaking-pool randomization against
queue sniping, and *some* NPC-seat streak-credit threshold (§7, §8, §11);
atomic, idempotent-per-round Studio outcome resolution (§6, §13, §14);
idempotent receipt handling (§12); `Net.luau` as the sole remote-
declaration surface (§14). None of these are safe to retrofit after a
live incident — they're all cheaper by construction than as a patch.

**Can wait and iterate post-launch:** deep alt-account device/IP
fingerprinting beyond basic correlation (§9) — start with logging and
manual review, build sophisticated detection once real telemetry exists
to tune against; the exact NPC-seat threshold number (§8) and the exact
movement-tolerance band (§3) — ship conservative defaults and tune against
real player and network data, matching `perf-budget.md`'s own
verify-empirically stance; account co-occurrence anomaly-detection
statistics (§9, §11) — meaningless without a real population baseline to
compare against.

**Cannot be fundamentally prevented, only detected and reversed:**

- **Subtle client-side movement/aim assistance** that stays within
  human-plausible tolerance — a script holding a reticle on target within
  tolerance (`turret-calibration`, `sensor-sweep`) is indistinguishable
  server-side from genuine skill on any single attempt. Only statistical
  anomaly detection across many sessions can flag it, and the response is
  always retroactive: ban plus streak/leaderboard-entry reversal, never a
  real-time block.
- **Out-of-game collusion between real people who land together by
  genuine chance.** Nothing technical stops two humans who recognize each
  other from choosing to cooperate once actually seated at the same
  Studio. The design can only make that rare (no party queue, randomized
  pooling) and statistically detectable if it repeats — never prevent a
  single instance of two strangers-turned-friends deciding to trust each
  other, which is, notably, not even something the game should want to
  prevent when it happens organically rather than by design.
- **Alt-account creation itself.** Roblox has no unforgeable real-world
  identity; account creation can be made more costly (device fingerprints,
  phone-verification-gated features) but never actually prevented against
  a motivated attacker. This is permanently a detect-the-pattern,
  reverse-the-credit problem, not a stop-it-at-signup one.
