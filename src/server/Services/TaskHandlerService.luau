--!strict
-- The task-handler dispatcher (P2-5): builds a TaskContext, calls into
-- the right handler (src/server/TaskHandlers/, looked up by taskId),
-- and wires that up to the Net remotes a task's client view fires. This
-- is the ONLY code that ever calls a handler's start/validate/cleanup -
-- a handler itself never touches Players, CollectionService, GameConfig,
-- or a remote directly (Types.luau's own contract).
--
-- THE EXPLOIT THIS FILE'S OWN HEADER COMMENT KEEPS COMING BACK TO:
-- TaskChallenge can legitimately contain the task's own answer (code-
-- playback's whole premise is showing the player a code to memorize).
-- If that payload were ever sent with Net.fireAllClients instead of
-- Net.fireClient, EVERY player in the server would receive every OTHER
-- player's rolled code the instant they walked up to their own station -
-- letting an exploiter read a station's answer off the network without
-- ever attempting the task themselves, no macro or replay needed at all.
-- Net.fireClient(name, player, payload) below, not Net.fireAllClients,
-- is the one line that stops it - every call site in this file sends
-- TaskChallenge/TaskResult to the specific interacting player only.
--
-- The OTHER classic shortcut - a client just firing "I succeeded"
-- directly - has no code path to close here because it was never opened:
-- there is no remote a client can fire that means "mark this task done."
-- Completion is only ever a SERVER-SIDE conclusion, reached by calling
-- TaskService.recordCompletion after a handler's own validate() returns
-- true from real, individually rate-limited, individually range/time/
-- assignment-checked submissions (see handleSubmission below) - a script
-- that skips playing the minigame has nothing to send that would ever
-- produce that true.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local Tasks = require(ReplicatedStorage.Shared.Config.Tasks)
local StationOccupancy = require(ServerScriptService.Server.StationOccupancy)
local Types = require(ServerScriptService.Server.TaskHandlers.Types)
local handlers = require(ServerScriptService.Server.TaskHandlers) :: { [string]: Types.TaskHandler<any, any, any> }

-- Looked up once at boot, not per-interaction - TaskDefs never change at
-- runtime.
local taskDefsById: { [string]: Validate.TaskDef } = {}
for _, entry in Tasks do
	local def = entry.def :: Validate.TaskDef
	taskDefsById[def.id] = def
end

type Session = {
	taskId: string,
	handler: Types.TaskHandler<any, any, any>,
	ctx: Types.TaskContext,
	state: any,
	-- Per-player counter (P6-4), sent with TaskChallenge and echoed by
	-- TaskAbort/TaskEnded, so a message about an old attempt can never
	-- end a newer one on either side, whatever order remotes land in.
	attempt: number,
	-- Solved, waiting out the plausible-time floor before it counts.
	-- Further submissions are ignored so they can't disturb the solve.
	completing: boolean?,
}

-- One attempt at a time per player - matches CLAUDE.md's mobile-first,
-- one-thumb-at-a-time reality; nothing about this framework needs a
-- player to have two tasks in flight simultaneously.
local activeSessions: { [Player]: Session } = {}
local attemptCounters: { [Player]: number } = {}

-- Task Insight used away from a station: the next attempt started
-- before this server time rolls easy, then the window is spent.
local insightUntil: { [Player]: number } = {}
-- Task Scramble's added time per player this round (powerups.md rule 5).
local scrambleExposure: { [Player]: number } = {}
-- powerups.md #9's "~4s added" per re-roll, and the round cap. Insight
-- "halves the added time cost": a scrambled easy attempt re-rolls easy.
local SCRAMBLE_COST_SECONDS = 4
local SCRAMBLE_EXPOSURE_CAP_SECONDS = 15

-- The hub's practice station (PracticeService.setPracticeStation): the
-- same handler, view and checks as a race station, but nobody is
-- assigned it. Anyone `mayUse` lets in can start it, a solve is only
-- feedback (never TaskService.recordCompletion, so nothing reaches a
-- stat - practice-area.md), and a scramble there costs no exposure,
-- since the hub has no round to reset it.
type PracticeStation = {
	stationId: string,
	part: BasePart,
	taskId: string,
	mayUse: (Player) -> boolean,
}
local practiceStation: PracticeStation? = nil

local function practiceFor(stationId: string): PracticeStation?
	local station = practiceStation
	if station ~= nil and station.stationId == stationId then
		return station
	end
	return nil
end

-- May `player` work on `stationId` right now: their own unfinished race
-- station, or the practice station while practising.
local function mayWork(player: Player, stationId: string): boolean
	local practice = practiceFor(stationId)
	if practice ~= nil then
		return practice.mayUse(player)
	end
	return (Loader.get("TaskService") :: any).isAssignedAndIncomplete(player, stationId)
end

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function isPlayerInRange(player: Player, stationPart: BasePart): boolean
	local character = player.Character
	if character == nil then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	return (root.Position - stationPart.Position).Magnitude <= Types.INTERACT_RANGE_STUDS
end

-- "cleanup(ctx) always runs" (the task's own requirement) - the ONE
-- place that's true from: task success, a new interaction superseding an
-- old one, a player leaving. Safe to call with no active session (a
-- no-op), so every call site below can call it unconditionally rather
-- than each having to re-check first.
--
-- `notify` tells the client its view is dead (TaskEnded). Every ending
-- the client didn't cause or can't already see passes true; success
-- (TaskResult says it), an abort (the client asked) and a leave don't.
local function endSession(player: Player, notify: boolean?)
	local session = activeSessions[player]
	if session == nil then
		return
	end
	session.handler.cleanup(session.ctx, session.state)
	activeSessions[player] = nil
	if notify and player.Parent ~= nil then
		Net.fireClient("TaskEnded", player, { attempt = session.attempt })
	end
	StationOccupancy.leave(player.UserId)
end

-- Logs a race attempt the player gave up on. A solve waiting out its
-- floor, a practice attempt, a re-roll at the same station and the
-- round ending aren't abandonment, so their paths never call this.
local function logAbandoned(player: Player, exit: string)
	local session = activeSessions[player]
	if session == nil or session.completing or practiceFor(session.ctx.stationId) ~= nil then
		return
	end
	Loader.get("Telemetry").taskAbandoned(player, session.taskId, session.ctx.elapsedSeconds(), exit)
end

-- `forceEasy` is set by a power-up restarting the current attempt;
-- a player's own interaction leaves it nil and takes any Insight window.
local function beginInteraction(player: Player, stationId: string, forceEasy: boolean?)
	local TaskService = Loader.get("TaskService") :: any

	-- A new interaction (at this station or any other) always supersedes
	-- whatever this player's previous attempt was - "including when the
	-- player... is frozen by a power-up mid-task" only ever actually
	-- matters if walking away and starting something else also cleans up
	-- correctly, which this covers the same way. Notified: if this new
	-- request fails the checks below, no challenge replaces the old view.
	local previous = activeSessions[player]
	if previous ~= nil and previous.ctx.stationId ~= stationId then
		logAbandoned(player, "Switched")
	end
	endSession(player, true)

	if not mayWork(player, stationId) then
		return
	end

	local practice = practiceFor(stationId)
	local stationPart = if practice ~= nil then practice.part else TaskService.getStationPart(stationId) :: BasePart?
	if stationPart == nil or not isPlayerInRange(player, stationPart) then
		return
	end

	local taskId = if practice ~= nil then practice.taskId else TaskService.getTaskIdFor(player, stationId) :: string?
	if taskId == nil then
		return
	end

	local handler = handlers[taskId]
	if handler == nil then
		warn(string.format("TaskHandlerService: no handler registered for taskId %q", taskId))
		return
	end

	local startedAt = now()
	local easy = forceEasy
	if easy == nil then
		local window = insightUntil[player]
		easy = window ~= nil and startedAt <= window
	end
	if easy then
		insightUntil[player] = nil -- one easy attempt per Insight
	end
	local ctx: Types.TaskContext = {
		player = player,
		stationId = stationId,
		stationPart = stationPart,
		-- Random.new (a real Roblox datatype), not TaskAssignment.luau's
		-- hand-rolled LCG - this file is Roblox-only and never needs to
		-- require() under Lune, so there's no reason to avoid it here the
		-- way TaskAssignment.luau had to.
		rng = Random.new(math.floor(startedAt * 1000) + player.UserId),
		elapsedSeconds = function()
			return now() - startedAt
		end,
		easy = easy == true,
	}

	local challenge, state = handler.start(ctx)
	local attempt = (attemptCounters[player] or 0) + 1
	attemptCounters[player] = attempt
	activeSessions[player] = { taskId = taskId, handler = handler, ctx = ctx, state = state, attempt = attempt }

	-- Targeted at this one player - see this file's own header comment.
	Net.fireClient(
		"TaskChallenge",
		player,
		{ stationId = stationId, taskId = taskId, challenge = challenge, attempt = attempt }
	)
	StationOccupancy.enter(player.UserId, stationPart)
end

-- The shared entry point every per-task submission remote (KeypadDigitSubmit
-- today; a future verb's own remote later) funnels into. `submission` is
-- whatever shape that task's handler declared for itself - this function
-- never looks inside it, only ever hands it straight to the handler.
local function handleSubmission(player: Player, stationId: string, submission: any)
	local TaskService = Loader.get("TaskService") :: any

	local session = activeSessions[player]
	if session == nil or session.ctx.stationId ~= stationId or session.completing then
		return
	end

	-- The three shared environmental guards Types.luau's own header
	-- comment names - checked HERE, once, rather than left for every
	-- handler author to remember. A handler's validate() is never even
	-- called if any of these fail.
	if not mayWork(player, stationId) then
		endSession(player, true)
		return
	end

	if not isPlayerInRange(player, session.ctx.stationPart) then
		return
	end

	local done, nextState, feedback = session.handler.validate(session.ctx, session.state, submission)
	session.state = nextState

	local function complete()
		Net.fireClient(
			"TaskResult",
			player,
			{ stationId = stationId, success = true, attempt = session.attempt, feedback = feedback }
		)
		-- The session's own elapsed time goes along with the completion
		-- (P3-5): it's the only place a REAL human duration for this task
		-- exists, and NPCService's fairness floor is measured against the
		-- median of exactly these numbers. Nothing about qualification
		-- reads it - see TaskService.recordCompletionFor. A practice solve
		-- stops at the TaskResult above: it records nothing.
		if practiceFor(stationId) == nil then
			TaskService.recordCompletion(player, stationId, session.ctx.elapsedSeconds())
		end
		endSession(player)
	end

	if not done then
		Net.fireClient(
			"TaskResult",
			player,
			{ stationId = stationId, success = false, attempt = session.attempt, feedback = feedback }
		)
		return
	end

	-- Solved too fast to be human: hold the completion until the floor.
	-- The view shows the last step landing (feedback), then "Done!" when
	-- this fires. Anything that ends the session meanwhile - walking
	-- away, a new interaction, the round ending - cancels it.
	local taskDef = taskDefsById[session.taskId]
	local wait = Types.completionDelaySeconds(
		if taskDef then taskDef.expectedDurationSeconds.min else nil,
		session.ctx.elapsedSeconds()
	)
	if wait <= 0 then
		complete()
		return
	end
	session.completing = true
	Net.fireClient(
		"TaskResult",
		player,
		{ stationId = stationId, success = false, attempt = session.attempt, feedback = feedback }
	)
	task.delay(wait, function()
		if activeSessions[player] == session and mayWork(player, stationId) then
			complete()
		end
	end)
end

-- ===== task power-ups (powerups.md #3 Task Insight, #9 Task Scramble) ====
--
-- Both re-roll the player's CURRENT attempt by starting a fresh one at
-- the same station - the same path a new interaction takes, so the old
-- view gets TaskEnded and the new TaskChallenge replaces it, and every
-- range/assignment check runs again. StatusEffects calls these after its
-- own gates (a bot caster, Phase Step, Second Wind); only the session
-- rules live here.

-- True if a new attempt replaced the one in progress.
local function restartAttempt(player: Player, easy: boolean): boolean
	local session = activeSessions[player]
	if session == nil or session.completing then
		return false
	end
	beginInteraction(player, session.ctx.stationId, easy)
	local replaced = activeSessions[player]
	return replaced ~= nil and replaced ~= session
end

-- Mid-task: the attempt restarts on its easy tier. Otherwise the next
-- attempt started within `windowSeconds` rolls easy.
local function grantInsight(player: Player, windowSeconds: number): (boolean, string)
	if restartAttempt(player, true) then
		insightUntil[player] = nil
		return true, "current task re-rolled easy"
	end
	insightUntil[player] = now() + windowSeconds
	return true, string.format("next task within %gs rolls easy", windowSeconds)
end

-- Re-rolls the victim's current attempt from scratch. Away from a
-- station there's nothing to scramble ("disengaging from the station
-- before the cast lands avoids it entirely"), and past rule 5's cap the
-- cast fails - either way the caster's item is already spent.
local function scramble(player: Player): (boolean, string)
	local session = activeSessions[player]
	if session == nil or session.completing then
		return false, "target isn't at a task"
	end
	local spent = scrambleExposure[player] or 0
	if spent >= SCRAMBLE_EXPOSURE_CAP_SECONDS then
		return false, "target is scramble-immune this round"
	end
	local easy = session.ctx.easy
	local practice = practiceFor(session.ctx.stationId) ~= nil
	if not restartAttempt(player, easy) then
		return false, "target isn't at a task"
	end
	if not practice then
		scrambleExposure[player] = spent + (if easy then SCRAMBLE_COST_SECONDS / 2 else SCRAMBLE_COST_SECONDS)
	end
	return true, "task re-rolled"
end

-- PracticeService registers the hub's one practice station here.
local function setPracticeStation(stationId: string, part: BasePart, taskId: string, mayUse: (Player) -> boolean)
	if handlers[taskId] == nil then
		warn(string.format("TaskHandlerService: no handler for practice taskId %q - no practice station", taskId))
		return
	end
	practiceStation = { stationId = stationId, part = part, taskId = taskId, mayUse = mayUse }
end

-- True while `player` has an attempt in progress at the practice station
-- (not one already solved and waiting out the floor).
local function isAtPracticeTask(player: Player): boolean
	local session = activeSessions[player]
	return session ~= nil and not session.completing and practiceFor(session.ctx.stationId) ~= nil
end

-- Ends a practice attempt whose player just stopped practising (a match
-- claimed them). No-op for anything else.
local function endPracticeFor(player: Player)
	local session = activeSessions[player]
	if session ~= nil and practiceFor(session.ctx.stationId) ~= nil then
		endSession(player, true)
	end
end

local TaskHandlerService: Loader.Service = {
	name = "TaskHandlerService",
	dependencies = { "NetGuard", "ConfigValidator", "TaskService", "RoundService", "Telemetry" },

	grantInsight = grantInsight,
	scramble = scramble,
	setPracticeStation = setPracticeStation,
	isAtPracticeTask = isAtPracticeTask,
	endPracticeFor = endPracticeFor,
}

function TaskHandlerService:init()
	local NetGuard = Loader.get("NetGuard") :: any

	NetGuard.on("TaskInteract", function(player: Player, payload: any)
		beginInteraction(player, payload.stationId)
	end)

	-- CodePlayback's own submission remote (P2-5's reference task). A new
	-- task reusing this same verb/interaction shape wires its own
	-- taskId's session the same way, through this same handleSubmission -
	-- only a task introducing a genuinely NEW interaction shape needs a
	-- new remote and a new NetGuard.on block here (docs/
	-- how-to-add-a-task.md covers this).
	NetGuard.on("KeypadDigitSubmit", function(player: Player, payload: any)
		handleSubmission(player, payload.stationId, { digit = payload.digit })
	end)

	-- PressureValve's own submission remote (P2-6's Tap reference task) -
	-- no task-specific fields beyond stationId, which the dispatcher
	-- already consumed above.
	NetGuard.on("TapSubmit", function(player: Player, payload: any)
		handleSubmission(player, payload.stationId, {})
	end)

	-- FuseRewire's own submission remote (P2-6's Drag reference task).
	NetGuard.on("FuseDropSubmit", function(player: Player, payload: any)
		handleSubmission(player, payload.stationId, { fuseId = payload.fuseId, slotId = payload.slotId })
	end)

	-- The Hold verb's own submission remote (AlarmKillswitch): press and
	-- release edges only.
	NetGuard.on("HoldSubmit", function(player: Player, payload: any)
		handleSubmission(player, payload.stationId, { pressed = payload.pressed })
	end)

	-- The Timing verb's own submission remote (ReactorSync, AirlockCycle):
	-- one stop tap and the attempt-clock time it claims.
	NetGuard.on("TimingSubmit", function(player: Player, payload: any)
		handleSubmission(player, payload.stationId, { at = payload.at })
	end)

	-- The task view's close/abort path (P6-4). Only ends the attempt the
	-- client is looking at: an abort for an older one is stale and dropped.
	NetGuard.on("TaskAbort", function(player: Player, payload: any)
		local session = activeSessions[player]
		if session ~= nil and session.attempt == payload.attempt then
			logAbandoned(player, "Closed")
			endSession(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		endSession(player)
		attemptCounters[player] = nil
		insightUntil[player] = nil
		scrambleExposure[player] = nil
	end)

	-- A real server only ever runs one round (architecture.md - Cleanup
	-- has no legal transition out), so this never fires against a stale
	-- session in production. Studio's debug interface is the exception:
	-- RoundService.debugForceTransition/debugReplayState exist
	-- specifically so a developer can replay Race repeatedly on the same
	-- server without a fresh one - without this, a session left over from
	-- a previous test race would linger, referencing a stationPart that
	-- may not even exist once a different map is loaded for the next one.
	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Race", function()
		for player in activeSessions do
			endSession(player, true)
		end
		StationOccupancy.clear()
		table.clear(insightUntil)
		table.clear(scrambleExposure)
	end)
end

return TaskHandlerService
