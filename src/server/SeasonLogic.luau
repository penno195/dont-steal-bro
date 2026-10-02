--!strict
-- Season reward tracks (design-decisions.md Q1's 2026-09-30 revision,
-- applied 2026-10-02; rewards-roadmap.md step 5).
--
-- A season runs between two fixed UTC dates and has two tracks, each a
-- list of items unlocked at win counts:
--   * the FREE track counts every win inside the window, for everyone;
--   * the PREMIUM track counts only wins after the season's pass was
--     first seen owned, and only inside the window.
-- A Roblox pass is owned forever, so the window is ours to enforce: the
-- profile records when ownership was first seen, and a new season needs
-- a new pass.
--
-- Pure: no Roblox API, so tests/SeasonLogic.spec.luau runs it headlessly.
-- Self-contained on purpose - no requires of sibling files - for the
-- same reason RewardLogic and StoreLogic are.

local SeasonLogic = {}

-- ===== types ================================================================

-- Structurally StoreLogic.Grant, so a track item's grant goes straight
-- into StoreLogic.applyGrants: one grant path for purchases, wins and
-- tracks alike.
export type Grant = {
	kind: "Currency" | "PowerUpStock" | "Cosmetic",
	amount: number?,
	powerUpId: string?,
	cosmeticId: string?,
}

export type TrackItem = {
	wins: number, -- unlocked at this many counted wins; 0 = as soon as the track starts counting
	grant: Grant,
}

export type Season = {
	id: string,
	startsAt: number, -- os.time() UTC, inclusive
	endsAt: number, -- os.time() UTC, exclusive
	free: { TrackItem }, -- ascending `wins`, which Validate enforces
	premium: { TrackItem },
}

-- One season's state on one profile. Structurally ProfileLogic's
-- SeasonProgress, which is what the profile stores.
--
-- `*Paid` counts how many items from the front of a track have been
-- granted. Items are paid strictly in list order, so one number is
-- enough to make settling idempotent: a currency item can't be paid
-- twice, however many times a join or a win re-settles.
export type Progress = {
	passSeenAt: number?, -- os.time() the pass was first seen owned inside the window; nil = never
	freeWins: number,
	premiumWins: number,
	freePaid: number,
	premiumPaid: number,
}

export type Paid = {
	track: "Free" | "Premium",
	wins: number,
	grant: Grant,
}

-- ===== dates ================================================================

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil). os.time's table form reads LOCAL time, so it can't
-- be used for a UTC config date on a machine that isn't on UTC.
local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function isLeap(y: number): boolean
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- "YYYY-MM-DD" -> os.time() of that date's 00:00 UTC, or nil when the
-- string isn't a real calendar date.
function SeasonLogic.parseUtcDate(text: any): number?
	if type(text) ~= "string" then
		return nil
	end
	local ys, ms, ds = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if ys == nil then
		return nil
	end
	local y, m, d = tonumber(ys) :: number, tonumber(ms) :: number, tonumber(ds) :: number
	if m < 1 or m > 12 or d < 1 then
		return nil
	end
	local maxDay = if m == 2 and isLeap(y) then 29 else DAYS_IN_MONTH[m]
	if d > maxDay then
		return nil
	end
	return daysFromCivil(y, m, d) * 86400
end

-- A Config/Seasons def as the services see it: nil when it's switched
-- off or its dates don't parse (Validate refuses the latter at boot, so
-- that is belt and braces). Typed loosely so this module needn't
-- require Validate.
function SeasonLogic.fromDef(def: { [string]: any }): Season?
	if def.enabled ~= true then
		return nil
	end
	local startsAt = SeasonLogic.parseUtcDate(def.startsOn)
	local endsAt = SeasonLogic.parseUtcDate(def.endsOn)
	if startsAt == nil or endsAt == nil or endsAt <= startsAt then
		return nil
	end
	return {
		id = def.id,
		startsAt = startsAt,
		endsAt = endsAt,
		free = def.free,
		premium = def.premium,
	}
end

function SeasonLogic.isLive(season: Season, now: number): boolean
	return now >= season.startsAt and now < season.endsAt
end

-- ===== progress =============================================================

function SeasonLogic.newProgress(): Progress
	return { passSeenAt = nil, freeWins = 0, premiumWins = 0, freePaid = 0, premiumPaid = 0 }
end

local function copy(progress: Progress): Progress
	return {
		passSeenAt = progress.passSeenAt,
		freeWins = progress.freeWins,
		premiumWins = progress.premiumWins,
		freePaid = progress.freePaid,
		premiumPaid = progress.premiumPaid,
	}
end

-- Pays every item from `paid + 1` onward whose win count has been
-- reached, stopping at the first that hasn't. Returns the new paid count.
local function settleTrack(
	track: { TrackItem },
	wins: number,
	paid: number,
	trackName: "Free" | "Premium",
	out: { Paid }
): number
	local index = paid + 1
	while index <= #track and track[index].wins <= wins do
		local item = track[index]
		table.insert(out, { track = trackName, wins = item.wins, grant = item.grant })
		index += 1
	end
	return index - 1
end

local function settle(progress: Progress, season: Season, out: { Paid })
	progress.freePaid = settleTrack(season.free, progress.freeWins, progress.freePaid, "Free", out)
	if progress.passSeenAt ~= nil then
		progress.premiumPaid = settleTrack(season.premium, progress.premiumWins, progress.premiumPaid, "Premium", out)
	end
end

-- On join and on a pass purchase. Starts tracking a live season, records
-- the first sighting of its pass, and pays anything now due - a track's
-- 0-win item, or an item a config edit moved below the player's count.
--
-- Returns nil when there is nothing to store: a season that hasn't
-- started, or one that ended before this player ever took part. An ended
-- season the player did take part in still settles, so nothing they
-- reached in the window is lost, but no new pass sighting is recorded.
function SeasonLogic.sync(progress: Progress?, season: Season, now: number, ownsPass: boolean): (Progress?, { Paid })
	local paid: { Paid } = {}
	if now < season.startsAt then
		return progress, paid
	end
	local live = now < season.endsAt
	if progress == nil and not live then
		return nil, paid
	end

	local after = if progress ~= nil then copy(progress) else SeasonLogic.newProgress()
	if live and ownsPass and after.passSeenAt == nil then
		after.passSeenAt = now
	end
	settle(after, season, paid)
	return after, paid
end

-- On a win. Counts it on the free track, and on the premium track if the
-- pass was seen first, then pays anything now due. A win outside the
-- window changes nothing.
function SeasonLogic.recordWin(progress: Progress?, season: Season, now: number): (Progress?, { Paid })
	local paid: { Paid } = {}
	if not SeasonLogic.isLive(season, now) then
		return progress, paid
	end

	local after = if progress ~= nil then copy(progress) else SeasonLogic.newProgress()
	after.freeWins += 1
	local seenAt = after.passSeenAt
	if seenAt ~= nil and seenAt <= now then
		after.premiumWins += 1
	end
	settle(after, season, paid)
	return after, paid
end

-- "Season season-1 Free @3 wins: Currency 100" - one audit line per item.
function SeasonLogic.describePaid(seasonId: string, item: Paid): string
	local grant = item.grant
	local what = if grant.kind == "Currency"
		then string.format("Currency %d", grant.amount or 0)
		elseif grant.kind == "PowerUpStock" then string.format(
			"PowerUpStock %s x%d",
			tostring(grant.powerUpId),
			grant.amount or 0
		)
		else string.format("Cosmetic %s", tostring(grant.cosmeticId))
	return string.format("Season %s %s @%d wins: %s", seasonId, item.track, item.wins, what)
end

return SeasonLogic
