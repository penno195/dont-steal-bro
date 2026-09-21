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
}

-- One attempt at a time per player - matches CLAUDE.md's mobile-first,
-- one-thumb-at-a-time reality; nothing about this framework needs a
-- player to have two tasks in flight simultaneously.
local activeSessions: { [Player]: Session } = {}

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
local function endSession(player: Player)
	local session = activeSessions[player]
	if session == nil then
		return
	end
	session.handler.cleanup(session.ctx, session.state)
	activeSessions[player] = nil
end

local function beginInteraction(player: Player, stationId: string)
	local TaskService = Loader.get("TaskService") :: any

	-- A new interaction (at this station or any other) always supersedes
	-- whatever this player's previous attempt was - "including when the
	-- player... is frozen by a power-up mid-task" only ever actually
	-- matters if walking away and starting something else also cleans up
	-- correctly, which this covers the same way.
	endSession(player)

	if not TaskService.isAssignedAndIncomplete(player, stationId) then
		return
	end

	local stationPart = TaskService.getStationPart(stationId) :: BasePart?
	if stationPart == nil or not isPlayerInRange(player, stationPart) then
		return
	end

	local taskId = TaskService.getTaskIdFor(player, stationId) :: string?
	if taskId == nil then
		return
	end

	local handler = handlers[taskId]
	if handler == nil then
		warn(string.format("TaskHandlerService: no handler registered for taskId %q", taskId))
		return
	end

	local startedAt = now()
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
	}

	local challenge, state = handler.start(ctx)
	activeSessions[player] = { taskId = taskId, handler = handler, ctx = ctx, state = state }

	-- Targeted at this one player - see this file's own header comment.
	Net.fireClient("TaskChallenge", player, { stationId = stationId, taskId = taskId, challenge = challenge })
end

-- The shared entry point every per-task submission remote (KeypadDigitSubmit
-- today; a future verb's own remote later) funnels into. `submission` is
-- whatever shape that task's handler declared for itself - this function
-- never looks inside it, only ever hands it straight to the handler.
local function handleSubmission(player: Player, stationId: string, submission: any)
	local TaskService = Loader.get("TaskService") :: any

	local session = activeSessions[player]
	if session == nil or session.ctx.stationId ~= stationId then
		return
	end

	-- The three shared environmental guards Types.luau's own header
	-- comment names - checked HERE, once, rather than left for every
	-- handler author to remember. A handler's validate() is never even
	-- called if any of these fail.
	if not TaskService.isAssignedAndIncomplete(player, stationId) then
		endSession(player)
		return
	end

	if not isPlayerInRange(player, session.ctx.stationPart) then
		return
	end

	local taskDef = taskDefsById[session.taskId]
	local minPlausibleSeconds = if taskDef
		then taskDef.expectedDurationSeconds.min * Types.MIN_PLAUSIBLE_COMPLETION_FRACTION
		else 0
	if session.ctx.elapsedSeconds() < minPlausibleSeconds then
		return
	end

	local done, nextState = session.handler.validate(session.ctx, session.state, submission)
	session.state = nextState

	Net.fireClient("TaskResult", player, { stationId = stationId, success = done })

	if done then
		TaskService.recordCompletion(player, stationId)
		endSession(player)
	end
end

local TaskHandlerService: Loader.Service = {
	name = "TaskHandlerService",
	dependencies = { "NetGuard", "ConfigValidator", "TaskService", "RoundService" },
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

	Players.PlayerRemoving:Connect(function(player: Player)
		endSession(player)
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
			endSession(player)
		end
	end)
end

return TaskHandlerService
