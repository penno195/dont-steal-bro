--!strict
-- Period-scoped keys and rollover detection for the daily and weekly
-- boards (P4-4). Which day a timestamp belongs to, which ISO week, when
-- those periods start and end, how long their data should outlive them,
-- and the two key shapes that make a rollover safe to process from more
-- than one server.
--
-- All of it is pure arithmetic over a Unix timestamp, so the awkward
-- cases can be checked directly rather than by waiting for a Tuesday.
-- LeaderboardService is the wrapper that supplies a real clock and the
-- real MemoryStore.
--
-- ===== THE TIMEZONE POLICY, AND WHY ====================================
--
-- A "day" is a UTC day. A "week" is an ISO-8601 week, which also starts
-- at UTC midnight, on a Monday.
--
-- The alternative - a local-time day - is the intuitive choice and the
-- wrong one for this game, for three reasons:
--
--   1. There is no single local time. Players are global and the board
--      is shared, so "today" would have to mean one timezone anyway;
--      picking the developer's own is arbitrary and invisible to
--      everyone else.
--   2. A server does not reliably know a player's timezone, and asking
--      the client makes the period boundary a client-supplied value -
--      i.e. something a compromised client could shift to get two
--      shots at a daily reward (Ground Rule 1).
--   3. MemoryStore entries expire on a TTL measured from now, not at a
--      wall-clock instant. A period whose end is a different real
--      instant per player has no single TTL that is correct.
--
-- The cost is real and worth naming: for a player in UTC+13, the daily
-- board resets at 1pm their time, in the middle of an afternoon session.
-- That is a presentation problem, and the honest fix is a UI that says
-- when the reset happens rather than a data model that pretends the
-- boundary is local.

local PeriodKeys = {}

-- Documentation for callers; the functions below take a plain `string`
-- rather than this union, because Luau widens a string-literal array
-- back to `string` on iteration and a narrowing cast at every call site
-- is noise that hides the real types. Each function branches on the
-- value, so an unrecognised kind behaves as Weekly rather than erroring
-- - and there are exactly two callers, both in LeaderboardService.
export type PeriodKind = "Daily" | "Weekly"

local SECONDS_PER_DAY = 86400

-- ===== calendar helpers ================================================

-- Day number since the Unix epoch, floored - so a timestamp anywhere
-- inside a UTC day maps to the same integer.
local function epochDay(timestamp: number): number
	return math.floor(timestamp / SECONDS_PER_DAY)
end

-- ISO weekday, Monday = 1 through Sunday = 7.
--
-- Derived rather than read from a calendar library: 1970-01-01 was a
-- Thursday, so epoch day 0 is weekday 4, and everything follows from
-- that one fact. `+ 3` shifts the epoch's Thursday onto the 4th slot,
-- the modulo wraps, and `+ 1` moves off zero-indexing.
function PeriodKeys.isoWeekday(timestamp: number): number
	return ((epochDay(timestamp) + 3) % 7) + 1
end

-- UTC midnight at the start of the day containing `timestamp`.
function PeriodKeys.dayStart(timestamp: number): number
	return epochDay(timestamp) * SECONDS_PER_DAY
end

-- UTC midnight at the start of the ISO week (Monday) containing
-- `timestamp`.
function PeriodKeys.weekStart(timestamp: number): number
	local weekday = PeriodKeys.isoWeekday(timestamp)
	return PeriodKeys.dayStart(timestamp) - (weekday - 1) * SECONDS_PER_DAY
end

-- ===== keys ============================================================

-- "2026-09-22" - the UTC date.
--
-- os.date with the "!" prefix is UTC rather than local, and that prefix
-- is the entire correctness of this function: without it the key would
-- follow whatever timezone the server happens to be in, which for a
-- Roblox game is a machine detail nobody controls and which can differ
-- between servers in the same universe. Two servers disagreeing about
-- today's key would split one day's board into two.
function PeriodKeys.dayKey(timestamp: number): string
	return os.date("!%Y-%m-%d", math.floor(timestamp)) :: string
end

