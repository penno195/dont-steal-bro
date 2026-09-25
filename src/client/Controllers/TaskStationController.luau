--!strict
-- Launches a task's minigame when a player interacts with a TaskStation,
-- and dispatches server responses to the right TaskView by taskId
-- (P2-5). This is the ONLY code that fires TaskInteract or listens for
-- TaskChallenge/TaskResult - a view itself never touches those, only its
-- own per-task submission remote (see TaskViews/Types.luau).
--
-- ProximityPrompt, not a custom raycast/distance-check loop: it already
-- handles touch-tap on mobile, gamepad and keyboard uniformly, and is
-- the standard Roblox pattern for "walk up and interact" -
-- CLAUDE.md's mobile-first rule wants exactly this, not a bespoke input
-- system to get right per platform. Attached dynamically per tagged
-- TaskStation, since map builders only promise the CollectionService tag/
-- attribute contract (map-kit-spec.md), never a pre-placed prompt.
--
-- The server is what actually decides whether an interaction is legal
-- (assignment, range, round state) - this prompt firing is only ever a
-- REQUEST; TaskHandlerService.beginInteraction re-checks everything
-- itself and simply does nothing if the request doesn't hold up. Nothing
-- client-side here needs to duplicate that logic to stay safe, only to
-- feel responsive.

--
-- P6-4: this controller also owns WHEN an attempt ends, for every view
-- (TaskViewBase or not). An attempt ends on success, the view's own
-- close button (TaskViewTypes.Session.close), the server's TaskEnded,
-- or one of the guards below: the character died or was removed, it
-- was knocked/walked out of range, or the race ended. Every one of
-- those runs the same `finish`, which hides the view (releasing its
-- input lock) and tells the server, so the camera and controls come
-- back whichever way the attempt ended.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local TaskViews = require(script.Parent.Parent.TaskViews)
local TaskViewTypes = require(script.Parent.Parent.TaskViews.Types)
local Tokens = require(script.Parent.Parent.UI.Tokens)

local PROMPT_MAX_DISTANCE = 10 -- client-side only, purely for prompt visibility - the server's own range check (TaskHandlers/Types.luau's INTERACT_RANGE_STUDS) is the one that's actually enforced
local RANGE_CHECK_INTERVAL = 0.2

local activeView: TaskViewTypes.TaskView? = nil
local activeStationId: string? = nil
local activeAttempt = 0
local stopGuards: (() -> ())? = nil

-- Prompts show only on your own unfinished stations during Race: the
-- server rejects any other station, and a Start that silently does
-- nothing reads as a bug. Cosmetic only - the server check stands.
local prompts: { [string]: ProximityPrompt } = {}
local route: { [string]: boolean } = {} -- stationId -> completed
local racing = false

local function refreshPrompt(stationId: string)
	local prompt: ProximityPrompt? = prompts[stationId]
	if prompt ~= nil then
		prompt.Enabled = racing and route[stationId] == false
	end
end

local function refreshPrompts()
	for stationId in prompts do
		refreshPrompt(stationId)
	end
end

-- Ends the current attempt for any reason but success. `tellServer` is
-- false only when the server is the one that ended it.
local function finish(tellServer: boolean)
	local view, stationId = activeView, activeStationId
	if view == nil or stationId == nil then
		return
	end
	activeView = nil
	activeStationId = nil
	if stopGuards ~= nil then
		stopGuards()
		stopGuards = nil
	end
	view.hide(stationId)
	if tellServer then
		Net.fireServer("TaskAbort", { attempt = activeAttempt })
	end
end

local function stationPartFor(stationId: string): BasePart?
	for _, instance in CollectionService:GetTagged("TaskStation") do
		if instance:IsA("BasePart") and instance:GetAttribute("StationId") == stationId then
			return instance
		end
	end
	return nil
end

