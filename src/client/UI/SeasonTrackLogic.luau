--!strict
-- The pure half of the store's Season tab (rewards-roadmap.md step 5b):
-- turns the live season's config and the player's own progress into rows
-- the screen draws, and the rows into tier columns (next-stages.md 1a:
-- tiers left to right, pass row on top, free row below). No Roblox API, no requires, so it runs under Lune
-- (tests/MenuScreens.spec).
--
-- Progress arrives in StoreState, which is targeted at its owner only.
-- Win counts are a private record, never shown to anyone else, so Q7's
-- "no streak visible to others" isn't touched.
--
-- Display only. What was paid is decided server-side (SeasonLogic); a
-- row reading "Claimed" just mirrors the paid counts the server sent.

local SeasonTrackLogic = {}

-- Structural copies of what this module reads from a Config/Seasons def,
-- so a real config value satisfies them without a require.
export type Grant = {
	kind: string,
	amount: number?,
	powerUpId: string?,
	cosmeticId: string?,
}

export type TrackItem = { wins: number, grant: Grant }

export type SeasonDef = {
	id: string,
	displayName: string,
	passKey: string,
	free: { TrackItem },
	premium: { TrackItem },
}

-- StoreState.season (StoreService.pushState): the live season, or nil
-- when none is running.
export type SeasonState = {
	id: string,
	secondsLeft: number,
	passSeen: boolean,
	freeWins: number,
	premiumWins: number,
	freePaid: number,
	premiumPaid: number,
	-- Payoff-loop step 5b: "Playtime" when the pass was earned, nil when
	-- bought or not held; and this week's active time toward the free
	-- pass, nil once the pass is held.
	passSource: string?,
	playtime: Playtime?,
}

export type Playtime = { activeSeconds: number, targetSeconds: number, weekResetsIn: number }

-- Rewards wait to be claimed (user decision 2026-10-09): "Claimable" is
-- reached and unlocked but not yet claimed, "Next" the first item the
-- player's wins haven't reached yet.
export type RowStatus = "Claimed" | "Claimable" | "Next" | "Locked"

export type Row = {
	-- The item's list position on its track: what a Claim names
	-- (SeasonClaimIntent's `upTo`).
	index: number,
	grant: Grant, -- what it pays, for the item preview
	wins: number,
	text: string,
	status: RowStatus,
	-- The tile's picture: the item's own art (an asset id) when it has
	-- some, else `icon`, a Components/Icons key.
	icon: string,
	image: number?,
	-- This track's wins have reached the item. A reached pass item is
	-- claimable as soon as the pass is bought.
	reached: boolean,
}

export type TrackView = {
	title: string,
	wins: number,
	-- The first unreached item's win count; nil once every item is
	-- reached.
	nextAt: number?,
	locked: boolean, -- premium without the pass
	claimable: number, -- how many items a Claim All would pay now
	rows: { Row },
}

export type View = {
	name: string,
	timeLeft: string,
	free: TrackView,
	premium: TrackView,
	playtime: PlaytimeView?, -- nil once the pass is held
}

-- The pass screen's "x / 6h active this week" bar (payoff-loop
-- step 5c): how full it is, what it reads, and when the week resets.
-- `short` is the Hub's always-on playtime row under the level pill.
export type PlaytimeView = { fraction: number, text: string, short: string, resets: string }

