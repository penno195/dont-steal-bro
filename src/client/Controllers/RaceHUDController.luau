--!strict
-- Feeds the race HUD (P6-3, UI/Screens/RaceHUD.luau) and mounts it for
-- the Race round state. The HUD never touches a remote: every server
-- payload lands here, is turned into display-ready rows, and is written
-- into one Vide source. The sources live for the whole session, so data
-- that arrives just before the HUD mounts (TaskService sends the route
-- as the race begins, with no promised order against RoundState) is
-- already there when it does.
--
-- Everything received here is display-only. The use button sends a
-- bare intent (slot 1, no target: the server smart-targets, P2-7) and
-- the server decides what, if anything, happens.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local vide = require(ReplicatedStorage.Packages.Vide)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local Tasks = require(ReplicatedStorage.Shared.Config.Tasks)
local Toast = require(script.Parent.Parent.UI.Components.Toast)
local HudLogic = require(script.Parent.Parent.UI.HudLogic)
local RaceHUD = require(script.Parent.Parent.UI.Screens.RaceHUD)
local UIScaleController = require(script.Parent.UIScaleController)

local source = vide.source

-- Nearest-station search: ≤ tasksPerPlayer distance checks, 5 times a
-- second. The arrow itself turns every frame with the camera, but only
-- writes when it has moved a whole ARROW_STEP.
local SEARCH_INTERVAL = 0.2
local ARROW_STEP = 5
-- If the server never answers a use (a dropped remote), unstick the
-- button rather than leaving it spinning for the rest of the race.
local USE_TIMEOUT = 2

-- Short, player-facing versions of PowerUpService's refusal reasons
-- that a player can act on. Anything else is an internal refusal the
-- player couldn't do anything about, so it gets no toast.
local REFUSALS: { [string]: string } = {
	["no valid target"] = "No target",
	["on cooldown"] = "Cooling down",
}

local taskNames: { [string]: string } = {}
for _, entry in Tasks do
	taskNames[entry.def.id] = entry.def.displayName
end
local powerUpNames: { [string]: string } = {}
for _, entry in PowerUps do
	powerUpNames[entry.def.id] = entry.def.displayName
end

type Route = { stationId: string, taskId: string, completed: boolean }

local endsAt = source(nil :: number?)
local tasks = source({} :: { RaceHUD.TaskRow })
local progress = source({} :: { HudLogic.ProgressEntry })
local held = source(nil :: RaceHUD.Held?)
local pending = source(false)
local effects = source({} :: { HudLogic.Effect })
local objective = source(nil :: RaceHUD.Objective?)

-- stationIds still to do, from the latest TaskAssignmentState.
local outstanding: { string } = {}
local stationParts: { [string]: BasePart } = {}

local useToken = 0
local function use()
	if held() == nil or pending() then
		return
	end
	pending(true)
	useToken += 1
	local token = useToken
	Net.fireServer("PowerUpUseIntent", { slotIndex = 1 })
	task.delay(USE_TIMEOUT, function()
		if useToken == token then
			pending(false)
		end
	end)
end

local store: RaceHUD.Store = {
	selfId = Players.LocalPlayer.UserId,
	qualifierCount = GameConfig.qualifierCount,
	raceSeconds = GameConfig.raceDurationSeconds,
	endsAt = endsAt,
	tasks = tasks,
	progress = progress,
	held = held,
	pending = pending,
	effects = effects,
	objective = objective,
	use = use,
}

local function trackStation(instance: Instance)
	local stationId = instance:GetAttribute("StationId")
	if instance:IsA("BasePart") and typeof(stationId) == "string" then
		stationParts[stationId] = instance
	end
end

local function onRoute(payload: any)
	local rows: { RaceHUD.TaskRow } = {}
	outstanding = {}
	for _, entry: Route in payload.assignments do
		table.insert(
			rows,
			table.freeze({
				title = taskNames[entry.taskId] or entry.taskId,
				completed = entry.completed,
			})
		)
		if not entry.completed then
			table.insert(outstanding, entry.stationId)
		end
	end
	tasks(rows)
end

