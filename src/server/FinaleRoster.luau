--!strict
-- Who is actually in the finale, and what happens when one of them
-- leaves (P3-7). Every branch of the Decision Studio's disconnect
-- handling is decided here, as a pure function of (phase, what they'd
-- already done, whether the result is already written), so the rules
-- can be proven by a test instead of by reading a service that also
-- runs timers and writes profiles.
-- DecisionService.luau is the Roblox-touching wrapper that supplies a
-- real roster and applies what this module decides.
--
-- ===== THE TWO DIFFERENT DISCONNECT RULES, AND WHERE THE LINE IS =====
--
-- design-decisions.md answers this in two places, and they say
-- different things because they cover different moments:
--
--   Q3, "between the race and the Studio": PROMOTE the 4th-place
--   alternate into the vacated seat. Nobody has done anything yet, the
--   seat is just empty, and Q3's own mechanism is "the alternate's
--   boundary access opens and they move into the vacated slot."
--
--   Q4, "inside the Studio": do NOT promote. The leaver keeps their
--   seat, their choice is substituted with Share, and they personally
--   take the loss regardless of what the table says. Promoting here
--   would hand a spectator a live seat in a negotiation that has
--   already been happening without them - they'd be voting on promises
--   they never heard.
--
-- So the line is exactly "has the Studio started." That's
-- `resolveStartingRoster` (once, before Intro) versus `classifyLeave`
-- (every leave after it).

local FinaleRoster = {}

export type Phase = "Intro" | "Negotiate" | "Choose" | "Reveal" | "Resolve"

-- ===== case 1: building the roster before the Studio starts =============

-- One vacated seat, and who (if anyone) took it. Kept as explicit pairs
-- rather than two parallel lists so the announcement can never mismatch
-- a promotion to the wrong departure: with two qualifiers gone and only
-- one alternate, "who replaced whom" has exactly one right answer and a
-- pair says it directly.
export type SeatChange = {
	droppedId: number,
	promotedId: number?, -- nil = the seat was left empty; the finale runs smaller
}

export type StartingRoster = {
	qualifierIds: { number },
	-- Purely so the caller can announce them - the roster above is
	-- already correct without reference to these.
	changes: { SeatChange },
}

-- Q3. Takes the qualification result's own qualifier list and its
-- single alternate, plus a presence predicate, and returns the roster
-- the Studio should actually open with.
--
-- There is only ever ONE alternate (Qualification.rank returns
-- `alternate: number?`), so at most one promotion can happen no matter
-- how many qualifiers vanished at once. Two qualifiers leaving in the
-- same window therefore legitimately produces a two-player finale, and
-- Outcomes.resolve has a real two-finalist branch for exactly that
-- (P3-1) - this is not a degraded case to be avoided.
--
-- The alternate is itself checked for presence: the 4th-place finisher
-- can have left too, and promoting a player who isn't there would just
-- move the problem into the Studio, where Q4's harsher rule would then
-- apply to someone who never even got a seat.
function FinaleRoster.resolveStartingRoster(
	qualifierIds: { number },
	alternateId: number?,
	isPresent: (racerId: number) -> boolean
): StartingRoster
	local roster: StartingRoster = { qualifierIds = {}, changes = {} }
	local alternateUsed = false

	local function canPromote(): boolean
		if alternateUsed or alternateId == nil then
			return false
		end
		-- Guard against the alternate somehow already being a qualifier
		-- (it can't be, given how Qualification.rank builds the two
		-- lists, but a seat filled twice would be a silent duplicate in
		-- Outcomes.resolve's input, and that's worth one comparison).
		--
		-- Checked against the ORIGINAL qualifier list, not the seats
		-- filled so far: a first-place departure is handled before the
		-- later qualifiers have been seated at all, so a "seats so far"
		-- check would wave through an alternate who is about to be
		-- seated in their own right two iterations later. The spec's
		-- "never seats the same racer twice" case caught exactly that.
		if table.find(qualifierIds, alternateId) ~= nil then
			return false
		end
		return isPresent(alternateId :: number)
	end

	for _, id in qualifierIds do
		if isPresent(id) then
			table.insert(roster.qualifierIds, id)
			continue
		end

		if not canPromote() then
			table.insert(roster.changes, { droppedId = id, promotedId = nil })
			continue
		end

		alternateUsed = true
		table.insert(roster.qualifierIds, alternateId :: number)
		table.insert(roster.changes, { droppedId = id, promotedId = alternateId })
	end

	return roster
end

-- ===== cases 2-5: somebody leaves once the Studio is running ============

