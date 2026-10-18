--!strict
-- The level-up pop-up's XP bar (owner, 2026-10-18: show a new player
-- the XP system), worked out headlessly. No Roblox API: tested under
-- Lune. Screens/LevelUpPopup plays what this says.
--
-- The bar fills in segments, one per level it passes through: the old
-- level's bar from where it stood to full, a full sweep for each whole
-- level between (a few at most, so a big jump doesn't drag), then the
-- new level's bar from empty to where it ends. Each full bar is a
-- level-up beat: the number pops, the sound plays, the bar empties.

local LevelUpLogic = {}

-- Structurally ResultsLogic.LevelProgress (LevelLogic.Progress).
export type Progress = {
	level: number,
	xpIntoLevel: number,
	xpForNext: number, -- 0 at the max level
}

export type Segment = {
	level: number, -- the level the counter shows while this one fills
	from: number, -- bar fraction, 0-1
	to: number,
	levelsUp: boolean, -- ends full: a level-up beat follows
	seconds: number, -- fill time; 0 = nothing to fill
}

LevelUpLogic.FULL_BAR_SECONDS = 1.2 -- an empty bar to full
LevelUpLogic.MIN_SECONDS = 0.3 -- any fill at all takes at least this
LevelUpLogic.MAX_SWEEPS = 3 -- full bars shown, the old level's included
LevelUpLogic.LEVEL_BEAT_SECONDS = 0.6 -- the pause on each level-up
LevelUpLogic.TICK_SECONDS = 0.08 -- a fill tick sound every this long

-- How full `progress`'s bar is. Full at the max level.
function LevelUpLogic.fraction(progress: Progress): number
	if progress.xpForNext <= 0 then
		return 1
	end
	return math.clamp(progress.xpIntoLevel / progress.xpForNext, 0, 1)
end

local function segment(level: number, from: number, to: number, levelsUp: boolean): Segment
	local span = to - from
	return {
		level = level,
		from = from,
		to = to,
		levelsUp = levelsUp,
		seconds = if span <= 0 then 0 else math.max(LevelUpLogic.MIN_SECONDS, LevelUpLogic.FULL_BAR_SECONDS * span),
	}
end

function LevelUpLogic.segments(before: Progress, after: Progress): { Segment }
	local startAt = LevelUpLogic.fraction(before)
	if after.level <= before.level then
		return { segment(before.level, startAt, math.max(startAt, LevelUpLogic.fraction(after)), false) }
	end
	local out = { segment(before.level, startAt, 1, true) }
	-- Whole levels passed through. Past MAX_SWEEPS the middle ones are
	-- skipped; the last one shown is always the level just below
	-- `after`, so the counter still lands on it in order.
	local middle = after.level - before.level - 1
	local shown = math.min(middle, LevelUpLogic.MAX_SWEEPS - 1)
	for index = 1, shown do
		local level = if index == shown then after.level - 1 else before.level + index
		table.insert(out, segment(level, 0, 1, true))
	end
	table.insert(out, segment(after.level, 0, LevelUpLogic.fraction(after), false))
	return out
end

-- The whole animation's length, level-up beats included: how long the
-- pop-up holds its reward cards back.
function LevelUpLogic.totalSeconds(segments: { Segment }): number
	local total = 0
	for _, part in segments do
		total += part.seconds
		if part.levelsUp then
			total += LevelUpLogic.LEVEL_BEAT_SECONDS
		end
	end
	return total
end

-- The XP counter during the fill: `xpGained` shared across the fill
-- time, so it reaches the total exactly as the bar stops. `elapsed` is
-- fill time only (level-up beats left out).
function LevelUpLogic.xpShown(xpGained: number, elapsed: number, fillSeconds: number): number
	if fillSeconds <= 0 then
		return xpGained
	end
	return math.floor(xpGained * math.clamp(elapsed / fillSeconds, 0, 1) + 0.5)
end

-- Seconds of fill (no beats): what xpShown shares the XP over.
function LevelUpLogic.fillSeconds(segments: { Segment }): number
	local total = 0
	for _, part in segments do
		total += part.seconds
	end
	return total
end

return LevelUpLogic
