--!strict
-- Pure half of the Decision Studio screen (P6-5): payload parsing, the
-- payoff table, the hold-to-confirm lock, the reveal timeline and the
-- result copy. No Roblox API and no requires, so
-- tests/DecisionLogic.spec.luau covers it headlessly - including a check
-- that the payoff table agrees with Outcomes.resolve for every
-- combination, so the table the players read can never misstate the
-- rules. Screens/DecisionStudio.luau and
-- Controllers/DecisionStudioController.luau feed it live values.
--
-- SECRECY: nothing here can hold another player's choice before the
-- reveal, because the only function that ever produces one is
-- parseReveal, and the only input to it is the DecisionReveal packet.
-- parseReveal also drops `bountyVU`: a winner's VU figure is a function
-- of their streak tier (design-decisions.md Q1), so a client that never
-- keeps it can never display it. See docs/decision-studio.md "Secrecy
-- audit".

local DecisionLogic = {}

export type Choice = "Steal" | "Share"
export type Phase = "Intro" | "Negotiate" | "Choose" | "Reveal" | "Resolve"
export type Prize = "Big" | "Medium" | "Small" | "Nothing"
export type Tone = "win" | "loss" | "neutral"

export type Reputation = { steals: number, shares: number }

export type Reveal = {
	choices: { [number]: Choice },
	branch: string,
	winnerIds: { number },
	loserIds: { number },
	revealAt: number,
}

export type Personal = { streakBefore: number, streakAfter: number, won: boolean }

-- Which screen to show. "Locked" is Choose after you've committed, and
-- the gap between the last lock and the reveal packet landing.
export type Stage = "Waiting" | "Intro" | "Negotiate" | "Choose" | "Locked" | "Reveal"

-- Seconds after `revealAt`. The same for every client and for reduced
-- motion: the stagger is timing, not motion, and three players reacting
-- out loud need to see the same card at the same moment. Reduced motion
-- changes HOW each step appears (a cut, not a flip), never WHEN.
DecisionLogic.TIMING = table.freeze({
	holdSeconds = 0.8, -- hold-to-confirm; long enough that a brushed thumb can't lock
	ackTimeout = 1.5, -- resend the same choice if no DecisionLockedIn came back
	ackRetries = 2,
	lead = 1.0, -- the beat of silence before the first card
	cardGap = 1.4, -- between cards
	outcomeAfter = 1.2, -- last card -> outcome banner
	resultAfter = 2.2, -- outcome banner -> result panel
})

-- PAYLOADS -----------------------------------------------------------

-- A RemoteEvent turns a map keyed by non-sequential numbers into string
-- keys, so DecisionReveal's `choices` (keyed by userId, and NPC ids are
-- negative) may arrive either way. Anything malformed is dropped: a
-- reveal the client can't read is shown as nothing rather than wrong.
local function toId(key: any): number?
	local n = tonumber(key)
	if n == nil or n ~= math.floor(n) then
		return nil
	end
	return n
end

local function isChoice(value: any): boolean
	return value == "Steal" or value == "Share"
end

function DecisionLogic.parseReveal(payload: any): Reveal?
	if type(payload) ~= "table" or type(payload.choices) ~= "table" or type(payload.outcome) ~= "table" then
		return nil
	end
	if type(payload.revealAt) ~= "number" or type(payload.outcome.branch) ~= "string" then
		return nil
	end
	local choices: { [number]: Choice } = {}
	for key, value in payload.choices do
		local id = toId(key)
		if id ~= nil and isChoice(value) then
			choices[id] = value
		end
	end
	local winnerIds: { number } = {}
	for _, entry in (payload.outcome.winners or {}) :: { any } do
		local id = if type(entry) == "table" then toId(entry.playerId) else nil
		if id ~= nil then
			table.insert(winnerIds, id) -- bountyVU deliberately not copied
		end
	end
	local loserIds: { number } = {}
	for _, raw in (payload.outcome.loserIds or {}) :: { any } do
		local id = toId(raw)
		if id ~= nil then
			table.insert(loserIds, id)
		end
	end
	return table.freeze({
		choices = table.freeze(choices),
		branch = payload.outcome.branch,
		winnerIds = table.freeze(winnerIds),
		loserIds = table.freeze(loserIds),
		revealAt = payload.revealAt,
	})
