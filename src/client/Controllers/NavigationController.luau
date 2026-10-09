--!strict
-- Navigation's client half (design-decisions.md Q8, "Navigation"): the
-- toggle beside the compass, the buy sheet it opens with nothing to
-- spend, and the path line to the nearest unfinished station.
--
-- The client only ever asks. NavigationToggle says "on" or "off"; the
-- server decides whether that spends a round or needs a purchase, and
-- answers with NavigationState. A round bought from the sheet switches
-- Navigation on server-side (NavigationService's onGranted), so the
-- sheet just waits for that "On" and closes.
--
-- The line is drawn only here, on the owner's client, from waypoints
-- the server sends to this player alone (NavigationPath). Nobody else
-- can see it, or tell that anyone is using it.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local vide = require(ReplicatedStorage.Packages.Vide)

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local PathLogic = require(ReplicatedStorage.Shared.PathLogic)
local StoreConfig = require(ReplicatedStorage.Shared.Config.Store)
local C = require(script.Parent.Parent.UI.Components)
local Modal = require(script.Parent.Parent.UI.Components.Modal)
local NavigationViewLogic = require(script.Parent.Parent.UI.NavigationViewLogic)
local Theme = require(script.Parent.Parent.UI.Theme)
local MenuController = require(script.Parent.MenuController)

local source = vide.source

-- How long the toggle shows "waiting" with no answer before it gives up.
local ANSWER_TIMEOUT = 3
-- How long a purchase spinner waits for the round to switch on.
local PURCHASE_TIMEOUT = 30

-- The line. Dots at waist height, one every DOT_SPACING studs, growing
-- and brightening as a pulse passes; a pulse every PULSE_WAVELENGTH
-- studs, moving at PULSE_SPEED towards the station.
local DOT_HEIGHT = 2.6
local DOT_SPACING = 2.5
local MAX_DOTS = 120 -- 300 studs of path; further than that just stops
local DOT_SIZE = 0.4
local DOT_PEAK = 0.85
local DOT_TRANSPARENCY = 0.45 -- between pulses; 0 at a peak
local PULSE_SPEED = 22
local PULSE_WAVELENGTH = 20
local SMOOTH_PASSES = 3 -- corner-cutting rounds; more = wider curves
local SMOOTH_STEP = 1.5 -- studs between the points it cuts, which caps how wide
local RESHAPE_SECONDS = 0.15 -- how often the dots re-anchor to the player
-- How far down to look for the floor under a waypoint (NavNodes and
-- station parts sit at whatever height they were placed).
local FLOOR_REACH = 14

local selfId = Players.LocalPlayer.UserId

-- ===== static config =========================================================

local items: { NavigationViewLogic.Item } = {}
local keyByAssetId: { [number]: string } = {}
for _, entry in StoreConfig do
	local def = entry.def :: any
	if NavigationViewLogic.sellsRound(def) or NavigationViewLogic.sellsPass(def) then
		table.insert(items, def)
		if def.assetId ~= 0 then
			keyByAssetId[def.assetId] = def.key
		end
	end
end
local offered = NavigationViewLogic.offered(items)

-- ===== state =================================================================

export type Toggle = "Off" | "On" | "Waiting"

local on = source(false)
local waiting = source(false)
local waitToken = 0
local buyingKey = source(nil :: string?) -- the round being bought from the sheet
local buyToken = 0
local closeSheet: (() -> ())? = nil

local function stopWaiting()
	waitToken += 1
	waiting(false)
end

local function hideSheet()
	buyToken += 1
	buyingKey(nil)
	if closeSheet ~= nil then
		local close = closeSheet :: () -> ()
		closeSheet = nil
		close()
	end
end

local function buy(key: string)
	if buyingKey() ~= nil then
		return
	end
	buyingKey(key)
	buyToken += 1
	local token = buyToken
	Net.fireServer("StorePurchaseIntent", { key = key })
	-- A receipt that never lands mustn't leave the sheet spinning; the
	-- round is kept for the next race if it lands late (Q8).
	task.delay(PURCHASE_TIMEOUT, function()
		if buyToken == token then
			buyingKey(nil)
		end
	end)
end

local function openSheet()
	if closeSheet ~= nil then
		return
	end
	local storeState = MenuController.storeState()
	local currency = if storeState then storeState.currency else nil
	local offers = NavigationViewLogic.offers(items, currency)
	if #offers == 0 then
		C.Toast.show("Navigation isn't on sale right now.", "warning")
		return
	end

	local actions: { Modal.Action } = {}
	for _, offer in offers do
		table.insert(actions, {
			label = offer.label,
			variant = if offer.coins then "secondary" else "primary",
			disabled = function(): boolean
				local busy = buyingKey()
				return not offer.affordable or (busy ~= nil and busy ~= offer.key)
			end,
			loading = function(): boolean
				return buyingKey() == offer.key
			end,
			onActivate = function()
				buy(offer.key)
			end,
		})
	end

	local body = "A path to your nearest unfinished station, for the rest of this round."
	if currency ~= nil then
		body ..= string.format(" You have %d coins.", currency)
	end
	closeSheet = Modal.open({
		title = "Navigation",
		body = body,
		actions = actions,
		dismissible = true,
		onDismiss = function()
			-- Mid-purchase the Roblox prompt is open on top; the sheet
			-- stays until it settles.
			if buyingKey() == nil then
				hideSheet()
			end
		end,
	})
end

-- ===== the path line =========================================================
-- Waist-high dots along the route, its corners rounded off, with a pulse
-- running from the player towards the station (owner, 2026-10-08). The
-- dots are pooled: a new route or a step forward moves them rather than
-- rebuilding them. A Highlight drawn on top of everything keeps them
-- showing, faintly, through a floor or a wall in the way.

local lineModel: Model? = nil
local pool: { BasePart } = {}
local dotAlong: { number } = {} -- each shown dot's distance down the path
local route: { Vector3 } = {} -- the server's waypoints, at waist height
local reshapeAt = 0

local function rootOf(): (BasePart?, Humanoid?)
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil, nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?, character:FindFirstChildOfClass("Humanoid")
end

local function waist(): Vector3?
	local root, humanoid = rootOf()
	if root == nil then
		return nil
	end
	local drop = root.Size.Y / 2 + (if humanoid then humanoid.HipHeight else 2)
	return root.Position - Vector3.new(0, drop - DOT_HEIGHT, 0)
end

local function toPoint(v: Vector3): NavigationViewLogic.Point
	return { x = v.X, y = v.Y, z = v.Z }
end

local function clearLine()
	route = {}
	table.clear(dotAlong)
	if lineModel ~= nil then
		lineModel:Destroy()
		lineModel = nil
	end
	for _, part in pool do
		part:Destroy() -- spares sit outside the model
	end
	table.clear(pool)
end

local function ensureModel(): Model
	if lineModel ~= nil then
		return lineModel
	end
	local model = Instance.new("Model")
	model.Name = "NavigationPath"
	local highlight = Instance.new("Highlight")
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = Theme.color.brand
	highlight.FillTransparency = 0.6
	highlight.OutlineTransparency = 1
	highlight.Adornee = model
	highlight.Parent = model
	model.Parent = Workspace
	lineModel = model
	return model
end

local function dot(model: Model): BasePart
	local part = Instance.new("Part")
	part.Name = "Dot"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * DOT_SIZE
	part.Material = Enum.Material.Neon
	part.Color = Theme.color.brand
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = model
	return part
end

-- Lays the dots out from where the player stands now.
local function reshape()
	local from = waist()
	if from == nil or #route == 0 then
		return
	end
	-- Start from where the player is along the route, so the part
	-- already run is dropped and the line never leads back to its start.
	local routePoints: { NavigationViewLogic.Point } = {}
	for _, point in route do
		table.insert(routePoints, toPoint(point))
	end
	local here = toPoint(from)
	local closest = PathLogic.closest(here, routePoints[1], routePoints)
	local points = { here }
	for i = math.max(closest.segment, 1), #routePoints do
		table.insert(points, routePoints[i])
	end
	-- Rounded on a dense copy, so a corner is cut by a stud or so at
	-- most and the curve can't swing through the wall it turns round.
	local dense = {}
	for _, entry in NavigationViewLogic.dots(points, SMOOTH_STEP, math.huge) do
		table.insert(dense, entry.point)
	end
	table.insert(dense, points[#points])
	local dots = NavigationViewLogic.dots(NavigationViewLogic.smooth(dense, SMOOTH_PASSES), DOT_SPACING, MAX_DOTS + 1)

	local model = ensureModel()
	local parts: { BasePart } = {}
	local cframes: { CFrame } = {}
	table.clear(dotAlong)
	-- The first dot is at the player's own waist; skip it.
	for i = 2, #dots do
		local n = i - 1
		if n > #pool then
			table.insert(pool, dot(model))
		end
		local part = pool[n]
		part.Parent = model
		local p = dots[i].point
		table.insert(parts, part)
		table.insert(cframes, CFrame.new(p.x, p.y, p.z))
		dotAlong[n] = dots[i].along
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	-- Spares come out of the model, so the Highlight doesn't draw them.
	for n = math.max(#dots, 1), #pool do
		pool[n].Parent = nil
	end
end

local function animate(now: number)
	for n, along in dotAlong do
		local lit = NavigationViewLogic.pulse(along, now, PULSE_SPEED, PULSE_WAVELENGTH)
		local part = pool[n]
		part.Size = Vector3.one * (DOT_SIZE + (DOT_PEAK - DOT_SIZE) * lit)
		part.Transparency = DOT_TRANSPARENCY * (1 - lit)
	end
end

-- The floor under a waypoint, or the waypoint itself over a gap.
local function grounded(point: Vector3, params: RaycastParams): Vector3
	local hit = Workspace:Raycast(point + Vector3.new(0, 2, 0), Vector3.new(0, -FLOOR_REACH, 0), params)
	return if hit then hit.Position else point
end

local function setRoute(points: { Vector3 })
	if #points == 0 then
		clearLine()
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	if lineModel ~= nil then
		table.insert(exclude, lineModel)
	end
	params.FilterDescendantsInstances = exclude

	route = {}
	for _, point in points do
		table.insert(route, grounded(point, params) + Vector3.new(0, DOT_HEIGHT, 0))
	end
	reshape()
end

local function onPath(payload: any)
	local points: { Vector3 } = {}
	if type(payload) == "table" and type(payload.points) == "table" then
		for _, point in payload.points do
			if typeof(point) == "Vector3" then
				table.insert(points, point)
			end
		end
	end
	if on() then
		setRoute(points)
	else
		clearLine()
	end
end

-- ===== the server's answer ===================================================

local function onState(payload: any)
	local state = NavigationViewLogic.read(payload)
	if state == nil then
		return
	end
	stopWaiting()
	on(state.on)
	if not state.on then
		clearLine()
	end
	if state.status == "NeedsPurchase" then
		openSheet()
	elseif state.status == "On" or state.status == "Off" then
		hideSheet()
	elseif state.status == "Unavailable" then
		hideSheet()
		C.Toast.show("Navigation isn't available right now.", "warning")
	end
end

local NavigationController: Loader.Controller = {
	name = "NavigationController",
	dependencies = { "UIScaleController", "MenuController" },

	-- For RaceHUDController's toggle: nil hides it (nothing on sale).
	toggle = function(): Toggle?
		if not offered then
			return nil
		end
		return if waiting() then "Waiting" elseif on() then "On" else "Off"
	end,

	press = function()
		if not offered or waiting() then
			return
		end
		waiting(true)
		waitToken += 1
		local token = waitToken
		Net.fireServer("NavigationToggle", { on = not on() })
		task.delay(ANSWER_TIMEOUT, function()
			if waitToken == token then
				waiting(false)
			end
		end)
	end,
}

function NavigationController:init()
	Net.onClientEvent("NavigationState", onState)
	Net.onClientEvent("NavigationPath", onPath)

	-- The sheet's purchases. Its own spinner only: the round itself
	-- arrives as NavigationState "On".
	Net.onClientEvent("StorePurchaseResult", function(payload: any)
		if type(payload) ~= "table" or payload.key ~= buyingKey() then
			return
		end
		if payload.status == "Prompted" or payload.status == "Granted" then
			return
		end
		buyToken += 1
		buyingKey(nil)
		local message = if type(payload.message) == "string" and payload.message ~= ""
			then payload.message
			else "Couldn't buy Navigation. Please try again."
		C.Toast.show(message, "danger")
	end)
	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, purchased: boolean)
			if userId == selfId and not purchased and keyByAssetId[productId] == buyingKey() then
				buyToken += 1
				buyingKey(nil) -- a cancel isn't an error; say nothing
			end
		end
	)

	-- Leaving the race takes everything down, whatever the server said.
	Net.onClientEvent("RoundState", function(payload: any)
		if type(payload) == "table" and payload.state ~= "Race" then
			stopWaiting()
			on(false)
			hideSheet()
			clearLine()
		end
	end)
end

function NavigationController:start()
	-- The dots re-anchor to the player a few times a second, and pulse
	-- every frame.
	RunService.RenderStepped:Connect(function()
		if #route == 0 then
			return
		end
		local now = os.clock()
		if now >= reshapeAt then
			reshapeAt = now + RESHAPE_SECONDS
			reshape()
		end
		animate(now)
	end)
end

return NavigationController