export type LeaveAction =
	-- Their seat stays, their choice becomes the configured default,
	-- and they take a forfeit loss (Q4). Cases 2 and 4.
	"SubstituteDefault"
	-- They already locked in: that choice stands untouched, and they
	-- still take a forfeit loss for leaving (case 3). The distinction
	-- from SubstituteDefault matters - a player who locked Steal and
	-- then quit must not have it quietly turned into Share.
	| "KeepLockedChoice"
	-- The result is already computed and written (case 5). Nothing
	-- about their record changes, because it is already final - and
	-- critically, no forfeit is applied on top of it.
	| "AlreadyResolved"

export type LeaveDecision = {
	action: LeaveAction,
	-- Whether the leaver personally takes a loss for leaving. Q4: "the
	-- leaver always personally takes the loss regardless of the
	-- computed table outcome" - true for every in-Studio leave EXCEPT
	-- one that happens after the result was already written.
	forfeits: boolean,
	-- Whether the others' resolution is still pending, i.e. whether the
	-- caller needs to check "has everyone locked now?" after applying
	-- this.
	mayCompleteRound: boolean,
}

-- The whole of Q4, as one decision.
--
-- `outcomeWritten` is the load-bearing input, not `phase`: the profile
-- writes happen at the END of Choose, inside the same synchronous call
-- that then enters Reveal (DecisionService's resolveAndReveal). So the
-- honest question is never "which phase are we in" but "has the result
-- already been committed" - a leave during Choose is case 3 or 4 if it
-- lands before that call and case 5 if it lands after, even though the
-- phase name is the same for a fraction of a second either side.
-- Phase is still taken, because a leave outside the Studio entirely
-- must not be treated as a finale forfeit at all.
function FinaleRoster.classifyLeave(phase: Phase?, hasLockedIn: boolean, outcomeWritten: boolean): LeaveDecision
	if outcomeWritten or phase == "Reveal" or phase == "Resolve" then
		-- Case 5. "The result was already written before the reveal, so
		-- nothing changes." Quitting during the reveal animation cannot
		-- dodge a loss, and equally cannot ADD one to a player who just
		-- won - which is the half of this that a naive "leaving always
		-- forfeits" rule would get wrong.
		return { action = "AlreadyResolved", forfeits = false, mayCompleteRound = false }
	end

	if hasLockedIn then
		-- Case 3.
		return { action = "KeepLockedChoice", forfeits = true, mayCompleteRound = true }
	end

	-- Cases 2 and 4 - the same handling, deliberately. A leave during
	-- Negotiate and a leave during Choose-without-locking both end with
	-- the seat holding the default choice; the only difference is how
	-- long the seat sits that way before it's read, which changes
	-- nothing about the outcome.
	return { action = "SubstituteDefault", forfeits = true, mayCompleteRound = true }
end

-- ===== case 6: the server shuts down mid-finale =========================

export type ShutdownPolicy =
	-- The result was already computed and written to profiles. It
	-- stands - ProfileStore's own BindToClose saves Profile.Data as it
	-- is, which is exactly what we want here.
	"KeepWrittenResult"
	-- Nothing was resolved. Every participant's streak is preserved
	-- exactly as it was before the round: no win, no loss, no forfeit.
	| "PreserveStreaks"

-- THE DECISION, and the reasoning, because P3-7 asks for it explicitly:
--
-- A shutdown mid-finale is a no-op for everyone. Nobody wins, nobody
-- loses, every streak survives untouched.
--
-- 1. It is not the player's doing. Q4's forfeit rule exists to close
--    disconnect-to-dodge (threat-model.md §10) - it punishes a CHOICE
--    to leave. A BindToClose has no such choice behind it: a player
--    cannot trigger one. Only Roblox (an update push, a migration) or
--    the developer can, so there is no exploit surface to defend and
--    the reasoning that justifies the forfeit simply doesn't apply.
-- 2. The streak is the entire metagame and resets completely on any
--    loss (gdd.md). Ending a 14-round streak because Roblox pushed an
--    engine update mid-negotiation would be the single most
--    rage-inducing possible behaviour in this game, and it would be
--    indistinguishable from a bug to the player it happened to.
-- 3. Awarding a WIN instead would be worse: it would make shutdowns
--    valuable, and "valuable" plus "unpredictable" is how you get
--    players convinced the game is rigged.
--
-- The one thing that must NOT happen is the pending-round-outcome
-- resolvers firing on the way down - those apply Q4's forfeit loss, and
-- on a shutdown every qualifier still has one registered. See
-- DecisionService.handleServerShutdown, which clears them.
function FinaleRoster.shutdownPolicy(outcomeWritten: boolean): ShutdownPolicy
	return if outcomeWritten then "KeepWrittenResult" else "PreserveStreaks"
end

return FinaleRoster