end

function DecisionLogic.parseReputation(list: any): { [number]: Reputation }
	local out: { [number]: Reputation } = {}
	if type(list) ~= "table" then
		return out
	end
	for _, entry in list :: { any } do
		local id = if type(entry) == "table" then toId(entry.playerId) else nil
		if id ~= nil and type(entry.steals) == "number" and type(entry.shares) == "number" then
			out[id] = table.freeze({ steals = math.max(0, entry.steals), shares = math.max(0, entry.shares) })
		end
	end
	return out
end

function DecisionLogic.parsePersonal(payload: any): Personal?
	if type(payload) ~= "table" then
		return nil
	end
	if type(payload.streakBefore) ~= "number" or type(payload.streakAfter) ~= "number" then
		return nil
	end
	return table.freeze({
		streakBefore = payload.streakBefore,
		streakAfter = payload.streakAfter,
		won = payload.won == true,
	})
end

-- REPUTATION ---------------------------------------------------------

-- design-decisions.md Q5's line. Lifetime counts, not a rolling window
-- (the profile keeps totals). Under ten decisions a percentage is noise
-- that reads like a verdict ("100%" after one steal), so small samples
-- show the raw count instead. 0/0 reads the same for an NPC and for a
-- first-timer on purpose - see DecisionService's DecisionParticipants.
local PERCENT_FROM = 10

function DecisionLogic.reputationLabel(rep: Reputation?): string
	local steals = if rep then rep.steals else 0
	local total = if rep then rep.steals + rep.shares else 0
	if total == 0 then
		return "No history yet"
	elseif total < PERCENT_FROM then
		return string.format("Stole %d of %d", steals, total)
	end
	return string.format("Steals %d%% of %d", math.floor(steals / total * 100 + 0.5), total)
end

-- PAYOFF TABLE -------------------------------------------------------

-- What YOU get, given your choice and how many of the others steal.
-- payoff-table.md §1, read from one seat. Words, never VU: VU is an
-- internal balancing unit a player never sees (payoff-table.md intro).
function DecisionLogic.prizeFor(mine: Choice, othersStealing: number, seats: number): Prize
	if seats <= 1 then
		return "Small" -- Outcomes.resolveOne: a solo finalist always gets the all-share package
	end
	local others = seats - 1
	if mine == "Steal" then
		return if othersStealing == 0 then "Big" else "Nothing"
	end
	if othersStealing == 0 then
		return "Small"
	elseif seats == 3 and othersStealing == others then
		return "Medium" -- the lone sharer between two thieves
	end
	return "Nothing"
end

export type PayoffCell = { when: string, prize: Prize }
export type PayoffRow = { choice: Choice, cells: { PayoffCell } }

local function othersPhrase(stealing: number, others: number): string
	if others == 1 then
		return if stealing == 0 then "They share" else "They steal"
	end
	if stealing == 0 then
		return "Both share"
	elseif stealing == others then
		return "Both steal"
	end
	return "One steals"
end

-- The always-visible table, as rows the screen lays out. One row per
-- choice, one cell per "what the others do".
function DecisionLogic.payoffRows(seats: number): { PayoffRow }
	local rows: { PayoffRow } = {}
	for _, choice: Choice in { "Steal", "Share" } :: { Choice } do
		local cells: { PayoffCell } = {}
		if seats <= 1 then
			table.insert(cells, { when = "Alone", prize = DecisionLogic.prizeFor(choice, 0, 1) })
		else
			for stealing = 0, seats - 1 do
				table.insert(cells, {
					when = othersPhrase(stealing, seats - 1),
					prize = DecisionLogic.prizeFor(choice, stealing, seats),
				})
			end
		end
		table.insert(rows, { choice = choice, cells = cells })
	end
	return rows
end

