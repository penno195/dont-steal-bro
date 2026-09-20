--!strict
-- The round state machine (P2-1) - "the single source of truth for what
-- phase the server is in." RoundStates.luau (src/shared/RoundStates.
-- luau) declares the legal transition table as data; this is what
-- enforces it against a live server: per-state Signals other services
-- subscribe to instead of polling, timers, client replication, and a
-- debug interface for testing the Decision Studio without waiting
-- through a real race.
--
-- WHY THE MACHINE NEVER AUTO-STARTS ITSELF:
-- Loader.luau's own contract is "init() may fetch another module via
-- Loader.get(...) but must not call methods on it yet; start() is the
-- first point that's safe." A service that wants to react to a round
-- state (RoundService.onEnter("Race", ...)) has to be free to subscribe
-- from its OWN init() or start() without a race against RoundService
-- already having fired that state. This module resolves that by
-- creating every Signal at MODULE LOAD time (so subscribing is always
-- safe, before or after RoundService's own init/start) and never firing
-- the first real transition automatically - the machine sits in
-- WaitingForPlayers, inert, until something external (a future
-- MatchmakingService, or the debug interface below) calls
-- requestTransition. By the time any real transition happens in a live
-- server, every service's init() and start() has already run.
--
-- WHY STATE IS REPLICATED AS ONE SMALL PAYLOAD, NOT A PER-SECOND TICK:
-- the state name plus an absolute end time from workspace:
-- GetServerTimeNow() (architecture.md §3) is everything a client needs -
-- it computes its own countdown locally (Clock.luau, P2-2) and a late
-- joiner gets the same payload directly on PlayerAdded, so "timers that
-- survive a player joining late" falls out of the design for free rather
-- than needing special-case catch-up logic.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local RoundStates = require(ReplicatedStorage.Shared.RoundStates)
local Signal = require(ReplicatedStorage.Packages.Signal)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

-- A local alias, not just repeated `RoundStates.RoundState` - luau-lsp
-- doesn't always preserve a required module's string-literal-union type
-- precisely across the require boundary (confirmed locally: iterating
-- `RoundStates.ALL` without this alias widened each element to `string`,
-- not the literal union). Aliasing it once here keeps every other use
-- below unambiguous.
type RoundState = RoundStates.RoundState

-- PLACEHOLDER: no real developer UserIds configured yet. Populate before
-- relying on the live-server half of the debug gate below - until then,
-- only a Studio session can reach the debug interface at all.
local DEVELOPER_USER_IDS: { number } = {}

-- Fixed per-state durations, sourced from GameConfig (P1-4). `nil` means
-- externally driven, not "instant": WaitingForPlayers ends when a future
-- MatchmakingService says the server is full; DecisionStudio ends when a
-- future DecisionService's own inner phase machine resolves. Neither is
-- a fixed timer RoundService itself should own.
local STATE_DURATIONS: { [RoundState]: number? } = {
	WaitingForPlayers = nil,
	Loading = GameConfig.roundTimers.loadingSeconds,
	Intro = GameConfig.roundTimers.introSeconds,
	Race = GameConfig.raceDurationSeconds,
	Qualified = GameConfig.roundTimers.qualifiedSeconds,
	DecisionStudio = nil,
	Results = GameConfig.roundTimers.resultsSeconds,
	Cleanup = GameConfig.roundTimers.cleanupSeconds,
}

local currentState: RoundState = "WaitingForPlayers"
local currentEndsAt: number? = nil
local exitRan = true -- nothing has been entered yet, so there's nothing pending to exit
local pendingTimerThread: thread? = nil

-- `any`, not the package's own exported `Signal<T...>` type: Signal's
-- Wally package is a re-export wrapper (Packages/Signal.lua just returns
-- another module's require), and luau-lsp doesn't resolve a generic type
-- name through that indirection ("Unknown type 'Signal.Signal'",
-- confirmed locally) - the same gap DataService.luau hit with
-- ProfileStore's `Profile<T>` (P1-5). `:Connect`/`:Fire`/`:Once` etc.
-- still autocomplete and typecheck fine on the VALUES returned by
-- `Signal.new()` itself; only the generic TYPE NAME fails to resolve.
--
-- Created eagerly, at module load - see the header comment on why this
-- (not RoundService:init()) is what makes subscribing from anywhere
-- always safe. Written out per-state rather than looped over RoundStates.
-- ALL: confirmed locally that indexing one of these tables with a loop
-- variable derived from a cross-module array value (even after an
-- explicit `:: {RoundState}` cast) doesn't type-check cleanly in this
-- luau-lsp version, while literal keys - as used everywhere else in this
-- file - do. States are a fixed, small enum, not a Ground-Rule-2
-- data-driven extension point, so the repetition costs nothing real.
local enterSignals: { [RoundState]: any } = {
	WaitingForPlayers = Signal.new(),
	Loading = Signal.new(),
	Intro = Signal.new(),
	Race = Signal.new(),
	Qualified = Signal.new(),
	DecisionStudio = Signal.new(),
	Results = Signal.new(),
	Cleanup = Signal.new(),
}
local exitSignals: { [RoundState]: any } = {
	WaitingForPlayers = Signal.new(),
	Loading = Signal.new(),
	Intro = Signal.new(),
	Race = Signal.new(),
	Qualified = Signal.new(),
	DecisionStudio = Signal.new(),
	Results = Signal.new(),
	Cleanup = Signal.new(),
}

-- Fires (player, theStateTheyLeftDuring) - "a handler for every player
-- leaving mid-state" (P2-1's own requirement), generic rather than
-- per-state since what a leaving player means differs entirely by
-- service (TaskService frees their station; DecisionService promotes an
-- alternate) and RoundService shouldn't need to know either of those.
local playerLeaving = Signal.new()

local function cancelPendingTimer()
	if pendingTimerThread ~= nil then
		task.cancel(pendingTimerThread)
		pendingTimerThread = nil
	end
end

local function broadcastState()
	Net.fireAllClients("RoundState", { state = currentState, endsAt = currentEndsAt })
end

-- Forward-declared: the timer-elapsed callback below and `transition`
-- call each other.
local transition: (to: RoundState, force: boolean?) -> ()

local function runTimerElapsed(forState: RoundState)
	pendingTimerThread = nil
	-- Explicit local type, not an inline `::` cast - same cross-module
	-- return-type precision gap as RoundStates.ALL above, and an inline
	-- cast on the expression didn't clear it either; a declared local
	-- type does. RoundStates.legalNextStates's OWN declared return type
	-- is already `{RoundState}`, this just re-asserts it.
	local nextState: RoundState? = RoundStates.legalNextStates(forState)[1]
	if nextState ~= nil then
		transition(nextState, false)
	end
end

local function enterState(state: RoundState)
	currentState = state
	exitRan = false
	cancelPendingTimer()

	local duration = STATE_DURATIONS[state]
	currentEndsAt = if duration ~= nil then Workspace:GetServerTimeNow() + duration else nil

	broadcastState()
	enterSignals[state]:Fire(currentEndsAt)

	if duration ~= nil then
		pendingTimerThread = task.delay(duration, function()
			runTimerElapsed(state)
		end)
	end
end

-- "A guard that a state's exit always runs exactly once, even when it is
-- triggered by both a timer and a condition in the same frame" - the
-- guard itself is RoundStates.runOnce; this is just the bookkeeping
-- around it (see ProfileLogic.release, P1-5, for the identical shape).
local function exitCurrentState(): boolean
	local ran = RoundStates.runOnce(exitRan, function()
		exitSignals[currentState]:Fire()
	end)
	if ran then
		exitRan = true
	end
	return ran
end

transition = function(to: RoundState, force: boolean?)
	if not force and not RoundStates.isLegalTransition(currentState, to) then
		local message = string.format("RoundService: illegal transition %s -> %s", currentState, to)
		if RunService:IsStudio() then
			error(message, 0)
		else
			warn(message)
		end
		return
	end

	exitCurrentState()
	enterState(to)
end

-- Requests a normal (legality-checked) transition. This is the one entry
-- point every other service uses - "matchmaking is full" is
-- requestTransition("Loading"); "three qualifiers finished early" is
-- requestTransition("Qualified"); the transition table itself (data, not
-- branching code) is what decides whether the request is honoured.
local function requestTransition(to: RoundState)
	transition(to, false)
end

local function isDebugAuthorized(player: Player?): boolean
	if RunService:IsStudio() then
		return true
	end
	if player == nil then
		return false
	end
	return table.find(DEVELOPER_USER_IDS, player.UserId) ~= nil
end

-- Forces ANY transition, bypassing RoundStates' legality table entirely.
-- Callable directly from a Studio command-bar/server script
-- (Loader.get("RoundService").debugForceTransition(...)); the gated
-- remote handler in init() below is what lets a live-server developer
-- reach this from a real client too.
local function debugForceTransition(to: RoundState)
	transition(to, true)
end

-- Fires the current state's pending timer immediately, instead of
-- waiting out its real duration - for fast-iterating a long state (Race)
-- in Studio.
local function debugSkipTimer()
	if pendingTimerThread == nil then
		return
	end
	local forState: RoundState = currentState
	cancelPendingTimer()
	runTimerElapsed(forState)
end

-- Re-enters the CURRENT state from scratch - resets its timer and
-- re-fires its enter signal, without treating it as a real exit (never
-- legal via the normal transition table, which is exactly why this
-- bypasses it directly rather than going through `transition`).
local function debugReplayState()
	enterState(currentState)
end

local RoundService: Loader.Service = {
	name = "RoundService",
	dependencies = { "NetGuard", "ConfigValidator" },

	getState = function(): RoundState
		return currentState
	end,
	getEndsAt = function(): number?
		return currentEndsAt
	end,
	onEnter = function(state: RoundState, callback: (endsAt: number?) -> ())
		return enterSignals[state]:Connect(callback)
	end,
	onExit = function(state: RoundState, callback: () -> ())
		return exitSignals[state]:Connect(callback)
	end,
	onPlayerLeaving = function(callback: (player: Player, state: RoundState) -> ())
		return playerLeaving:Connect(callback)
	end,
	requestTransition = requestTransition,
	debugForceTransition = debugForceTransition,
	debugSkipTimer = debugSkipTimer,
	debugReplayState = debugReplayState,
}

function RoundService:init()
	local NetGuard = Loader.get("NetGuard") :: any

	NetGuard.setRoundStateProvider(function(): string?
		return currentState
	end)

	NetGuard.on("DebugForceRoundState", function(player: Player, payload: any)
		if not isDebugAuthorized(player) then
			warn(
				string.format(
					"RoundService: unauthorized DebugForceRoundState attempt by %s (%d)",
					player.Name,
					player.UserId
				)
			)
			return
		end
		debugForceTransition(payload.state :: RoundState)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		Net.fireClient("RoundState", player, { state = currentState, endsAt = currentEndsAt })
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		playerLeaving:Fire(player, currentState)
	end)
end

function RoundService:start()
	-- Replication only, not a signal fire - see the header comment for
	-- why the actual state machine doesn't start itself here.
	broadcastState()
end

return RoundService
