--!strict
-- The title ladder's rules (P4-2), as arithmetic: which titles a
-- bestStreak has unlocked, which ones a given change has JUST unlocked,
-- which one to display, whether a title may be shown at all in the
-- current round state, and what an NPC should plausibly be wearing.
-- TitleService.luau is the Roblox-touching wrapper that reads real
-- profiles, fires the unlock remote and draws the nametag.
--
-- ===== WHY UNLOCKING IS A PURE FUNCTION OF bestStreak ===================
--
-- gdd.md §3: titles are "never revoked when a streak resets," and P4-2
-- calls that permanence "the whole emotional point," asking for it to
-- be structurally impossible to revoke one. Three separate things make
-- that true here, and none of them is a rule someone has to remember:
--
--   1. `unlockedFor` is a function of bestStreak ALONE. currentStreak
--      is not a parameter, so no amount of losing can be expressed as
--      an input to it.
--   2. bestStreak itself is never lowered by anything -
--      ProgressionLogic.applyResult (P4-1) only ever raises it, and
--      that is asserted for every reason code in its own spec.
--   3. The stored list is append-only (DataService.unlockTitle), so
--      even a recomputation that somehow returned less could not
--      remove what is already there.
--
-- There is deliberately no `revoke`, `lock` or `clear` function in this
-- module. Adding one would be the bug.

local TitleLogic = {}

-- Structurally identical to Validate.TitleDef, duplicated rather than
-- required for the reason ProfileLogic's header gives about
-- Validate.BountyTier: a Roblox Instance-path require would make this
-- module unloadable under Lune, and Luau's structural typing means a
-- real TitleDef satisfies this with no cast at the call site.
export type TitleDef = {
	id: string,
	displayName: string,
	colorHex: string,
	minStreak: number,
	effect: ("Glow" | "Pulse" | "Rainbow")?,
}

-- ===== unlocking ============================================================

-- Every title this bestStreak has earned, lowest rung first. Sorted by
-- threshold rather than returned in registry order, so the result never
-- depends on a filename.
function TitleLogic.unlockedFor(titles: { TitleDef }, bestStreak: number): { TitleDef }
	local unlocked: { TitleDef } = {}
	for _, def in titles do
		if bestStreak >= def.minStreak then
			table.insert(unlocked, def)
		end
	end
	table.sort(unlocked, function(a, b)
		return a.minStreak < b.minStreak
	end)
	return unlocked
end

