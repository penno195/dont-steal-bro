--!strict
-- The betrayal card and trust stat (payoff-loop-roadmap.md step 7), as
-- pure rules. design-decisions.md Q5's "betrayal card and trust stat"
-- applied case has the owner's answers; this file is who they cover.
--
-- "Betrayed" means a sharer who lost to a lone stealer. Two stealers
-- can't rob anyone (the lone sharer wins there, payoff-table.md), so a
-- betrayed sharer always has exactly one name on their card.
--
-- Self-contained: no requires of sibling files, no Roblox API calls, so
-- it stays requirable under Lune (tests/BetrayalLogic.spec.luau). Which
-- finalists are still present, and whether the match is practice (card
-- yes, stat no), are the service's checks.

local BetrayalLogic = {}

-- The slices of Outcomes.FinalistInput and Outcomes.OutcomeResult this
-- module reads, restated (as GuessLogic does) to stay require-free.
export type Finalist = {
	playerId: number,
	choice: string,
}

export type ResolvedResult = {
	winners: { { playerId: number, outcomeTag: string } },
}

export type Robbery = {
	sharerId: number,
	stealerId: number,
}

-- Every betrayed sharer and who robbed them, in seat order. Empty unless
-- the result has exactly one winner and it won as the lone stealer.
-- Keyed on the winners list rather than the branch name (GuessLogic's
-- stance), so the three-seat sole steal and the two-seat
-- one-steal-one-share are the same case here.
function BetrayalLogic.robberies(finalists: { Finalist }, result: ResolvedResult): { Robbery }
	local out: { Robbery } = {}
	if #result.winners ~= 1 or result.winners[1].outcomeTag ~= "SoleStealer" then
		return out
	end
	local stealerId = result.winners[1].playerId
	for _, finalist in finalists do
		if finalist.choice == "Share" and finalist.playerId ~= stealerId then
			table.insert(out, { sharerId = finalist.playerId, stealerId = stealerId })
		end
	end
	return out
end

-- Who robbed this player, or nil when they weren't betrayed.
function BetrayalLogic.robbedBy(playerId: number, robberies: { Robbery }): number?
	for _, robbery in robberies do
		if robbery.sharerId == playerId then
			return robbery.stealerId
		end
	end
	return nil
end

return BetrayalLogic