-- Whole hours as "6", else floored to a tenth ("2.5"), so the bar never
-- reads the target before the server has granted the pass.
function SeasonTrackLogic.hoursText(seconds: number): string
	local tenths = math.max(0, seconds) // 360
	if tenths % 10 == 0 then
		return string.format("%d", tenths // 10)
	end
	return string.format("%d.%d", tenths // 10, tenths % 10)
end

-- The playtime bar's clock: "6m", "1h 6m", "6h". Floored to the minute
-- for the same reason as hoursText.
function SeasonTrackLogic.durationText(seconds: number): string
	local minutes = math.max(0, seconds) // 60
	local h, m = minutes // 60, minutes % 60
	if h == 0 then
		return string.format("%dm", m)
	elseif m == 0 then
		return string.format("%dh", h)
	end
	return string.format("%dh %dm", h, m)
end

function SeasonTrackLogic.weekResetText(seconds: number): string
	local days = seconds // 86400
	if days >= 2 then
		return string.format("resets in %d days", days)
	elseif days == 1 then
		return "resets in 1 day"
	end
	local hours = seconds // 3600
	if hours >= 1 then
		return string.format("resets in %dh", hours)
	end
	return "resets soon"
end

function SeasonTrackLogic.playtimeView(state: SeasonState): PlaytimeView?
	local p = state.playtime
	if p == nil or state.passSeen or p.targetSeconds <= 0 then
		return nil
	end
	local active = math.clamp(p.activeSeconds, 0, p.targetSeconds)
	return {
		fraction = active / p.targetSeconds,
		text = string.format(
			"Free pass: %s / %s active this week",
			SeasonTrackLogic.durationText(active),
			SeasonTrackLogic.durationText(p.targetSeconds)
		),
		short = string.format(
			"%s / %s",
			SeasonTrackLogic.durationText(active),
			SeasonTrackLogic.durationText(p.targetSeconds)
		),
		resets = SeasonTrackLogic.weekResetText(p.weekResetsIn),
	}
end

-- The pop-up the Hub's playtime row opens (Hub menu pass): how the free
-- pass is earned. `hours` is GameConfig.playtimePass.activeHoursPerWeek.
function SeasonTrackLogic.playtimeExplainer(hours: number, view: PlaytimeView): string
	return string.format(
		"Play %s active hours in one week to unlock this season's paid pass for free.\n\n"
			.. "Ranked rounds always count. Lobby and practice time counts while you're playing, not while you're away.\n\n"
			.. "This week: %s (%s).",
		SeasonTrackLogic.hoursText(hours * 3600),
		view.short,
		view.resets
	)
end

-- Did the pass just arrive by playtime? passSource flipping to
-- "Playtime" within one season. A first state (a join) never counts, so
-- the pop-up isn't replayed on every visit.
function SeasonTrackLogic.earnedByPlaytime(before: SeasonState?, after: SeasonState?): boolean
	return before ~= nil
		and after ~= nil
		and before.id == after.id
		and before.passSource ~= "Playtime"
		and after.passSource == "Playtime"
end

-- The "Earned by playtime" pop-up's title and body. The target is read
-- from the state before the grant, the last one that carried it.
function SeasonTrackLogic.playtimePassText(def: SeasonDef, before: SeasonState): (string, string)
	local hours = if before.playtime
		then SeasonTrackLogic.hoursText(before.playtime.targetSeconds) .. " active hours"
		else "Your playtime"
	return "EARNED BY PLAYTIME!",
		string.format(
			"%s this week unlocked the %s pass. Its premium track is yours for the rest of the season.",
			hours,
			def.displayName
		)
end

function SeasonTrackLogic.timeLeftText(seconds: number): string
	local days = seconds // 86400
	if days >= 2 then
		return string.format("%d days left", days)
	elseif days == 1 then
		return "1 day left"
	end
	local hours = seconds // 3600
	if hours >= 1 then
		return string.format("%dh left", hours)
	end
	return "Ends soon"
end

local function track(
	title: string,
	items: { TrackItem },
	wins: number,
	paid: number,
	locked: boolean,
	grantText: (Grant) -> string,
	imageFor: (Grant) -> number?
): TrackView
	local rows: { Row } = {}
	local nextAt: number? = nil
	local claimable = 0
	for index, item in items do
		local reached = wins >= item.wins
		local status: RowStatus = "Locked"
		if index <= paid then
			status = "Claimed"
		elseif reached then
			if not locked then
				status = "Claimable"
				claimable += 1
			end
		elseif nextAt == nil then
			nextAt = item.wins
			if not locked then
				status = "Next"
			end
		end
		table.insert(rows, {
			index = index,
			grant = item.grant,
			wins = item.wins,
			text = grantText(item.grant),
			status = status,
			icon = SeasonTrackLogic.iconFor(item.grant),
			image = imageFor(item.grant),
			reached = reached,
		})
	end
	return { title = title, wins = wins, nextAt = nextAt, locked = locked, claimable = claimable, rows = rows }
end

-- `imageFor` names an item's own picture (a cosmetic's preview icon);
-- nil, or nil from it, falls back to the grant's icon.
function SeasonTrackLogic.view(
	def: SeasonDef,
	state: SeasonState,
	grantText: (Grant) -> string,
	imageFor: ((Grant) -> number?)?
): View
	local locked = not state.passSeen
	local image = imageFor or function(_: Grant): number?
		return nil
	end
	return {
		name = def.displayName,
		timeLeft = SeasonTrackLogic.timeLeftText(state.secondsLeft),
		free = track("Free track", def.free, state.freeWins, state.freePaid, false, grantText, image),
		premium = track(
			if locked then "Premium track · needs the pass" else "Premium track",
			def.premium,
			state.premiumWins,
			state.premiumPaid,
			locked,
			grantText,
			image
		),
		playtime = SeasonTrackLogic.playtimeView(state),
	}
end

-- One tier: a win count with each track's item there (nil = that row
-- pays nothing at this count).
export type Column = {
	wins: number,
	premium: Row?,
	free: Row?,
}