-- Watches the local character for the ways an attempt dies without
-- anyone pressing anything. Distance is polled (5 Hz; a knockback is a
-- physics impulse with no event of its own), death and removal are
-- events. Never ends anything synchronously, so it's safe to start
-- before the view is shown. Returns the disconnect.
local function startGuards(stationId: string): () -> ()
	local player = Players.LocalPlayer
	local station = stationPartFor(stationId)
	local connections: { RBXScriptConnection } = {}
	local running = true

	local function trip()
		if running then
			finish(true)
		end
	end

	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		table.insert(connections, humanoid.Died:Connect(trip))
	end
	table.insert(connections, player.CharacterRemoving:Connect(trip))

	task.spawn(function()
		while running do
			task.wait(RANGE_CHECK_INTERVAL)
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			local gone = root == nil or not root:IsA("BasePart")
			if
				gone
				or (
					station ~= nil
					and ((root :: BasePart).Position - station.Position).Magnitude > Tokens.taskView.leaveRangeStuds
				)
			then
				trip()
			end
		end
	end)

	return function()
		running = false
		for _, c in connections do
			c:Disconnect()
		end
	end
end

local function attachPrompt(stationPart: BasePart)
	if stationPart:FindFirstChildOfClass("ProximityPrompt") ~= nil then
		return
	end

	local stationId = stationPart:GetAttribute("StationId")
	if typeof(stationId) ~= "string" then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TaskInteractPrompt"
	prompt.ActionText = "Start"
	prompt.ObjectText = "Task"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PROMPT_MAX_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = stationPart
	prompts[stationId] = prompt
	refreshPrompt(stationId)

	prompt.Triggered:Connect(function()
		Net.fireServer("TaskInteract", { stationId = stationId })
	end)
end

local function onChallenge(payload: any)
	local stationId = payload.stationId :: string
	local taskId = payload.taskId :: string

	-- The server only ever runs one attempt per player at a time
	-- (TaskHandlerService.beginInteraction ends the old session before
	-- starting a new one), so any open view was just superseded
	-- server-side - including a restart at the same station.
	finish(false)

	local view = TaskViews[taskId]
	if view == nil then
		warn(string.format("TaskStationController: no TaskView registered for taskId %q", taskId))
		return
	end

	activeView = view
	activeStationId = stationId
	activeAttempt = payload.attempt :: number
	stopGuards = startGuards(stationId)
	local attempt = activeAttempt
	view.show(stationId, payload.challenge, {
		attempt = attempt,
		close = function()
			if activeAttempt == attempt then
				finish(true)
			end
		end,
	})
end

local function onEnded(payload: any)
	if payload.attempt == activeAttempt then
		finish(false)
	end
end

local function onRoundState(payload: any)
	racing = payload.state == "Race"
	if not racing then
		finish(true)
		route = {} -- a new race sends a new route
	end
	refreshPrompts()
end

local function onRoute(payload: any)
	route = {}
	for _, entry in payload.assignments do
		route[entry.stationId :: string] = entry.completed == true
	end
	refreshPrompts()
end

local function onResult(payload: any)
	if activeView == nil or activeStationId ~= payload.stationId or payload.attempt ~= activeAttempt then
		return
	end

	activeView.onResult(payload.stationId, payload.success, payload.feedback)

	if payload.success then
		activeView = nil
		activeStationId = nil
		if stopGuards ~= nil then
			stopGuards()
			stopGuards = nil
		end
	end
end

local TaskStationController: Loader.Controller = {
	name = "TaskStationController",
	dependencies = {},
}

function TaskStationController:init()
	Net.onClientEvent("TaskChallenge", onChallenge)
	Net.onClientEvent("TaskResult", onResult)
	Net.onClientEvent("TaskEnded", onEnded)
	Net.onClientEvent("RoundState", onRoundState)
	Net.onClientEvent("TaskAssignmentState", onRoute)
end

function TaskStationController:start()
	for _, instance in CollectionService:GetTagged("TaskStation") do
		if instance:IsA("BasePart") then
			attachPrompt(instance)
		end
	end

	-- Covers a map (or a station within it) that loads in AFTER this
	-- controller has already started - "timers that survive a player
	-- joining late" is RoundService's own phrase for the same kind of
	-- late-arrival robustness, applied here to station discovery instead.
	CollectionService:GetInstanceAddedSignal("TaskStation"):Connect(function(instance: Instance)
		if instance:IsA("BasePart") then
			attachPrompt(instance)
		end
	end)
end

return TaskStationController