local PRIZE_LABEL: { [Prize]: string } = table.freeze({
	Big = "BIG",
	Medium = "MEDIUM",
	Small = "SMALL",
	Nothing = "NOTHING",
})
DecisionLogic.PRIZE_LABEL = PRIZE_LABEL

-- THE EXPLAINER (P6-8, docs/onboarding.md). The "How it works" sheet
-- walks the four ways a table can go, one line each, written for a
-- 12-year-old's first read. Every prize in it comes from prizeFor, so
-- the words can't drift from the rules: retune Outcomes and the sheet
-- follows. A player who misreads the finale feels cheated rather than
-- outplayed, so this is the one screen that must never be wrong.
export type ExplainerRow = { stealers: number, headline: string, detail: string }

local COUNT_PHRASE: { [number]: string } = { [1] = "One person steals", [2] = "Two people steal" }

-- Takes a plain string: prizeFor's literals widen to string once they're
-- stored in a local.
local function prizePhrase(prize: string, plural: boolean): string
	local verb = if plural then "get" else "gets"
	if prize == "Nothing" then
		return verb .. " nothing"
	end
	return string.format("%s %s %s prize", verb, if prize == "Big" then "the" else "a", PRIZE_LABEL[prize :: Prize])
end

function DecisionLogic.explainerRows(seats: number): { ExplainerRow }
	if seats <= 1 then
		local only = DecisionLogic.prizeFor("Share", 0, 1)
		return {
			{
				stealers = 0,
				headline = "Just you",
				detail = "You " .. prizePhrase(only, true) .. ", whatever you pick.",
			},
		}
	end
	local rows: { ExplainerRow } = {}
	for stealers = 0, seats do
		local sharers = seats - stealers
		local stealPrize = DecisionLogic.prizeFor("Steal", math.max(stealers - 1, 0), seats)
		local sharePrize = DecisionLogic.prizeFor("Share", stealers, seats)
		local headline, detail
		if stealers == 0 then
			headline, detail = "Everyone shares", "Everyone " .. prizePhrase(sharePrize, false) .. "."
		elseif sharers == 0 then
			headline, detail = "Everyone steals", "Everyone " .. prizePhrase(stealPrize, false) .. "."
		else
			headline = COUNT_PHRASE[stealers] or string.format("%d people steal", stealers)
			local stealLine = (if stealers == 1 then "The stealer " else "The stealers ")
				.. prizePhrase(stealPrize, stealers > 1)
				.. "."
			local shareLine = (if sharers == 1 then "The one who shared " else "The sharers ")
				.. prizePhrase(sharePrize, sharers > 1)
				.. "."
			-- Whoever got something reads first.
			detail = if sharePrize ~= "Nothing" and stealPrize == "Nothing"
				then shareLine .. " " .. stealLine
				else stealLine .. " " .. shareLine
		end
		table.insert(rows, { stealers = stealers, headline = headline, detail = detail })
	end
	return rows
end

-- The rest of the sheet: how picking works, the one-line lesson, and
-- what it does to your streak (design-decisions.md Q7: any prize is a
-- win, nothing is a loss).
DecisionLogic.EXPLAINER = table.freeze({
	title = "Steal or Share?",
	secret = "Everyone picks in secret. All the picks are shown at the same time.",
	lesson = "Stealing only works if you're the only one who does it.",
	streak = "Get a prize and your streak goes up. Get nothing and it goes back to 0.",
})

-- The prize a winner took, from the branch alone. Mirrors
-- DecisionService.outcomeTagFor, so it names the same package the
-- server granted.
function DecisionLogic.prizeForBranch(branch: string, won: boolean): Prize
	if not won then
		return "Nothing"
	elseif branch == "SoleSteal" or branch == "OneStealOneShare" then
		return "Big"
	elseif branch == "LoneShare" then
		return "Medium"
	end
	return "Small"
end

-- STAGE --------------------------------------------------------------