local function onEffects(payload: any)
	local list: { HudLogic.Effect } = {}
	for _, entry in payload.effects do
		table.insert(
			list,
			table.freeze({
				id = entry.id,
				category = entry.category,
				kind = entry.kind,
				expiresAt = entry.expiresAt,
			})
		)
	end
	effects(list)
end

local function onInventory(payload: any)
	local first = payload.inventory[1]
	if first == nil then
		held(nil)
	else
		held(table.freeze({ id = first.powerUpId, name = powerUpNames[first.powerUpId] or first.powerUpId }))
	end
end

local function onUseResult(payload: any)
	useToken += 1
	pending(false)
	local message = if payload.success then nil else REFUSALS[payload.reason]
	if message ~= nil then
		Toast.show(message, "warning")
	end
end

-- The objective arrow, while mounted. Returns the stop function.
local function runObjective(): () -> ()
	local target: BasePart? = nil
	local sinceSearch = math.huge
	local lastBearing: number? = nil
	local lastDistance: number? = nil

	local connection = RunService.RenderStepped:Connect(function(dt: number)
		local character = Players.LocalPlayer.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local camera = Workspace.CurrentCamera
		if root == nil or not root:IsA("BasePart") or camera == nil then
			objective(nil)
			lastBearing = nil
			return
		end
		local position = root.Position

		sinceSearch += dt
		if sinceSearch >= SEARCH_INTERVAL then
			sinceSearch = 0
			local points: { HudLogic.Point } = {}
			for _, stationId in outstanding do
				local part: BasePart? = stationParts[stationId]
				if part ~= nil and part.Parent ~= nil then
					table.insert(points, { id = stationId, x = part.Position.X, z = part.Position.Z })
				end
			end
			local best = HudLogic.nearest(points, position.X, position.Z)
			target = if best then stationParts[best.id] else nil
		end

		local goal = target
		if goal == nil then
			objective(nil)
			lastBearing = nil
			return
		end

		local look = camera.CFrame.LookVector
		local offset = goal.Position - position
		local bearing =
			HudLogic.quantize(HudLogic.bearing(look.X, look.Z, offset.X, offset.Z) + ARROW_STEP / 2, ARROW_STEP)
		local distance = math.floor(Vector2.new(offset.X, offset.Z).Magnitude)
		if bearing ~= lastBearing or distance ~= lastDistance then
			lastBearing, lastDistance = bearing, distance
			objective(table.freeze({ bearing = bearing, distance = distance }))
		end
	end)

	return function()
		connection:Disconnect()
		objective(nil)
	end
end

local RaceHUDController: Loader.Controller = {
	name = "RaceHUDController",
	dependencies = { "UIScaleController" },
}

local unmount: (() -> ())? = nil
local stopObjective: (() -> ())? = nil

local function onRoundState(payload: any)
	endsAt(payload.endsAt)
	local racing = payload.state == "Race"
	if racing and unmount == nil then
		unmount = RaceHUD.mount(UIScaleController, store)
		stopObjective = runObjective()
	elseif not racing and unmount ~= nil then
		(unmount :: () -> ())()
		unmount = nil
		if stopObjective ~= nil then
			stopObjective()
			stopObjective = nil
		end
		-- A new race sends a new route; don't show this one's until then.
		tasks({})
		outstanding = {}
		progress({})
		pending(false)
	end
end

function RaceHUDController:init()
	Net.onClientEvent("RoundState", onRoundState)
	Net.onClientEvent("TaskAssignmentState", onRoute)
	Net.onClientEvent("TaskProgress", function(payload: any)
		progress(payload.progress)
	end)
	Net.onClientEvent("StatusEffectsChanged", onEffects)
	Net.onClientEvent("PowerUpInventoryChanged", onInventory)
	Net.onClientEvent("PowerUpUseResult", onUseResult)
end

function RaceHUDController:start()
	for _, instance in CollectionService:GetTagged("TaskStation") do
		trackStation(instance)
	end
	CollectionService:GetInstanceAddedSignal("TaskStation"):Connect(trackStation)
end

return RaceHUDController
