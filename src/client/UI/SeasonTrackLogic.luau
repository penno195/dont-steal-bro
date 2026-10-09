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
}

-- Rewards wait to be claimed (user decision 2026-10-09): "Claimable" is
-- reached and unlocked but not yet claimed, "Next" the first item the
-- player's wins haven't reached yet.
export type RowStatus = "Claimed" | "Claimable" | "Next" | "Locked"

export type Row = {
	-- The item's list position on its track: what a Claim names
	-- (SeasonClaimIntent's `upTo`).
	index: number,
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
}

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
	Currency = "coin",
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
