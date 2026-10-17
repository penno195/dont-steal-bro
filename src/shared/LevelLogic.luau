--!strict
-- What every round pays, win or lose (design-decisions.md Q1's "a payoff
-- for every round", 2026-10-17; payoff-loop-roadmap.md step 1): XP toward
-- a lifetime account level, coins for the race place, and coins for each
-- level gained. Win payouts stay in RewardLogic; this is the floor
-- under them.
--
-- The profile stores only lifetime `xp`. The level is always worked out
-- from it here, so the two can never disagree and the client can draw
-- the same XP bar from the same number.
--
-- Self-contained on purpose - no requires, no Roblox API calls - so it
-- stays requirable under Lune for headless tests (tests/LevelLogic.spec)
-- and from both server and client (Ground Rule 4). The types duplicate
-- the slices of Validate's RoundRewardsConfig this module reads;
-- structural typing means the real config satisfies them with no cast.

local LevelLogic = {}

export type RoundXpConfig = {
	perTask: number,
	studio: number,
	win: number,
	perHit: number,
	maxHits: number,
	byPlace: { number },
}

export type LevelCurveConfig = {
	firstLevelXp: number,
	perLevelXp: number,
	maxLevel: number,
	levelUpCurrency: number,
}

export type RoundRewardsConfig = {
	xp: RoundXpConfig,
	currencyByPlace: { number },
	level: LevelCurveConfig,
}

-- What one participant did in one round. The server fills this from
-- its own records (TaskService, PowerUpService, the finale result);
-- nothing here comes from a client.
export type RoundPerformance = {
	tasksDone: number,
	place: number?, -- race finish order, 1 = first; nil = no place recorded
	reachedStudio: boolean, -- sat in the Decision Studio as a finalist
	won: boolean, -- progressed from the Studio
	hits: number, -- power-ups landed on a rival
}

export type Progress = {
	level: number,
	xpIntoLevel: number, -- XP earned since reaching `level`
	xpForNext: number, -- XP `level` -> `level + 1` costs; 0 at maxLevel
}

export type RoundAward = {
	xpGained: number,
	xpAfter: number,
	levelBefore: number,
	levelAfter: number,
	placeCurrency: number,
	levelUpCurrency: number,
	milestonesReached: { number }, -- milestone levels crossed this round, ascending
}

local function wholeAtLeastZero(value: number): number
	if value ~= value then -- NaN
		return 0
	end
	return math.max(0, math.floor(value))
end

-- ===== the level curve ======================================================

-- XP to go from `level` to `level + 1`.
function LevelLogic.xpToNext(curve: LevelCurveConfig, level: number): number
	return curve.firstLevelXp + curve.perLevelXp * (level - 1)
end

-- The level `totalXp` reaches, and how far into it. Starts at level 1.
-- XP past maxLevel still counts toward nothing, but is kept on the
-- profile, so raising maxLevel later lets it count.
function LevelLogic.progressFor(curve: LevelCurveConfig, totalXp: number): Progress
	local remaining = wholeAtLeastZero(totalXp)
	local level = 1
	while level < curve.maxLevel do
		local cost = LevelLogic.xpToNext(curve, level)
		if remaining < cost then
			return { level = level, xpIntoLevel = remaining, xpForNext = cost }
		end
		remaining -= cost
		level += 1
	end
	return { level = curve.maxLevel, xpIntoLevel = 0, xpForNext = 0 }
end

-- ===== one round ============================================================

-- A place outside the list (or none) pays nothing.
local function byPlace(list: { number }, place: number?): number
	if place == nil then
		return 0
	end
	return list[place] or 0
end

function LevelLogic.roundXp(config: RoundXpConfig, performance: RoundPerformance): number
	local xp = config.perTask * wholeAtLeastZero(performance.tasksDone)
		+ byPlace(config.byPlace, performance.place)
		+ config.perHit * math.min(config.maxHits, wholeAtLeastZero(performance.hits))
	if performance.reachedStudio then
		xp += config.studio
		-- A win can only come from the Studio, so it can't pay on its own.
		if performance.won then
			xp += config.win
		end
	end
	return xp
end

function LevelLogic.placeCurrency(config: RoundRewardsConfig, place: number?): number
	return byPlace(config.currencyByPlace, place)
end

-- Everything one round pays a participant. `milestones` is every level
-- that unlocks something (LevelLogic.milestoneLevels below); the ones
-- crossed this round come back in `milestonesReached`.
function LevelLogic.award(
	config: RoundRewardsConfig,
	xpBefore: number,
	performance: RoundPerformance,
	milestones: { number }
): RoundAward
	local before = wholeAtLeastZero(xpBefore)
	local gained = LevelLogic.roundXp(config.xp, performance)
	local after = before + gained
	local levelBefore = LevelLogic.progressFor(config.level, before).level
	local levelAfter = LevelLogic.progressFor(config.level, after).level

	local reached = {}
	for _, milestone in milestones do
		if milestone > levelBefore and milestone <= levelAfter then
			table.insert(reached, milestone)
		end
	end
	table.sort(reached)

	return {
		xpGained = gained,
		xpAfter = after,
		levelBefore = levelBefore,
		levelAfter = levelAfter,
		placeCurrency = LevelLogic.placeCurrency(config, performance.place),
		levelUpCurrency = config.level.levelUpCurrency * (levelAfter - levelBefore),
		milestonesReached = reached,
	}
end

-- ===== level-only cosmetics =================================================

-- A cosmetic a level unlocks (CosmeticDef.unlockLevel). Built by the
-- caller from the Cosmetics registry, enabled ones only.
export type LevelUnlock = {
	id: string,
	level: number,
}

-- Every level that unlocks something, once each, ascending.
function LevelLogic.milestoneLevels(unlocks: { LevelUnlock }): { number }
	local seen: { [number]: boolean } = {}
	local levels = {}
	for _, unlock in unlocks do
		if not seen[unlock.level] then
			seen[unlock.level] = true
			table.insert(levels, unlock.level)
		end
	end
	table.sort(levels)
	return levels
end

-- The ids `level` has unlocked that `owned` doesn't hold yet. Every one
-- at or below the level, not just the ones crossed this round, so a
-- cosmetic added at level 5 later still reaches a player already past
-- it, at their next round.
function LevelLogic.unlocksDue(unlocks: { LevelUnlock }, level: number, owned: { string }): { string }
	local have: { [string]: boolean } = {}
	for _, id in owned do
		have[id] = true
	end
	local due = {}
	for _, unlock in unlocks do
		if unlock.level <= level and not have[unlock.id] then
			have[unlock.id] = true
			table.insert(due, unlock.id)
		end
	end
	return due
end

return LevelLogic
