--!strict
-- A free season pass for playtime (payoff-loop step 5; design-decisions
-- .md Q1's "a payoff for every round" case).
--
-- GameConfig.playtimePass.activeHoursPerWeek active hours inside one
-- week unlock the live season's premium track for the rest of that
-- season. The grant itself is SeasonLogic.buyPass with source
-- "Playtime", so it's the very pass a purchase unlocks, once per season
-- however it was got.
--
-- What counts (owner, 2026-10-17 and 2026-10-18):
--   * A ranked match: always.
--   * The Hub and a practice match: only with player input in the last
--     idleWindowSeconds, so standing AFK earns nothing.
--   * Only inside one Mon-Sun UTC week AND one season. A week that
--     straddles a season change restarts the count on the 1st, so hours
--     from the old season never earn the new one's pass.
--
-- The count is one small profile record, reset lazily: a credit (or a
-- read) in a different week or season starts from 0, so nothing has to
-- run at midnight on a Monday.
--
-- Pure: no Roblox API, so tests/PlaytimeLogic.spec.luau runs it
-- headlessly. Self-contained on purpose, like SeasonLogic: the week
-- start is the same arithmetic as PeriodKeys.weekStart (ISO weeks start
-- at UTC midnight on a Monday), repeated rather than required.

local PlaytimeLogic = {}

local SECONDS_PER_DAY = 86400
local SECONDS_PER_HOUR = 3600

-- ===== types ================================================================

-- Structurally Validate.PlaytimePassConfig (GameConfig.playtimePass).
export type Config = {
	activeHoursPerWeek: number,
	idleWindowSeconds: number,
	maxCreditSeconds: number,
}

-- Where the player is spending the time. The server decides this
-- (which place it is, and whether the match is practice), never the
-- client.
export type Context = "Match" | "Practice" | "Hub"

-- What the profile stores: the active seconds counted so far in one
-- week of one season.
export type State = {
	seasonId: string,
	weekStart: number, -- os.time() UTC of that week's Monday 00:00
	activeSeconds: number,
}

-- Only the two season fields the count needs (SeasonLogic.Season has
-- them). The caller passes nil when no season is live.
export type SeasonRef = {
	id: string,
	startsAt: number,
}

export type Progress = {
	activeSeconds: number,
	targetSeconds: number,
	weekEndsAt: number, -- when this week's count resets (the next Monday 00:00 UTC)
}

-- ===== weeks ================================================================

-- UTC midnight on the Monday of the week containing `now`. 1970-01-01
-- was a Thursday, hence the + 3 (see PeriodKeys.isoWeekday).
function PlaytimeLogic.weekStart(now: number): number
	local day = math.floor(now / SECONDS_PER_DAY)
	local weekday = (day + 3) % 7 -- Monday = 0
	return (day - weekday) * SECONDS_PER_DAY
end

function PlaytimeLogic.targetSeconds(config: Config): number
	return config.activeHoursPerWeek * SECONDS_PER_HOUR
end

-- ===== counting =============================================================

-- Whether the last stretch of time counts. `lastInputAt` is the server's
-- os.time() stamp of the player's latest input (nil = none seen). A
-- compromised client can fake input, but all that buys is the free pass
-- it could earn by tapping a screen anyway.
function PlaytimeLogic.isActive(config: Config, context: Context, now: number, lastInputAt: number?): boolean
	if context == "Match" then
		return true
	end
	return lastInputAt ~= nil and now - lastInputAt <= config.idleWindowSeconds
end

-- The count `state` stands for at `now` in `season`: itself while it's
-- the same week and season, else a fresh 0.
local function current(state: State?, season: SeasonRef, now: number): State
	local week = PlaytimeLogic.weekStart(now)
	if state ~= nil and state.seasonId == season.id and state.weekStart == week then
		return { seasonId = state.seasonId, weekStart = state.weekStart, activeSeconds = state.activeSeconds }
	end
	return { seasonId = season.id, weekStart = week, activeSeconds = 0 }
end

-- Adds `seconds` of active time ending at `now`. Returns the new state
-- and whether the pass is now due, which the caller grants through
-- SeasonLogic.buyPass(..., "Playtime").
--
-- Nothing counts with no live season, or once the pass is held (bought
-- or earned): the state comes back unchanged. One credit is capped at
-- maxCreditSeconds, and at the time since this week (or season) began,
-- so a stalled tick or a credit across Monday midnight can't bank time
-- that belongs to no counted period. `due` stays true on every credit
-- past the target until the pass is held, so a grant that failed (a
-- save that didn't happen) is retried by the next tick.
function PlaytimeLogic.credit(
	config: Config,
	state: State?,
	season: SeasonRef?,
	hasPass: boolean,
	now: number,
	seconds: number
): (State?, boolean)
	if season == nil or hasPass or now < season.startsAt then
		return state, false
	end
	local after = current(state, season, now)
	local periodStart = math.max(after.weekStart, season.startsAt)
	local amount = seconds
	if amount ~= amount or amount < 0 then -- NaN or negative
		amount = 0
	end
	amount = math.min(amount, config.maxCreditSeconds, now - periodStart)
	after.activeSeconds += amount
	return after, after.activeSeconds >= PlaytimeLogic.targetSeconds(config)
end

-- What the pass screen shows: this week's count toward the target. A
-- stale state (an earlier week or season) reads as 0.
function PlaytimeLogic.progress(config: Config, state: State?, season: SeasonRef, now: number): Progress
	local counted = current(state, season, now)
	return {
		activeSeconds = math.min(counted.activeSeconds, PlaytimeLogic.targetSeconds(config)),
		targetSeconds = PlaytimeLogic.targetSeconds(config),
		weekEndsAt = counted.weekStart + 7 * SECONDS_PER_DAY,
	}
end

return PlaytimeLogic
