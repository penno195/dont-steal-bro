--!strict
-- The hub's Play button (P5-1's missing client half): what the queue
-- card says and which intent a tap sends. No Roblox API, so
-- tests/QueueLogic.spec runs it headlessly; QueueController feeds it
-- QueueState payloads and draws whatever `view` returns.
--
-- THE SERVER DECIDES. A tap only sends QueueJoinIntent or
-- QueueLeaveIntent (Ground Rule 1); the card changes when the server's
-- QueueState answers, never on the tap itself. Between the two the
-- button shows a spinner (`pending`), and gives up after
-- PENDING_TIMEOUT in case the intent was rate-limited and dropped
-- without a reply (Net.luau: capacity 3, refill 0.5/s).
--
-- ARE WE IN LINE? QueueState's `status` alone doesn't say. "Unavailable"
-- is sent both when a join is refused (not queued) and when the queue
-- store is struggling while a Waiting ticket is kept (still queued -
-- MatchmakingService's UNAVAILABLE_MESSAGE says "You're still in line").
-- So `queued` is tracked here: an Unavailable keeps whatever it was,
-- except straight after Joining, where it means the write failed.
--
-- COMMITTED: once MatchFound or Travelling, leaving is refused
-- server-side ("Your match is already on its way"), so the card offers
-- no button at all rather than one that can't work.

local QueueLogic = {}

export type Status = "Idle" | "Joining" | "Waiting" | "MatchFound" | "Travelling" | "Unavailable"
export type Intent = "Join" | "Leave"
export type Tone = "neutral" | "success" | "warning"

export type State = {
	status: Status,
	queued: boolean,
	message: string?,
	position: number?,
	queueSize: number?,
	queueSizeIsLowerBound: boolean,
	estimatedWaitSeconds: number?,
	-- os.clock() of the tap still awaiting a reply; nil when none.
	pendingSince: number?,
}

export type View = {
	headline: string?,
	detail: string?,
	tone: Tone,
	action: Intent?,
	actionLabel: string,
	busy: boolean,
	-- The world board over the queue pad (HubQueueCountdown): one short line.
	board: string,
}

QueueLogic.PENDING_TIMEOUT = 5

local STATUSES: { [string]: boolean } = {
	Idle = true,
	Joining = true,
	Waiting = true,
	MatchFound = true,
	Travelling = true,
	Unavailable = true,
}

function QueueLogic.new(): State
	return {
		status = "Idle",
		queued = false,
		message = nil,
		position = nil,
		queueSize = nil,
		queueSizeIsLowerBound = false,
		estimatedWaitSeconds = nil,
		pendingSince = nil,
	}
end

local function count(value: any): number?
	if type(value) == "number" and value == value and value >= 0 and value < math.huge then
		return math.floor(value)
	end
	return nil
end

-- Folds one QueueState payload in. Anything malformed is ignored and
-- the old state is handed back unchanged.
function QueueLogic.apply(state: State, payload: any): State
	if type(payload) ~= "table" or type(payload.status) ~= "string" or not STATUSES[payload.status] then
		return state
	end
	-- Checked against STATUSES above; the cast widens past the string refinement.
	local status: Status = (payload.status :: any) :: Status
	local queued = state.queued
	if status == "Idle" then
		queued = false
	elseif status == "Unavailable" then
		queued = state.queued and state.status ~= "Joining"
	else
		queued = true
	end

	local nextState = QueueLogic.new()
	nextState.status = status
	nextState.queued = queued
	nextState.message = if type(payload.message) == "string" and payload.message ~= "" then payload.message else nil
	if status == "Waiting" then
		-- The per-tick broadcast carries the numbers; the first Waiting
		-- (straight after the join) carries only an optional message.
		-- Keep the last numbers until new ones arrive.
		local hasNumbers = payload.queueSize ~= nil or payload.estimatedWaitSeconds ~= nil
		if hasNumbers then
			nextState.position = count(payload.position)
			nextState.queueSize = count(payload.queueSize)
			nextState.queueSizeIsLowerBound = payload.queueSizeIsLowerBound == true
			nextState.estimatedWaitSeconds = count(payload.estimatedWaitSeconds)
		elseif state.status == "Waiting" then
			nextState.position = state.position
			nextState.queueSize = state.queueSize
			nextState.queueSizeIsLowerBound = state.queueSizeIsLowerBound
			nextState.estimatedWaitSeconds = state.estimatedWaitSeconds
		end
	end
	return nextState
end

-- The intent a tap on the card's button should send, or nil for none.
function QueueLogic.actionFor(state: State): Intent?
	if state.status == "MatchFound" or state.status == "Travelling" then
		return nil
	end
	local intent: Intent = if state.queued then "Leave" else "Join"
	return intent
end

-- A tap. Returns the next state and the intent to fire (nil: ignore
-- the tap, e.g. one is already in flight).
function QueueLogic.tap(state: State, now: number): (State, Intent?)
	if state.pendingSince ~= nil and now - state.pendingSince < QueueLogic.PENDING_TIMEOUT then
		return state, nil
	end
	local intent: Intent? = QueueLogic.actionFor(state)
	if intent == nil then
		return state, nil
	end
	local nextState = table.clone(state)
	nextState.pendingSince = now
	return nextState, intent
end

-- Clears a pending tap that never got an answer.
function QueueLogic.tick(state: State, now: number): State
	if state.pendingSince ~= nil and now - state.pendingSince >= QueueLogic.PENDING_TIMEOUT then
		local nextState = table.clone(state)
		nextState.pendingSince = nil
		return nextState
	end
	return state
end

-- "~20s", "~2 min". Rounded up so it never promises faster than planned.
function QueueLogic.formatWait(seconds: number): string
	if seconds < 60 then
		return string.format("~%ds", math.max(1, math.ceil(seconds)))
	end
	return string.format("~%d min", math.ceil(seconds / 60))
end

local function lineText(state: State): string?
	local parts = {}
	if state.position ~= nil and state.queueSize ~= nil then
		table.insert(
			parts,
			string.format(
				"#%d of %d%s",
				state.position,
				state.queueSize,
				if state.queueSizeIsLowerBound then "+" else ""
			)
		)
	end
	if state.estimatedWaitSeconds ~= nil then
		table.insert(parts, QueueLogic.formatWait(state.estimatedWaitSeconds))
	end
	return if #parts > 0 then table.concat(parts, "  ·  ") else nil
end

-- `practice`: this is a private server (design-decisions.md Q7, the
-- practice-match case), so the queue is the friends here, not the world.
function QueueLogic.view(state: State, practice: boolean?): View
	local action: Intent? = QueueLogic.actionFor(state)
	local view: View = {
		headline = nil,
		detail = state.message,
		tone = "neutral",
		action = action,
		actionLabel = if action == "Leave" then "Leave queue" else "Play",
		busy = state.pendingSince ~= nil or state.status == "Joining",
		board = "Tap PLAY to join",
	}
	local status = state.status
	if status == "Joining" then
		view.headline = "Joining the queue..."
		view.board = "Joining..."
	elseif status == "Waiting" then
		local line = lineText(state)
		view.headline = "Finding players..."
		view.detail = state.message or line
		view.board = if line then "In line  " .. line else "Finding players..."
	elseif status == "MatchFound" then
		view.headline = "Match found!"
		view.tone = "success"
		view.board = "Match found!"
	elseif status == "Travelling" then
		view.headline = "Heading to your match..."
		view.tone = "success"
		view.board = "Heading to your match..."
	elseif status == "Unavailable" then
		view.headline = if state.queued then "Still in line" else "Can't join right now"
		view.tone = "warning"
		view.board = if state.queued then "Still in line..." else "Queue unavailable"
	end
	if practice == true then
		if status == "Idle" then
			view.detail = state.message or "Practice server: no streak, coins or stats at stake."
			view.board = "Tap PLAY for a practice match"
		elseif status == "Waiting" then
			view.headline = "Waiting for your friends..."
			view.board = "Waiting for friends..."
		end
	end
	-- Idle with a message: a failed teleport sent them back (P5-2).
	return view
end

return QueueLogic
