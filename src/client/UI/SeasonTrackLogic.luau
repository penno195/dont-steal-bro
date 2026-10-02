--!strict
-- The pure half of the store's Season tab (rewards-roadmap.md step 5b):
-- turns the live season's config and the player's own progress into rows
-- the screen draws. No Roblox API, no requires, so it runs under Lune
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

export type RowStatus = "Claimed" | "Next" | "Locked"

export type Row = {
	wins: number,
	text: string,
	status: RowStatus,
}

export type TrackView = {
	title: string,
	wins: number,
	-- The next unclaimed item's win count, for the progress bar; nil once
	-- the whole track is claimed.
	nextAt: number?,
	locked: boolean, -- premium without the pass
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
	grantText: (Grant) -> string
): TrackView
	local rows: { Row } = {}
	local nextAt: number? = nil
	for index, item in items do
		local status: RowStatus = "Locked"
		if index <= paid then
			status = "Claimed"
		elseif nextAt == nil then
			nextAt = item.wins
			if not locked then
				status = "Next"
			end
		end
		table.insert(rows, { wins = item.wins, text = grantText(item.grant), status = status })
	end
	return { title = title, wins = wins, nextAt = nextAt, locked = locked, rows = rows }
end

function SeasonTrackLogic.view(def: SeasonDef, state: SeasonState, grantText: (Grant) -> string): View
	local locked = not state.passSeen
	return {
		name = def.displayName,
		timeLeft = SeasonTrackLogic.timeLeftText(state.secondsLeft),
		free = track("Free track", def.free, state.freeWins, state.freePaid, false, grantText),
		premium = track(
			if locked then "Premium track · needs the pass" else "Premium track",
			def.premium,
			state.premiumWins,
			state.premiumPaid,
			locked,
			grantText
		),
	}
end

return SeasonTrackLogic
