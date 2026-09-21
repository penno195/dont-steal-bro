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

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local TaskViews = require(script.Parent.Parent.TaskViews)
local TaskViewTypes = require(script.Parent.Parent.TaskViews.Types)

local PROMPT_MAX_DISTANCE = 10 -- client-side only, purely for prompt visibility - the server's own range check (TaskHandlers/Types.luau's INTERACT_RANGE_STUDS) is the one that's actually enforced

local activeView: TaskViewTypes.TaskView? = nil
local activeStationId: string? = nil

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

	prompt.Triggered:Connect(function()
		Net.fireServer("TaskInteract", { stationId = stationId })
	end)
end

local function onChallenge(payload: any)
	local stationId = payload.stationId :: string
	local taskId = payload.taskId :: string

	if activeView ~= nil and activeStationId ~= nil and activeStationId ~= stationId then
		-- The server only ever runs one attempt per player at a time
		-- (TaskHandlerService.beginInteraction calls endSession before
		-- starting a new one) - a challenge for a DIFFERENT station means
		-- our previous one was just superseded server-side.
		activeView.hide(activeStationId)
	end

	local view = TaskViews[taskId]
	if view == nil then
		warn(string.format("TaskStationController: no TaskView registered for taskId %q", taskId))
		return
	end

	activeView = view
	activeStationId = stationId
	view.show(stationId, payload.challenge)
end

local function onResult(payload: any)
	if activeView == nil or activeStationId ~= payload.stationId then
		return
	end

	activeView.onResult(payload.stationId, payload.success)

	if payload.success then
		activeView = nil
		activeStationId = nil
	end
end

local TaskStationController: Loader.Controller = {
	name = "TaskStationController",
	dependencies = {},
}

function TaskStationController:init()
	Net.onClientEvent("TaskChallenge", onChallenge)
	Net.onClientEvent("TaskResult", onResult)
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
