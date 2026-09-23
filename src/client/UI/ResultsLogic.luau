--!strict
-- The pure half of the results screen (P6-6): what the round did to
-- this player, and the order the recap reveals it in - with the streak
-- change landing last. No Roblox API, no requires; tested under Lune
-- (tests/MenuScreens.spec).
--
-- Two sources, and they're trusted differently:
--   * RoundRecap (server, targeted, on entering Results): reason,
--     streak before/after, bounty, streak credit. Authoritative.
--   * RaceTally (counted by the client from broadcasts it already got:
--     TaskProgress, TaskQualificationResult, its own PowerUpUseResult).
--     Display-only - a modified client lying to itself about how many
--     power-ups it used changes nothing anywhere else.

local ResultsLogic = {}

export type Recap = {
	roundId: string,
	reason: string, -- ProgressionLogic.ReasonCode
	streakBefore: number,
	streakAfter: number,
	bestStreakBefore: number,
	bestStreakAfter: number,
	bounty: { streakTier: number, outcomeTag: string }?,
	streakCredited: boolean,
	npcSeatCount: number,
	npcSeatThreshold: number,
}

export type RaceTally = {
	placement: number?, -- nil if they never appeared in a standings broadcast
	fieldSize: number,
	tasksCompleted: number,
	powerUpsUsed: number,
}

local WIN_REASONS: { [string]: boolean } = {
	QualifiedWin = true,
	StudioWinSoleStealer = true,
	StudioWinLoneSharer = true,
	StudioWinAllShare = true,
}

function ResultsLogic.isWin(reason: string): boolean
	return WIN_REASONS[reason] == true
end

-- ===== the finale line ======================================================

-- nil when the player never reached the Studio - the screen then leaves
-- the finale beat out entirely rather than showing "didn't qualify"
-- twice (placement already says it).
function ResultsLogic.finaleLine(reason: string): string?
	if reason == "StudioWinSoleStealer" then
		return "You stole it - and got away with it."
	elseif reason == "StudioWinLoneSharer" then
		return "You shared, and it paid off."
	elseif reason == "StudioWinAllShare" then
		return "Everyone shared. Everyone won."
	elseif reason == "QualifiedWin" then
		return "Last finalist standing - the win is yours."
	elseif reason == "StudioLoss" then
		return "The Studio didn't go your way."
	elseif reason == "ForfeitDisconnect" then
		return "You left the Studio, which counts as a loss."
	end
	return nil
end

-- ===== the streak change ===================================================

export type StreakKind =
	"Up" -- a credited win
	| "Held" -- a win that earned no streak credit (NPC-heavy round)
	| "Died" -- a loss that ended a streak worth naming
	| "None" -- a loss from zero: nothing was lost

export type StreakChange = {
	kind: StreakKind,
	before: number,
	after: number,
	newBest: boolean,
	-- "Held" only: the specific reason, per threat-model.md §8 - never a
	-- vague "no change".
	note: string?,
}

function ResultsLogic.streakChange(recap: Recap): StreakChange
	local kind: StreakKind
	local note: string? = nil
	if recap.streakAfter > recap.streakBefore then
		kind = "Up"
	elseif ResultsLogic.isWin(recap.reason) then
		kind = "Held"
		if not recap.streakCredited then
			note = string.format(
				"%d of the seats this round were bots (the limit is %d), so the win doesn't add to your streak. Queue again for a fuller lobby.",
				recap.npcSeatCount,
				recap.npcSeatThreshold
			)
		end
	elseif recap.streakBefore > 0 then
		kind = "Died"
	else
		kind = "None"
	end
	return {
		kind = kind,
		before = recap.streakBefore,
		after = recap.streakAfter,
		newBest = recap.bestStreakAfter > recap.bestStreakBefore,
		note = note,
	}
end

-- The one-line headline for the streak beat. A dead streak is named as
-- a number, plainly - P6-5's rule for the Studio result applies here
-- too: without cruelty, but without softening.
function ResultsLogic.streakHeadline(change: StreakChange): string
	if change.kind == "Up" then
		return if change.newBest
			then string.format("Streak %d - a new best", change.after)
			else string.format("Streak %d", change.after)
	elseif change.kind == "Held" then
		return string.format("Streak holds at %d", change.after)
	elseif change.kind == "Died" then
		return string.format("Your %d-win streak ends here", change.before)
	end
	return "No streak on the line this time"
end

-- ===== sequencing ===========================================================

export type BeatId = "Placement" | "Tasks" | "PowerUps" | "Finale" | "Rewards" | "Streak"

export type Beat = { id: BeatId, at: number }

-- Seconds between beats, and the extra held breath before the streak.
-- The pause is the point: the streak is the thing the whole metagame is
-- about, so it gets a beat of silence to itself.
ResultsLogic.BEAT_GAP = 0.6
ResultsLogic.STREAK_PAUSE = 0.9

-- The recap's beats in order, each with its start time from when the
-- screen opens. The streak is always last - P6-6's one sequencing rule.
-- Finale appears only for someone who reached the Studio, Rewards only
-- for someone who has a bounty to show, Streak only when there is a
-- recap at all (a spectator has no streak change this round).
--
-- Reduced motion keeps the SAME order and timing. Reduced motion is
-- about movement (the screen swaps slides for plain appearance), not
-- pacing, and collapsing the sequence would take away the one moment of
-- suspense the screen has for the players who most need it calm.
function ResultsLogic.beats(recap: Recap?): { Beat }
	local ids: { BeatId } = { "Placement", "Tasks", "PowerUps" }
	if recap ~= nil then
		if ResultsLogic.finaleLine(recap.reason) ~= nil then
			table.insert(ids, "Finale")
		end
		if recap.bounty ~= nil and ResultsLogic.isWin(recap.reason) then
			table.insert(ids, "Rewards")
		end
		table.insert(ids, "Streak")
	end

	local out: { Beat } = {}
	local t = 0
	for i, id in ids do
		if id == "Streak" then
			t += ResultsLogic.STREAK_PAUSE
		end
		table.insert(out, { id = id :: BeatId, at = t })
		if i < #ids then
			t += ResultsLogic.BEAT_GAP
		end
	end
	return out
end

-- How many beats are showing at `elapsed` seconds in. `skipped` (a tap
-- on the recap) shows everything at once - the pacing is for the first
-- watch, not a wait a player has to sit through every round.
function ResultsLogic.revealedCount(beats: { Beat }, elapsed: number, skipped: boolean): number
	if skipped then
		return #beats
	end
	local n = 0
	for _, beat in beats do
		if beat.at <= elapsed then
			n += 1
		end
	end
	return n
end

-- "3rd of 6", with the ordinal done properly (11th/12th/13th).
function ResultsLogic.placementText(placement: number?, fieldSize: number): string
	if placement == nil then
		return "Unplaced"
	end
	local suffix = "th"
	local mod100 = placement % 100
	if mod100 < 11 or mod100 > 13 then
		local mod10 = placement % 10
		suffix = if mod10 == 1 then "st" elseif mod10 == 2 then "nd" elseif mod10 == 3 then "rd" else "th"
	end
	return string.format("%d%s of %d", placement, suffix, fieldSize)
end

return ResultsLogic
