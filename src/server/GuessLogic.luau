--!strict
-- Finale guesses (payoff-loop-roadmap.md step 2), as pure rules. Every
-- player knocked out of the race gets one Guess Token per round and
-- picks the finalist who walks out. A correct guess earns one streak
-- shield, but only when the Studio has a single winner who won as a
-- stealer or a sharer. design-decisions.md Q7's "streak cash-out,
-- own-streak indicator, finale guesses" applied case has the owner's
-- answers; this file is them as arithmetic.
--
-- Self-contained: no requires of sibling files, no Roblox API calls, so
-- it stays requirable under Lune (tests/GuessLogic.spec.luau). The
-- service that takes a guess intent (step 2b) owns the round's timing
-- and the player list; this module only judges what it's handed.
--
-- Q7 CONDITION 1: a guess shows nothing about anyone's streak. The
-- targets are finalists by id, and the shield a guess earns is the
-- guesser's own, told to them alone.

local GuessLogic = {}

-- The two Outcomes tags a lone winner can carry and still count. Restated
-- (as Outcomes.OutcomeTag is) so this module stays require-free.
-- "AllShare" is left out on purpose: every all-share result, and the
-- SoloFinalist default, wins nothing (the owner's rule).
local COUNTED_TAGS: { [string]: boolean } = {
	SoleStealer = true,
	LoneSharer = true,
}

-- The slice of Outcomes.OutcomeResult this module reads.
export type ResolvedResult = {
	winners: { { playerId: number, outcomeTag: string } },
}

-- The finalist who walks out, or nil when no guess can win this round.
-- Keyed on the winners list rather than the branch name, so a branch
-- added to Outcomes later is judged by what it paid, not by its name:
-- exactly one winner, tagged as a lone stealer or a lone sharer.
-- All-share (any count), all-steal (no winners) and the SoloFinalist
-- default (tagged AllShare) all come back nil.
function GuessLogic.walkerOut(result: ResolvedResult): number?
	if #result.winners ~= 1 then
		return nil
	end
	local only = result.winners[1]
	if not COUNTED_TAGS[only.outcomeTag] then
		return nil
	end
	return only.playerId
end

-- Whether a guess earns a shield. Nil (no guess placed) never does.
function GuessLogic.isCorrect(guessedId: number?, result: ResolvedResult): boolean
	local walker = GuessLogic.walkerOut(result)
	return walker ~= nil and guessedId == walker
end

-- Why a guess intent is refused. Analytics keys as much as control flow,
-- the same stance as ProgressionLogic's reason codes.
export type GuessRefusal =
	-- The guesser is sitting in the Studio. Finalists don't guess.
	"IsFinalist"
	-- The target isn't one of this round's finalists.
	| "NotAFinalist"
	-- The guesser already spent this round's token. One token, one
	-- guess: it can't be changed once placed.
	| "AlreadyGuessed"

-- Judges one guess intent against the round. `finalistIds` is the
-- Studio's seats, NPC seats included (no NPC limit, per the owner);
-- `guesses` is guesser -> target for the guesses already taken this
-- round. Whether the guesser was in this round at all, and whether the
-- window is still open, are the service's checks: it holds the round.
function GuessLogic.validate(
	guesserId: number,
	targetId: number,
	finalistIds: { number },
	guesses: { [number]: number }
): (boolean, GuessRefusal?)
	if table.find(finalistIds, guesserId) ~= nil then
		return false, "IsFinalist"
	end
	if table.find(finalistIds, targetId) == nil then
		return false, "NotAFinalist"
	end
	if guesses[guesserId] ~= nil then
		return false, "AlreadyGuessed"
	end
	return true, nil
end

-- Every guesser who earns a shield this round, in ascending id order so
-- the grants (and their audit lines) come out the same every time.
function GuessLogic.shieldWinners(guesses: { [number]: number }, result: ResolvedResult): { number }
	local walker = GuessLogic.walkerOut(result)
	local winners: { number } = {}
	if walker == nil then
		return winners
	end
	for guesserId, targetId in guesses do
		if targetId == walker then
			table.insert(winners, guesserId)
		end
	end
	table.sort(winners)
	return winners
end

return GuessLogic
