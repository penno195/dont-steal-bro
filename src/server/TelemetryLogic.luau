--!strict
-- The pure half of analytics (next-stages step 6): what each event is
-- called, which AnalyticsService call carries it, its numeric value and
-- its three custom fields. Services/Telemetry.luau does the Roblox calls
-- (finding the Player, rate limits, the queue); everything it has to
-- DECIDE lives here so it can be tested headlessly
-- (tests/TelemetryLogic.spec.luau). docs/telemetry-schema.md is the
-- human-readable version of the mapping below; keep the two in step.
--
-- Self-contained on purpose, like TeleportLogic: no requires, so Lune
-- can load it.
--
-- ===== THE PLATFORM'S LIMITS ==============================================
--
-- These come from the current Roblox analytics docs (custom events,
-- custom fields, funnel events) and the pinned globalTypes.d.luau:
--
--  * Every call needs a Player. Round-level facts are logged against one
--    human in the server (the "anchor"); NPC-only facts can't be logged.
--  * At most 3 custom fields, string values only, and at most 8,000
--    unique COMBINATIONS of the three per event. So no field ever holds a
--    round id, a user id or a raw number that grows without bound; those
--    go in `value` (custom events) or `funnelSessionId` (funnels).
--  * At most 100 custom event names per game. Breakdowns go in fields,
--    never in the event name.
--  * A funnel counts only the first time a user hits a step in a
--    session, and keeps the 10 most recent sessions per user.
--  * Events are only accepted from a published game's server. Studio
--    calls go nowhere, which is why the service can echo them instead.
--
-- Field values carry their dimension name ("Map: School"), which the
-- docs recommend so a chart's legend reads on its own.

local TelemetryLogic = {}

export type Kind = "Funnel" | "Custom"

-- One AnalyticsService call, described as data. `fields` is in slot
-- order: fields[1] goes to CustomField01, and so on. A nil slot is left
-- out of the call rather than sent empty.
export type Record = {
	kind: Kind,
	name: string, -- the funnel name, or the custom event name
	value: number?, -- custom events only
	sessionId: string?, -- funnels only
	step: number?, -- funnels only
	stepName: string?, -- funnels only
	fields: { string? },
}

-- ===== funnels =============================================================

-- Hub side: pressing Play to leaving for a match. One session per queue
-- attempt (the service mints the id), so a player who queues, cancels and
-- queues again is two sessions.
TelemetryLogic.MATCHMAKING_FUNNEL = "Matchmaking"
TelemetryLogic.MatchmakingStep = {
	Queued = 1,
	Matched = 2,
}

-- Match side: one session per round, keyed by RoundService's roundId.
-- The race's per-task pacing is the TaskCompleted custom event, not a
-- step: a funnel only counts a step once per session.
TelemetryLogic.ROUND_FUNNEL = "Round"
TelemetryLogic.RoundStep = {
	Started = 1,
	Finished = 2, -- all assigned tasks done (was AllTasksCompleted)
	Qualified = 3,
	FinaleEntered = 4,
	ChoiceLocked = 5,
	ResultReceived = 6,
}

local function namesByStep(steps: { [string]: number }): { [number]: string }
	local names: { [number]: string } = {}
	for stepName, step in steps do
		names[step] = stepName
	end
	return names
end

local ROUND_STEP_NAMES = namesByStep(TelemetryLogic.RoundStep :: any)
local MATCHMAKING_STEP_NAMES = namesByStep(TelemetryLogic.MatchmakingStep :: any)

-- ===== field values ========================================================

local MAX_VALUE_LENGTH = 40

-- One custom field value. Ids from config are trusted, but anything a
-- client could have influenced is cleaned and capped here as well, so a
-- bad value can only ever be one ugly row, never thousands.
function TelemetryLogic.field(dimension: string, value: any): string
	local text = tostring(value)
	text = string.gsub(text, "[^%w_%-%.%+ ]", "")
	if #text > MAX_VALUE_LENGTH then
		text = string.sub(text, 1, MAX_VALUE_LENGTH)
	end
	if text == "" then
		text = "none"
	end
	return dimension .. ": " .. text
end

-- Streaks grow without bound, so a field gets a band and the exact
-- number goes in `value`. The bands follow where the design expects
-- behaviour to change: a first win, a short run, and "has something to
-- lose".
local STREAK_BANDS: { { lo: number, label: string } } = {
	{ lo = 20, label = "20+" },
	{ lo = 10, label = "10-19" },
	{ lo = 5, label = "5-9" },
	{ lo = 3, label = "3-4" },
	{ lo = 1, label = "1-2" },
	{ lo = 0, label = "0" },
}

function TelemetryLogic.streakBand(streak: number): string
	for _, band in STREAK_BANDS do
		if streak >= band.lo then
			return band.label
		end
	end
	return "0"
end

-- Return reasons arrive in TeleportData, which the client controls, so
-- only the reasons the match server actually sends are kept.
local RETURN_REASONS: { [string]: true } = {
	Late = true,
	Stray = true,
	RoundOver = true,
}

function TelemetryLogic.returnReason(raw: any): string
	if type(raw) == "string" and RETURN_REASONS[raw] then
		return raw
	end
	return "Unknown"
