--!strict
-- The pure half of the leaderboards screen (P6-6): what a board payload
-- means for the screen, where the viewer stands, and which rows to
-- actually build. No Roblox API, no requires; tested under Lune
-- (tests/MenuScreens.spec).
--
-- Every board arrives by broadcast from a server-side cache
-- (LeaderboardState for all-time, PeriodBoardState for daily/weekly -
-- P4-3/P4-4), refreshed every 60-120s. There is no request remote, so
-- "loading" can only mean "no broadcast received yet", and the screen
-- can't make it faster by asking.

local BoardLogic = {}

export type Tab = "Daily" | "Weekly" | "AllTime"
BoardLogic.TABS = table.freeze({ "Daily", "Weekly", "AllTime" } :: { Tab })

export type Entry = { rank: number, userId: number, bestStreak: number, displayName: string }

-- LeaderboardState / PeriodBoardState, as received. `status` is
-- LeaderboardLogic.CacheStatus ("Fresh" | "Stale" | "Empty").
export type Payload = {
	entries: { Entry },
	status: string,
	periodKey: string?,
}

export type Phase =
	"Loading" -- nothing received yet this session
	| "Empty" -- received, and genuinely nothing on it
	| "Ready"

export type Viewer = {
	onList: boolean,
	rank: number?, -- nil when off the list
	bestStreak: number?, -- the board's own number for them, when on it
}

export type View = {
	phase: Phase,
	stale: boolean,
	rows: { Entry },
	viewer: Viewer,
}

-- The board caps at GameConfig.leaderboard.topCount (100). The server
-- already sends at most that; capping here too means a misconfigured
-- server can't hand a phone 5,000 rows to lay out.
BoardLogic.MAX_ROWS = 100

function BoardLogic.view(payload: Payload?, viewerId: number): View
	if payload == nil then
		return { phase = "Loading", stale = false, rows = {}, viewer = { onList = false, rank = nil, bestStreak = nil } }
	end

	local rows = {}
	for i, entry in payload.entries do
		if i > BoardLogic.MAX_ROWS then
			break
		end
		table.insert(rows, entry)
	end

	-- The server's "Empty" and a zero-length list both mean empty; trust
	-- either, so a Fresh status with no rows can't render a blank list.
	local phase: Phase = if payload.status == "Empty" or #rows == 0 then "Empty" else "Ready"

	local viewer: Viewer = { onList = false, rank = nil, bestStreak = nil }
	for _, entry in rows do
		if entry.userId == viewerId then
			viewer = { onList = true, rank = entry.rank, bestStreak = entry.bestStreak }
			break
		end
	end

	return { phase = phase, stale = payload.status == "Stale", rows = rows, viewer = viewer }
end

-- The pinned row's text for a viewer who isn't on the list. There is no
-- personal rank to show: the boards are OrderedDataStore / MemoryStore
-- sorted maps read top-down, and neither can say where the 40,000th
-- player sits without reading 40,000 rows. So it says what's true
-- rather than inventing a number.
function BoardLogic.offListLabel(): string
	return string.format("Not in the top %d yet", BoardLogic.MAX_ROWS)
end

-- Empty-state copy per tab. A fresh period is the common case for daily
-- and weekly (every rollover empties them), so it reads as an invitation
-- rather than an error. All-time is only empty on a brand-new game or a
-- cache that has never loaded.
function BoardLogic.emptyText(tab: Tab): (string, string)
	if tab == "Daily" then
		return "A new day, an empty board", "Win a round today to be the first name on it."
	elseif tab == "Weekly" then
		return "A new week, an empty board", "Win a round this week to be the first name on it."
	end
	return "No streaks recorded yet", "The first win puts you at the top."
end

-- ===== the hub's wall boards ===============================================
--
-- The three HubLeaderboardSurface parts (hub-spec.md), one per tab,
-- drawn by HubBoardController from the same broadcasts as the menu
-- screen. A wall can't scroll, so it shows the top WALL_ROWS only: five,
-- because the hub's boards are 9 studs tall and ten rows were too small
-- to read from the path on a phone. The full 100 is in the menu.

BoardLogic.WALL_ROWS = 5

BoardLogic.WALL_TITLES = table.freeze({
	Daily = "TODAY'S TOP STREAKS",
	Weekly = "THIS WEEK'S TOP STREAKS",
	AllTime = "ALL-TIME BEST STREAKS",
} :: { [string]: string })

export type WallRow = { rank: string, name: string, streak: string, isViewer: boolean }

export type Wall = {
	title: string,
	rows: { WallRow },
	-- Shown instead of rows when there are none: Loading or Empty.
	message: string?,
	detail: string?,
	stale: boolean,
}

-- Only a Tab key gets a wall; anything else (a mistyped Period
-- attribute) returns nil, so the controller skips that part.
function BoardLogic.wall(tab: string, payload: Payload?, viewerId: number): Wall?
	local title = BoardLogic.WALL_TITLES[tab]
	if title == nil then
		return nil
	end
	local v = BoardLogic.view(payload, viewerId)
	if v.phase == "Loading" then
		return { title = title, rows = {}, message = "Loading…", detail = nil, stale = false }
	elseif v.phase == "Empty" then
		local headline, body = BoardLogic.emptyText(tab :: Tab)
		return { title = title, rows = {}, message = headline, detail = body, stale = v.stale }
	end
	local rows: { WallRow } = {}
	for i, entry in v.rows do
		if i > BoardLogic.WALL_ROWS then
			break
		end
		table.insert(rows, {
			rank = "#" .. entry.rank,
			name = entry.displayName,
			streak = tostring(entry.bestStreak),
			isViewer = entry.userId == viewerId,
		})
	end
	return { title = title, rows = rows, message = nil, detail = nil, stale = v.stale }
end

-- ===== virtualisation ======================================================
--
-- 100 rows built as 100 Frames each with a PlayerRow's worth of children
-- is well over a thousand instances, which a cheap Android phone pays
-- for in layout on every scroll frame. Building only what's visible
-- (plus a margin) keeps it to a couple of dozen regardless of length.

-- Which rows (1-based, inclusive) to build for a list scrolled
-- `offset` pixels down a `viewport`-tall window, rows `rowHeight` tall
-- with `gap` between them. `overscan` extra rows either side hide the
-- pop-in on a fast fling. Returns (1, 0) - an empty range - for an
-- empty list.
function BoardLogic.visibleRange(
	offset: number,
	viewport: number,
	rowHeight: number,
	gap: number,
	count: number,
	overscan: number
): (number, number)
	if count <= 0 or rowHeight <= 0 then
		return 1, 0
	end
	local pitch = rowHeight + gap
	local first = math.floor(math.max(offset, 0) / pitch) + 1 - overscan
	local last = math.ceil((math.max(offset, 0) + viewport) / pitch) + overscan
	return math.clamp(first, 1, count), math.clamp(last, 1, count)
end

-- Total scrollable height for `count` rows - the canvas size, so the
-- scrollbar is right even though most rows don't exist.
function BoardLogic.contentHeight(count: number, rowHeight: number, gap: number): number
	if count <= 0 then
		return 0
	end
	return count * rowHeight + (count - 1) * gap
end

return BoardLogic