-- The reveal packet wins over the phase: DecisionPhaseChanged("Reveal")
-- and DecisionReveal are two events with no promised order, and once
-- the packet is here nothing else matters.
function DecisionLogic.stage(phase: Phase?, reveal: Reveal?, selfLocked: boolean, isFinalist: boolean): Stage
	if reveal ~= nil then
		return "Reveal"
	elseif phase == "Intro" or phase == "Negotiate" then
		return phase
	elseif phase == "Choose" then
		return if isFinalist and not selfLocked then "Choose" else "Locked"
	elseif phase == "Reveal" or phase == "Resolve" then
		return "Locked"
	end
	return "Waiting"
end

-- HOLD TO CONFIRM ----------------------------------------------------

-- Open -> Holding(choice) on press; back to Open if released early;
-- Locked(choice) once held for holdSeconds. Locked never leaves Locked:
-- there is no undo, and the server would refuse one anyway.
export type ConfirmState = "Open" | "Holding" | "Locked"
export type Confirm = { state: ConfirmState, choice: Choice?, startedAt: number }

DecisionLogic.OPEN = table.freeze({ state = "Open", choice = nil, startedAt = 0 } :: Confirm)

-- A press while already holding (a second thumb on the other button) is
-- ignored rather than switching: the first deliberate hold owns it.
function DecisionLogic.press(c: Confirm, choice: Choice, now: number): Confirm
	if c.state ~= "Open" then
		return c
	end
	return table.freeze({ state = "Holding", choice = choice, startedAt = now } :: Confirm)
end

function DecisionLogic.release(c: Confirm, choice: Choice): Confirm
	if c.state ~= "Holding" or c.choice ~= choice then
		return c
	end
	return DecisionLogic.OPEN
end

-- Returns the new state and whether THIS tick is the one that locked
-- (so the caller sends exactly one intent).
function DecisionLogic.tick(c: Confirm, now: number, holdSeconds: number): (Confirm, boolean)
	if c.state ~= "Holding" or now - c.startedAt < holdSeconds then
		return c, false
	end
	return table.freeze({ state = "Locked", choice = c.choice, startedAt = c.startedAt } :: Confirm), true
end

function DecisionLogic.holdFraction(c: Confirm, now: number, holdSeconds: number): number
	if c.state == "Locked" then
		return 1
	elseif c.state ~= "Holding" or holdSeconds <= 0 then
		return 0
	end
	return math.clamp((now - c.startedAt) / holdSeconds, 0, 1)
end

-- REVEAL TIMELINE ----------------------------------------------------

export type RevealStep = { cardsShown: number, outcomeShown: boolean, resultShown: boolean }

-- A function of (server now - revealAt) ONLY. Every client computes the
-- same step at the same server time whenever its packet happened to
-- land - a late packet joins the timeline part-way, it never restarts
-- it. No client-side timer anywhere.
function DecisionLogic.revealStep(elapsed: number, seats: number): RevealStep
	local t = DecisionLogic.TIMING
	local shown = 0
	if elapsed >= t.lead then
		shown = math.min(seats, 1 + math.floor((elapsed - t.lead) / t.cardGap))
	end
	local lastCard = t.lead + math.max(0, seats - 1) * t.cardGap
	local outcomeAt = lastCard + t.outcomeAfter
	return {
		cardsShown = shown,
		outcomeShown = elapsed >= outcomeAt,
		resultShown = elapsed >= outcomeAt + t.resultAfter,
	}
end

function DecisionLogic.revealLength(seats: number): number
	local t = DecisionLogic.TIMING
	return t.lead + math.max(0, seats - 1) * t.cardGap + t.outcomeAfter + t.resultAfter
end

-- RESULT COPY --------------------------------------------------------

export type ResultCopy = { headline: string, detail: string, streak: string?, tone: Tone }