-- The two tracks lined up as tiers, fewest wins first. Validate lets a
-- track list two items at the same count, so the nth item at a count on
-- one row shares a column with the nth at that count on the other.
function SeasonTrackLogic.columns(view: View): { Column }
	local byKey: { [string]: Column } = {}
	local keys: { { wins: number, nth: number, key: string } } = {}
	local function place(rows: { Row }, isPremium: boolean)
		local seen: { [number]: number } = {}
		for _, r in rows do
			local nth = (seen[r.wins] or 0) + 1
			seen[r.wins] = nth
			local key = r.wins .. "#" .. nth
			local column = byKey[key]
			if column == nil then
				column = { wins = r.wins }
				byKey[key] = column
				table.insert(keys, { wins = r.wins, nth = nth, key = key })
			end
			if isPremium then
				column.premium = r
			else
				column.free = r
			end
		end
	end
	place(view.premium.rows, true)
	place(view.free.rows, false)
	table.sort(keys, function(a, b)
		return if a.wins ~= b.wins then a.wins < b.wins else a.nth < b.nth
	end)
	local columns: { Column } = {}
	for _, k in keys do
		table.insert(columns, byKey[k.key])
	end
	return columns
end

-- A reward with no picture of its own shows an icon (a Components/Icons
-- key): a power-up its own icon, which Icons keys by power-up id, and
-- anything else one for its grant's kind.
local KIND_ICON: { [string]: string } = {
	Currency = "coin-gold",
	PowerUpStock = "bolt",
	Cosmetic = "gem",
	Title = "trophy",
}

function SeasonTrackLogic.iconFor(grant: Grant): string
	if grant.kind == "PowerUpStock" and grant.powerUpId ~= nil then
		return grant.powerUpId
	end
	return KIND_ICON[grant.kind] or "gem"
end

-- A coin reward's picture grows with the amount: a few coins, then
-- stacks, then a chest (assets/seasonpass/make-pictures.js). Each tier
-- covers amounts up to `upTo`; the last has none and takes the rest.
local COIN_PICTURES: { { upTo: number?, image: number } } = {
	{ upTo = 75, image = 138425276509423 },
	{ upTo = 150, image = 124045296120447 },
	{ image = 113432804756453 },
}

-- A reward's own full-colour picture, for the pass tiles and every claim
-- pop-up: a cosmetic's preview icon, a power-up's picture (both looked
-- up by the caller, from config), coins by amount. nil = show iconFor's
-- tinted icon instead.
function SeasonTrackLogic.pictureFor(
	grant: Grant,
	cosmeticPicture: (string) -> number?,
	powerUpPicture: (string) -> number?
): number?
	local id: number? = nil
	if grant.kind == "Cosmetic" and grant.cosmeticId ~= nil then
		id = cosmeticPicture(grant.cosmeticId)
	elseif grant.kind == "PowerUpStock" and grant.powerUpId ~= nil then
		id = powerUpPicture(grant.powerUpId)
	elseif grant.kind == "Currency" then
		local amount = grant.amount or 0
		for _, tier in COIN_PICTURES do
			if tier.upTo == nil or amount <= tier.upTo then
				return tier.image
			end
		end
	end
	return if type(id) == "number" and id > 0 then id else nil
end

export type Reward = { premium: boolean, grant: Grant }

-- What a claim just paid, for the pop-up: the items whose list position
-- moved past `before`'s paid counts in `after`, premium first. Both
-- states must be the same season - a new month starts its counts over,
-- and only a claim moves them while a season is live (an ended season
-- grants its leftovers on join, when no season state is sent).
function SeasonTrackLogic.claimedBetween(def: SeasonDef, before: SeasonState?, after: SeasonState?): { Reward }
	local rewards: { Reward } = {}
	if before == nil or after == nil or before.id ~= after.id or after.id ~= def.id then
		return rewards
	end
	for index = before.premiumPaid + 1, math.min(after.premiumPaid, #def.premium) do
		table.insert(rewards, { premium = true, grant = def.premium[index].grant })
	end
	for index = before.freePaid + 1, math.min(after.freePaid, #def.free) do
		table.insert(rewards, { premium = false, grant = def.free[index].grant })
	end
	return rewards
end

-- The column the strip opens scrolled to: the first tier with something
-- to claim, else the first still holding an item not yet claimed, else
-- the last.
function SeasonTrackLogic.focusColumn(columns: { Column }): number
	for index, column in columns do
		local p, f = column.premium, column.free
		if (p and p.status == "Claimable") or (f and f.status == "Claimable") then
			return index
		end
	end
	for index, column in columns do
		local p, f = column.premium, column.free
		if (p and p.status ~= "Claimed") or (f and f.status ~= "Claimed") then
			return index
		end
	end
	return math.max(#columns, 1)
end

return SeasonTrackLogic
