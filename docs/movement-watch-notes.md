# Movement sanity checker — notes (P2-9)

Companion to `src/server/Services/MovementWatch.luau` (the implementation
— its own header comment is the canonical version of "what counts as a
legitimate cause of apparent speed," read that first if this ever seems
to disagree). This is the short note the task itself asked for: what to
expect from mobile networks specifically, and how to read the first
week of `MovementWatch AUDIT`/`MovementWatch [Log/Flag]` lines before
touching any threshold — including before deciding whether "Act" should
ever do anything.

## False-positive sources that will dominate on mobile

**In rough order of how often I'd expect each to actually show up**,
given CLAUDE.md's own mobile-first stance (this game targets a cheap
Android phone on whatever network it happens to have):

1. **Background app throttling.** A phone backgrounding the Roblox app
   briefly (a notification, a call, the OS reclaiming CPU) doesn't pause
   the character server-side — the player's position just doesn't
   update for a beat, then the client's next replication carries several
   "missed" frames of real movement at once. This looks identical to a
   burst of legitimate movement compressed into a short window, which is
   *exactly* what the rolling score (not an instant judgement) exists to
   absorb, but it's still the single most common source of a `Log`-level
   line I'd expect to see.

2. **Cellular network jitter / handoff.** A player moving between cell
   towers, or on a congested connection, sees position updates arrive in
   uneven bursts rather than smoothly — several studs of real movement
   replicating in one packet after a gap, not because they moved fast,
   but because the *updates* were slow and then caught up. Same shape as
   #1, same reason the rolling score should absorb it rather than a
   single-sample check flagging it outright.

3. **Low, variable frame rate on cheap hardware.** This affects the
   *client's* perceived smoothness, not the server-authoritative
   position sampling this system does — but a struggling client is more
   likely to also be the one with irregular network flushing, so the two
   compound in practice even though they're not the same root cause.

4. **A player's own Wi-Fi/cellular handoff mid-round**, briefly
   disconnecting and reconnecting the DataModel's replication rather than
   the player themselves — server-side this can look like a large jump
   the instant replication resumes. This is functionally the same shape
   as a lag spike (#1/#2) from this system's point of view; nothing
   about it is mobile-specific per se, but it's more frequent on mobile
   networks than on a stable wired connection.

**What this does NOT need a mobile-specific fix for:** falling, the
respawn frame, and server-initiated teleports are all handled
structurally (see the service's own header comment) regardless of
platform — they're not mobile false-positive sources, they're always-
true legitimate causes this system already accounts for on every
platform.

## How to read the first week of logs before enabling any enforcement

1. **Don't look at individual `Log`-level lines in isolation.** A `Log`
   line means one sample exceeded the tolerance cap once — on mobile,
   expect this to happen occasionally to nearly every real player over a
   full week, for the reasons above. It is not itself evidence of
   anything. Only `Flag`-level lines (the rolling score has climbed
   enough to suggest a *pattern*, not a one-off) are worth reading
   individually at all.

2. **Pull `MovementWatch.getRoundSummary()` after each round, or read
   the automatic per-round summary `MovementWatch` already prints when
   Race ends**, and look at the SHAPE of `violationCount` /
   `sampleCount` across the week, not any single round. A player who's
   consistently at 1-2 violations out of ~40 samples a round across many
   rounds is almost certainly mobile jitter (see above). A player whose
   `violationCount` spikes to a large fraction of `sampleCount` in one
   specific round, or whose `maxExcessRatio` is dramatically higher than
   everyone else's, is the pattern actually worth a human looking at.

3. **Cross-reference `maxExcessRatio`, not just `violationCount`.** A
   pile of samples barely over the tolerance cap (`excessRatio` just
   above 0) is consistent with normal network noise even if there are
   many of them. A `maxExcessRatio` of, say, 2+ (observed speed roughly
   3x the allowed cap) on even a single sample is a different kind of
   signal — worth pulling that specific event's raw numbers
   (`observedSpeed`/`allowedSpeed`/`at`) and checking what round state
   and what StatusEffects were active on that player at that timestamp.

4. **Before raising or lowering any threshold, change one variable at a
   time and let a full week pass again.** `movementSpeedTolerance`
   (the grace multiplier) is the right first knob if `Log`-level noise
   is overwhelming — it directly controls how much of the mobile jitter
   above gets absorbed before contributing anything to the score at all.
   `movementViolationDecayPerSecond` is the second knob if scores are
   climbing during ordinary play but never quite reaching `Flag` (raise
   it, so an isolated burst decays back out faster) or `Flag` triggers
   too easily during clearly-legitimate play (lower it). Resist tuning
   both in the same week — a threshold change and a genuine cheating
   pattern showing up around the same time are otherwise impossible to
   tell apart after the fact.

5. **Do not enable any "Act" behavior from this week's data alone.**
   This version is LOG ONLY by design — the numbers above are a starting
   point for tuning `movementSpeedTolerance`/decay/`Log`/`Flag`, not a
   readiness signal for enforcement. Enabling anything at "Act" (a kick,
   a position correction, anything else) is a separate decision this
   task deliberately doesn't make, and should only happen after
   `Flag`-level events have been manually reviewed against real replays
   or logs for long enough to be confident the false-positive rate at
   that level is genuinely low — not just "lower than Log."