end

-- ===== round context =======================================================

-- What the match server knows about the round once it starts. Every
-- Round funnel step carries the same three fields, because a funnel can
-- only be split by a field every step has.
export type RoundContext = {
	roundId: string,
	mapId: string,
	humans: number,
	configVersion: string?, -- next-stages step 8; nil until then
}

local function roundFields(context: RoundContext): { string? }
	return {
		TelemetryLogic.field("Map", context.mapId),
		TelemetryLogic.field("Humans", context.humans),
		if context.configVersion ~= nil then TelemetryLogic.field("Config", context.configVersion) else nil,
	}
end

function TelemetryLogic.roundStep(context: RoundContext, step: number): Record
	return {
		kind = "Funnel",
		name = TelemetryLogic.ROUND_FUNNEL,
		sessionId = context.roundId,
		step = step,
		stepName = ROUND_STEP_NAMES[step],
		fields = roundFields(context),
	}
end

function TelemetryLogic.matchmakingStep(sessionId: string, step: number): Record
	return {
		kind = "Funnel",
		name = TelemetryLogic.MATCHMAKING_FUNNEL,
		sessionId = sessionId,
		step = step,
		stepName = MATCHMAKING_STEP_NAMES[step],
		fields = {},
	}
end

-- ===== custom events =======================================================

local function custom(name: string, value: number?, fields: { string? }): Record
	return { kind = "Custom", name = name, value = value, fields = fields }
end

-- Value: seconds the task took. Split by task, map and where it fell in
-- the player's list (task 1 includes the walk from spawn).
function TelemetryLogic.taskCompleted(taskId: string, seconds: number, taskNumber: number, mapId: string): Record
	return custom("TaskCompleted", math.floor(seconds), {
		TelemetryLogic.field("Task", taskId),
		TelemetryLogic.field("Map", mapId),
		TelemetryLogic.field("Order", taskNumber),
	})
end

function TelemetryLogic.mapVoted(mapId: string): Record
	return custom("MapVoted", nil, {
		TelemetryLogic.field("Map", mapId),
	})
end

-- Round-level: logged once, against the anchor. Value: humans present.
function TelemetryLogic.mapPlayed(mapId: string, humans: number): Record
	return custom("MapPlayed", humans, {
		TelemetryLogic.field("Map", mapId),
		TelemetryLogic.field("Humans", humans),
	})
end

-- No target id: unbounded, and the question is "does it land", not
-- "on whom".
function TelemetryLogic.powerUpUsed(powerUpId: string, succeeded: boolean, mapId: string): Record
	return custom("PowerUpUsed", nil, {
		TelemetryLogic.field("PowerUp", powerUpId),
		TelemetryLogic.field("Result", if succeeded then "Landed" else "Refused"),
		TelemetryLogic.field("Map", mapId),
	})
end

-- Value: the exact streak, so averages work; the band is for splitting.
-- The reward rung is next-stages step 8's addition (launch-review.md §3
-- checks the finale per rung).
function TelemetryLogic.stealShareChoice(choice: string, streak: number, rung: number?): Record
	return custom("StealShareChoice", streak, {
		TelemetryLogic.field("Choice", choice),
		TelemetryLogic.field("Streak", TelemetryLogic.streakBand(streak)),
		if rung ~= nil then TelemetryLogic.field("Rung", rung) else nil,
	})
end

-- Round-level: logged once, against the anchor.
function TelemetryLogic.finaleOutcome(branch: string, winners: number, bots: number): Record
	return custom("FinaleOutcome", nil, {
		TelemetryLogic.field("Branch", branch),
		TelemetryLogic.field("Winners", winners),
		TelemetryLogic.field("Bots", bots),
	})
end

-- Value: the streak that was lost.
function TelemetryLogic.streakLoss(streak: number, reason: string, mapId: string): Record
	return custom("StreakLoss", streak, {
		TelemetryLogic.field("Reason", reason),
		TelemetryLogic.field("Streak", TelemetryLogic.streakBand(streak)),
		TelemetryLogic.field("Map", mapId),
	})
end

-- Round-level: logged once, against the anchor, after the NPC fill.
-- Value: bot seats. Since the NPC-seat streak threshold was retired
-- (threat-model.md §8), this is the only check on bot-lobby farming.
function TelemetryLogic.npcCountInRound(bots: number, humans: number, mapId: string): Record
	return custom("NPCCountInRound", bots, {
		TelemetryLogic.field("Bots", bots),
		TelemetryLogic.field("Humans", humans),
		TelemetryLogic.field("Map", mapId),
	})
end

-- Value: the Robux price, when the caller knows it.
function TelemetryLogic.purchaseCompleted(productId: string, productType: string, robux: number?): Record
	return custom("PurchaseCompleted", robux, {
		TelemetryLogic.field("Product", productId),
		TelemetryLogic.field("Type", productType),
	})
end

function TelemetryLogic.returnedToHub(rawReason: any): Record
	return custom("ReturnedToHub", nil, {
		TelemetryLogic.field("Reason", TelemetryLogic.returnReason(rawReason)),
	})
end

return TelemetryLogic
