--!strict
-- Steal/Share Decision Studio outcome resolution (P3-1). Pure - no
-- Roblox API calls, and no requires of sibling shared modules (the same
-- self-contained stance Net.luau/Validate.luau/ProfileLogic.luau all
-- take, and for the same reason - see testing-conventions.md: this has
-- to stay requirable under Lune for headless tests, tests/Outcomes.
-- spec.luau).
--
-- Bounty numbers always come from the CALLER, never a literal in this
-- module ("bounty values come from the central config," the task's own
-- requirement, verbatim) - resolved from GameConfig.bountyTiers via
-- ProfileLogic.resolveBountyTier against each player's OWN streak.
-- design-decisions.md Q1 is explicit that this is per-player, not
-- per-Studio: "players at different streak tiers in the same Studio
-- each resolve their own package independently against their own tier
-- - there's no shared pot." `FinalistInput` below duplicates the three
-- VU fields it actually needs from Validate.luau's BountyTier rather
-- than requiring that module - the same duplication ProfileLogic.luau's
-- own BountyTier already establishes as this repo's precedent; a real
-- Validate.BountyTier value (or ProfileLogic.BountyTier) satisfies this
-- structurally, no cast needed at the call site.
--
-- FEWER THAN THREE FINALISTS: design-decisions.md Q3 guarantees the
-- Decision Studio always resolves with exactly 3 (NPC backfill covers
-- any gap - "there is no void case"), so in the shipped game
-- resolveTwo/resolveOne below are defensive, not a path DecisionService
-- (P3-2) should ever normally hit. They're still implemented explicitly
-- rather than left to fall out of the 3-player code by accident (the
-- task's own requirement) precisely because "shouldn't happen" isn't
-- the same guarantee as "can't happen," and a pure resolver should be
-- total over its declared input range regardless.
--
-- 1-PLAYER RULE, A DESIGN CALL THIS TASK MAKES EXPLICITLY (not covered
-- by any existing doc): a solo finalist's choice has no counterpart to
-- act on - nobody to steal from, nobody to be betrayed by - so Steal vs
-- Share carries no game-theoretic meaning at all for them. Rather than
-- reward simply being the last one standing (likely due to OTHER
-- players disconnecting, not skill in the actual Steal/Share dynamic)
-- with the best possible payout, a solo finalist always resolves at the
-- baseline all-share amount regardless of which they pick. Flag this
-- for the project owner to override if a different rule is wanted - it
-- is a reasonable default, not a locked decision the way design-
-- decisions.md's eight resolved questions are.

local Outcomes = {}

export type Choice = "Steal" | "Share"

export type FinalistInput = {
	playerId: number,
	choice: Choice,
	soleStealerVU: number,
	loneSharerVU: number,
	allShareVU: number,
}

export type WinnerEntry = {
	playerId: number,
	bountyVU: number,
}

export type OutcomeResult = {
	branch: string, -- names the resolved branch, for analytics and the reveal animation
	winners: { WinnerEntry },
	loserIds: { number },
}

local function countSteals(finalists: { FinalistInput }): number
	local stealCount = 0
	for _, finalist in finalists do
		if finalist.choice == "Steal" then
			stealCount += 1
		end
	end
	return stealCount
end

-- Three finalists - the four rules the task names explicitly, verbatim.
local function resolveThree(finalists: { FinalistInput }): OutcomeResult
	local stealCount = countSteals(finalists)

	if stealCount == 1 then
		-- 1 Steal, 2 Share: the stealer wins the large bounty; the sharers lose.
		local winners: { WinnerEntry } = {}
		local losers: { number } = {}
		for _, finalist in finalists do
			if finalist.choice == "Steal" then
				table.insert(winners, { playerId = finalist.playerId, bountyVU = finalist.soleStealerVU })
			else
				table.insert(losers, finalist.playerId)
			end
		end
		return { branch = "SoleSteal", winners = winners, loserIds = losers }
	elseif stealCount == 2 then
		-- 2 Steal, 1 Share: the sharer wins the small bounty; the stealers lose.
		local winners: { WinnerEntry } = {}
		local losers: { number } = {}
		for _, finalist in finalists do
			if finalist.choice == "Share" then
				table.insert(winners, { playerId = finalist.playerId, bountyVU = finalist.loneSharerVU })
			else
				table.insert(losers, finalist.playerId)
			end
		end
		return { branch = "LoneShare", winners = winners, loserIds = losers }
	elseif stealCount == 0 then
		-- 3 Share: all three win the smallest bounty.
		local winners: { WinnerEntry } = {}
		for _, finalist in finalists do
			table.insert(winners, { playerId = finalist.playerId, bountyVU = finalist.allShareVU })
		end
		return { branch = "AllShare", winners = winners, loserIds = {} }
	else -- stealCount == 3
		-- 3 Steal: nobody wins; all three lose.
		local losers: { number } = {}
		for _, finalist in finalists do
			table.insert(losers, finalist.playerId)
		end
		return { branch = "AllSteal", winners = {}, loserIds = losers }
	end
end

-- Two finalists - the 3-player rules' natural asymmetric collapse: a
-- lone stealer still takes everything, mutual sharing still pays out
-- (at the all-share rate, the closest existing tier to "everyone present
-- cooperated"), mutual stealing still pays nobody.
local function resolveTwo(finalists: { FinalistInput }): OutcomeResult
	local stealCount = countSteals(finalists)

	if stealCount == 0 then
		local winners: { WinnerEntry } = {}
		for _, finalist in finalists do
			table.insert(winners, { playerId = finalist.playerId, bountyVU = finalist.allShareVU })
		end
		return { branch = "TwoShare", winners = winners, loserIds = {} }
	elseif stealCount == 1 then
		local winners: { WinnerEntry } = {}
		local losers: { number } = {}
		for _, finalist in finalists do
			if finalist.choice == "Steal" then
				table.insert(winners, { playerId = finalist.playerId, bountyVU = finalist.soleStealerVU })
			else
				table.insert(losers, finalist.playerId)
			end
		end
		return { branch = "OneStealOneShare", winners = winners, loserIds = losers }
	else -- stealCount == 2
		local losers: { number } = {}
		for _, finalist in finalists do
			table.insert(losers, finalist.playerId)
		end
		return { branch = "TwoSteal", winners = {}, loserIds = losers }
	end
end

-- One finalist - see this file's own header comment for the reasoning:
-- always the baseline all-share payout, regardless of choice.
local function resolveOne(finalists: { FinalistInput }): OutcomeResult
	local only = finalists[1]
	return {
		branch = "SoloFinalist",
		winners = { { playerId = only.playerId, bountyVU = only.allShareVU } },
		loserIds = {},
	}
end

-- Pure: resolves 1, 2 or 3 finalists' Steal/Share choices into winners,
-- losers and a named branch. Errors outside that range - Ground Rule 2's
-- "fail loudly" stance applies to a caller bug (0 or 4+ finalists) the
-- same way it applies to a bad config file.
function Outcomes.resolve(finalists: { FinalistInput }): OutcomeResult
	local count = #finalists
	assert(count >= 1 and count <= 3, string.format("Outcomes.resolve: expected 1-3 finalists, got %d", count))

	if count == 3 then
		return resolveThree(finalists)
	elseif count == 2 then
		return resolveTwo(finalists)
	end
	return resolveOne(finalists)
end

return Outcomes