local HEADLINES: { [string]: { win: string, loss: string, watch: string } } = {
	SoleSteal = { win = "You took it all", loss = "Betrayed", watch = "One thief walks away" },
	OneStealOneShare = { win = "You took it all", loss = "Betrayed", watch = "One thief walks away" },
	LoneShare = { win = "They fought. You won.", loss = "Too many thieves", watch = "The sharer wins" },
	AllShare = { win = "Everyone shared", loss = "Everyone shared", watch = "Everyone shared" },
	TwoShare = { win = "Everyone shared", loss = "Everyone shared", watch = "Everyone shared" },
	AllSteal = { win = "Nobody wins", loss = "Nobody wins", watch = "Nobody wins" },
	TwoSteal = { win = "Nobody wins", loss = "Nobody wins", watch = "Nobody wins" },
	SoloFinalist = { win = "Last one standing", loss = "Last one standing", watch = "Last one standing" },
}

-- The streak line. A loss names the number that just died, plainly -
-- no "don't worry", no "better luck next time", and no cruelty either.
-- `personal` is nil for a spectator and until the targeted packet lands.
local function streakLine(personal: Personal?): string?
	if personal == nil then
		return nil
	end
	local before, after = personal.streakBefore, personal.streakAfter
	if personal.won then
		if after > before then
			return string.format("Streak %d", after)
		end
		return "No streak credit this round"
	end
	if after == before and before > 0 then
		return string.format("Streak %d kept - no streak credit this round", before)
	elseif before > 0 then
		return string.format("Your %d-win streak ends here", before)
	end
	return "No streak on the line"
end

function DecisionLogic.resultCopy(reveal: Reveal, selfId: number, personal: Personal?): ResultCopy
	local lines = HEADLINES[reveal.branch] or { win = "You won", loss = "You lost", watch = "The Studio has decided" }
	local won = table.find(reveal.winnerIds, selfId) ~= nil
	local lost = table.find(reveal.loserIds, selfId) ~= nil
	if not won and not lost then
		local prize: Prize = DecisionLogic.prizeForBranch(reveal.branch, #reveal.winnerIds > 0)
		return {
			headline = lines.watch,
			detail = if prize == "Nothing"
				then "No bounty this time"
				else string.format(
					"%s bounty to the winner%s",
					DecisionLogic.PRIZE_LABEL[prize],
					if #reveal.winnerIds > 1 then "s" else ""
				),
			streak = nil,
			tone = "neutral",
		}
	end
	local prize: Prize = DecisionLogic.prizeForBranch(reveal.branch, won)
	return {
		headline = if won then lines.win else lines.loss,
		detail = if won then string.format("%s bounty", DecisionLogic.PRIZE_LABEL[prize]) else "No bounty",
		streak = streakLine(personal),
		tone = if won then "win" else "loss",
	}
end

-- CHAT ---------------------------------------------------------------

export type Rect = { x: number, y: number, width: number, height: number }

-- Where the Studio's top content may start so it sits under Roblox's
-- chat window rather than behind it (CoreGui draws over PlayerGui) - a
-- player with no voice negotiates entirely in that window. A chat
-- window in the bottom half, hidden, or zero-sized pushes nothing. The
-- push is capped so the seats can't be shoved off a short screen.
function DecisionLogic.chatInset(chat: Rect?, usable: Rect, gap: number, maxFraction: number): number
	if chat == nil or chat.width <= 0 or chat.height <= 0 then
		return usable.y
	end
	if chat.y > usable.y + usable.height / 2 then
		return usable.y
	end
	local wanted = math.max(usable.y, chat.y + chat.height + gap)
	return math.min(wanted, usable.y + usable.height * maxFraction)
end

-- P6-7: the bottom margin for the decide stack. A player still typing
-- when Choose opens has the on-screen keyboard over the bottom half of
-- a portrait phone, which is exactly where the hold buttons sit, so the
-- stack rides up above it. `keyboardTop` is the keyboard's top edge in
-- the same space as `usable` (nil when it's closed); the lift is capped
-- at maxFraction of the height so the stack never leaves the screen.
function DecisionLogic.keyboardLift(keyboardTop: number?, usable: Rect, margin: number, maxFraction: number): number
	local bottom = usable.y + usable.height
	if keyboardTop == nil or keyboardTop >= bottom then
		return margin
	end
	local wanted = bottom - keyboardTop + margin
	return math.clamp(wanted, margin, math.max(margin, usable.height * maxFraction))
end

return DecisionLogic
