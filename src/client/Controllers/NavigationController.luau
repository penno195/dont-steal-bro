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

-- The line: how wide, how far above the floor, and how far down to look
-- for the floor under a waypoint (NavNodes and station parts sit at
-- whatever height they were placed).
local LINE_WIDTH = 0.7
local LINE_LIFT = 0.3
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

local lineFolder: Folder? = nil
local linePoints: { Attachment } = {} -- on the terrain: an attachment needs a part
local startAttachment: Attachment? = nil

local function clearLine()
	if lineFolder ~= nil then
		lineFolder:Destroy()
		lineFolder = nil
	end
	for _, attachment in linePoints do
		attachment:Destroy()
	end
	table.clear(linePoints)
	startAttachment = nil
end

local function rootOf(): (BasePart?, Humanoid?)
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil, nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?, character:FindFirstChildOfClass("Humanoid")
end

local function feet(): Vector3?
	local root, humanoid = rootOf()
	if root == nil then
		return nil
	end
	local drop = root.Size.Y / 2 + (if humanoid then humanoid.HipHeight else 2)
	return root.Position - Vector3.new(0, drop - LINE_LIFT, 0)
end

-- The floor under a waypoint, or the waypoint itself over a gap.
local function grounded(point: Vector3, params: RaycastParams): Vector3
	local hit = Workspace:Raycast(point + Vector3.new(0, 2, 0), Vector3.new(0, -FLOOR_REACH, 0), params)
	return if hit then hit.Position + Vector3.new(0, LINE_LIFT, 0) else point
end

local function drawLine(points: { Vector3 })
	clearLine()
	if #points == 0 then
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
	params.FilterDescendantsInstances = exclude

	local folder = Instance.new("Folder")
	folder.Name = "NavigationPath"
	local terrain = Workspace.Terrain
	local color = ColorSequence.new(Theme.color.brand)

	local previous: Attachment? = nil
	local function addPoint(position: Vector3): Attachment
		local attachment = Instance.new("Attachment")
		attachment.Name = "NavigationPoint"
		attachment.Parent = terrain
		attachment.WorldPosition = position
		table.insert(linePoints, attachment)
		if previous ~= nil then
			local beam = Instance.new("Beam")
			beam.Attachment0 = previous
			beam.Attachment1 = attachment
			beam.Color = color
			beam.Width0 = LINE_WIDTH
			beam.Width1 = LINE_WIDTH
			beam.FaceCamera = true
			beam.LightEmission = 1
			beam.Transparency = NumberSequence.new(0.15)
			beam.Segments = 1
			beam.Parent = folder
		end
		previous = attachment
		return attachment
	end

	startAttachment = addPoint(feet() or grounded(points[1], params))
	for _, point in points do
		addPoint(grounded(point, params))
	end
	folder.Parent = Workspace
	lineFolder = folder
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
		drawLine(points)
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
	-- The line's first point follows the player's feet.
	RunService.RenderStepped:Connect(function()
		local start = startAttachment
		if start == nil then
			return
		end
		local position = feet()
		if position ~= nil then
			start.WorldPosition = position
		end
	end)
end

return NavigationController