-- "2026-W39" - ISO-8601 year and week number.
--
-- The ISO year is NOT always the calendar year, which is the trap this
-- function exists to avoid. ISO week 1 is the week containing the first
-- Thursday of January, so the last days of December can belong to week
-- 1 of the NEXT year, and the first days of January can belong to week
-- 52 or 53 of the PREVIOUS one. Keying on the calendar year would put
-- those days in a week that never existed.
--
-- The standard trick: find the Thursday of this week, and take its
-- calendar year and its ordinal day. Thursday is the tiebreak day by
-- definition, so whichever year it falls in is the ISO year, and the
-- week number follows from how many whole weeks precede it.
function PeriodKeys.isoWeekKey(timestamp: number): string
	local weekday = PeriodKeys.isoWeekday(timestamp)
	local thursday = PeriodKeys.dayStart(timestamp) + (4 - weekday) * SECONDS_PER_DAY

	local isoYear = tonumber(os.date("!%Y", thursday)) :: number
	local ordinalDay = tonumber(os.date("!%j", thursday)) :: number
	local week = math.floor((ordinalDay - 1) / 7) + 1

	return string.format("%d-W%02d", isoYear, week)
end

function PeriodKeys.keyFor(kind: string, timestamp: number): string
	return if kind == "Daily" then PeriodKeys.dayKey(timestamp) else PeriodKeys.isoWeekKey(timestamp)
end

-- The MemoryStore SortedMap holding one period's live standings. The
-- period key is IN the map name, which is what makes rollover free:
-- at midnight every server simply starts addressing a different map,
-- and the old one ages out on its own TTL. No cleanup job, which is
-- P4-4's stated reason for MemoryStore over OrderedDataStore.
function PeriodKeys.liveMapName(kind: string, periodKey: string): string
	return string.format("streak_%s_%s", string.lower(kind), periodKey)
end

-- The regular-DataStore key for a FINISHED period's frozen standings.
-- A different store entirely from the live map, because this one must
-- outlive every TTL - yesterday's winners are still worth showing and
-- still owe a reward.
function PeriodKeys.snapshotKey(kind: string, periodKey: string): string
	return string.format("snapshot_%s_%s", string.lower(kind), periodKey)
end

-- The single key two servers race for when a period ends. Whoever wins
-- it processes the rollover; everyone else sees it taken and does
-- nothing. See LeaderboardService's rollover section for the mechanism.
function PeriodKeys.rolloverLockKey(kind: string, periodKey: string): string
	return string.format("rollover_%s_%s", string.lower(kind), periodKey)
end

-- ===== bounds and expiry ===============================================

export type PeriodBounds = {
	startsAt: number,
	endsAt: number, -- exclusive: the first instant of the NEXT period
}

function PeriodKeys.boundsFor(kind: string, timestamp: number): PeriodBounds
	if kind == "Daily" then
		local startsAt = PeriodKeys.dayStart(timestamp)
		return { startsAt = startsAt, endsAt = startsAt + SECONDS_PER_DAY }
	end
	local startsAt = PeriodKeys.weekStart(timestamp)
	return { startsAt = startsAt, endsAt = startsAt + 7 * SECONDS_PER_DAY }
end

-- How long a live entry should be kept alive for, in seconds from
-- `now`. P4-4: "expiry set so a period's data outlives the period
-- itself by a small margin for display purposes, without unbounded
-- growth."
--
-- Measured from NOW rather than from the period start, because a
-- MemoryStore TTL counts from the moment of the write - an entry
-- written at 23:58 and one written at 00:02 need different TTLs to
-- expire at the same wall-clock instant, and using a fixed "one day"
-- for both would keep the late one alive almost a full day into the
-- next period.
--
-- The grace margin is what lets the finished board still be readable
-- while the rollover snapshot is being taken and displayed. It is
-- deliberately small: the snapshot is the durable copy, so the live map
-- has no reason to linger beyond it.
function PeriodKeys.liveExpirySeconds(kind: string, now: number, graceSeconds: number): number
	local bounds = PeriodKeys.boundsFor(kind, now)
	local remaining = bounds.endsAt - now
	-- At least the grace period even for a write landing exactly on the
	-- boundary, so an entry is never written with a zero or negative TTL.
	return math.max(remaining, 0) + graceSeconds
end

-- ===== rollover ========================================================

-- Whether the period changed between two observations. Compares KEYS
-- rather than timestamps, so it is correct across a day boundary, a
-- week boundary, a server that was asleep for three days, and a clock
-- that jumped - in every case the question is the same: is the period I
-- am in now a different one from the period I last saw?
--
-- `previousKey` is nil on a server's first ever check, which is
-- deliberately NOT a rollover: a server booting at 3am has not just
-- witnessed midnight, and treating it as though it had would have every
-- new server trying to re-process a period that ended hours ago.
function PeriodKeys.hasRolledOver(previousKey: string?, currentKey: string): boolean
	if previousKey == nil then
		return false
	end
	return previousKey ~= currentKey
end

return PeriodKeys