-- The titles crossed by a bestStreak moving from `previousBest` to
-- `newBest` - i.e. thresholds in (previousBest, newBest]. This is what
-- the unlock notification fires for.
--
-- A range rather than a single title, because bestStreak can jump by
-- more than one rung in one change: a returning player whose profile
-- migrated, a config edit that adds a rung below where someone already
-- is, or simply a threshold gap of 1. Firing one notification and
-- silently dropping the rest would leave titles unlocked that the
-- player was never told about.
--
-- Empty when bestStreak went nowhere or backwards - the latter cannot
-- happen (see this file's header) but returning {} rather than
-- erroring keeps a recomputation harmless.
function TitleLogic.newlyUnlocked(titles: { TitleDef }, previousBest: number, newBest: number): { TitleDef }
	local crossed: { TitleDef } = {}
	if newBest <= previousBest then
		return crossed
	end

	for _, def in titles do
		if def.minStreak > previousBest and def.minStreak <= newBest then
			table.insert(crossed, def)
		end
	end
	table.sort(crossed, function(a, b)
		return a.minStreak < b.minStreak
	end)
	return crossed
end

-- The top rung reached, which is what a player who has never chosen a
-- title should be shown. nil below the first threshold.
function TitleLogic.highestUnlocked(titles: { TitleDef }, bestStreak: number): TitleDef?
	local unlocked = TitleLogic.unlockedFor(titles, bestStreak)
	return unlocked[#unlocked]
end

function TitleLogic.findById(titles: { TitleDef }, titleId: string?): TitleDef?
	if titleId == nil then
		return nil
	end
	for _, def in titles do
		if def.id == titleId then
			return def
		end
	end
	return nil
end

-- Equipping is allowed only for something already unlocked. The real
-- enforcement is DataService.setEquippedTitle, which checks the stored
-- list and refuses - this is the same check in pure form, so the
-- service can reject a bad request without a profile round-trip and so
-- the rule is testable.
function TitleLogic.canEquip(unlockedIds: { string }, titleId: string?): boolean
	if titleId == nil then
		return true -- unequipping is always allowed
	end
	return table.find(unlockedIds, titleId) ~= nil
end

-- ===== visibility: design-decisions.md Q7, condition 1 ==================

-- "Streak is never visible to other players during a live round - hub
-- and post-match leaderboard only, never an in-round HUD, NAMEPLATE, or
-- any other tell (including indirect ones)" - Q7, verbatim, and it says
-- "nameplate" specifically.
--
-- A title is exactly such an indirect tell: it maps to a bestStreak
-- threshold, so "Untouchable" over someone's head announces a player
-- worth targeting. Q7's whole safety argument is that a rival cannot
-- identify a target mid-round, and that argument is load-bearing for
-- the harsh streak-reset rule the game is built on.
--
-- So titles are shown in the pre-round lobby and after the result is
-- in, and suppressed for every state in between. The Decision Studio
-- counts as live and is suppressed too: three finalists negotiating
-- would read a rival's rung as information about how badly they need
-- the win.
--
-- `showDuringRound` is GameConfig.titleDisplayDuringRound, which exists
-- so this is a config flip rather than a code change if the design is
-- ever revisited. It defaults to false; flipping it to true means
-- amending Q7, not just this flag.
local VISIBLE_STATES: { [string]: boolean } = {
	WaitingForPlayers = true, -- the pre-round lobby on this server
	Results = true, -- post-match
	Cleanup = true, -- still post-match; the results screen is usually still up
}

function TitleLogic.isVisibleInState(roundState: string, showDuringRound: boolean): boolean
	if showDuringRound then
		return true
	end
	return VISIBLE_STATES[roundState] == true
end

-- ===== NPC titles ===========================================================

-- P4-2: "titles must appear for NPCs too, drawn from a plausible fake
-- distribution, so a bot-filled lobby does not look obviously fake."
--
-- Weighted toward the low rungs, and the top rungs are excluded
-- outright. A lobby where two bots wear Touch Grass is more obviously
-- fake than one where they wear nothing - the rarest titles are rare,
-- and a player who has actually seen how hard rung 8 is would clock it
-- instantly. `maxRungExclusive` is how many of the top rungs are off
-- limits.
--
-- The distribution is a simple decreasing weight over the allowed
-- rungs, plus a real chance of no title at all, because plenty of
-- genuine players haven't equipped one.
function TitleLogic.pickNPCTitle(
	titles: { TitleDef },
	roll: number,
	noTitleChance: number,
	topRungsExcluded: number
): TitleDef?
	if roll < noTitleChance then
		return nil
	end

	local ladder: { TitleDef } = table.clone(titles)
	table.sort(ladder, function(a, b)
		return a.minStreak < b.minStreak
	end)

	local allowed = #ladder - math.max(topRungsExcluded, 0)
	if allowed <= 0 then
		return nil
	end

	-- Re-normalise the roll across the non-"no title" range, so
	-- noTitleChance doesn't skew which rung gets picked.
	local span = math.max(1 - noTitleChance, 1e-6)
	local normalised = math.clamp((roll - noTitleChance) / span, 0, 0.999999)

	-- Weight rung i as (allowed - i + 1): the first rung is the most
	-- common, the last allowed one the rarest.
	local totalWeight = 0
	for index = 1, allowed do
		totalWeight += (allowed - index + 1)
	end

	local target = normalised * totalWeight
	local cumulative = 0
	for index = 1, allowed do
		cumulative += (allowed - index + 1)
		if target < cumulative then
			return ladder[index]
		end
	end
	return ladder[allowed]
end

return TitleLogic
