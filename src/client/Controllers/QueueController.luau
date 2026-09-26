--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The hub's Play button and queue status (P5-1's client half). The
-- rules - which intent a tap sends, what each QueueState says - live in
-- UI/QueueLogic (pure, tested). This file wires them to the remotes,
-- the screen, and the board over the queue pad.
--
-- WHERE: bottom-left, leaving the Primary zone (bottom-right) to the
-- practice power-up slots, which sit where they do in a race. On touch
-- it lifts above Roblox's thumbstick (Layout's ReservedMove zone), so
-- it never blocks movement. Re-placed when the usable rect or input
-- mode changes.
--
-- WHEN: hub servers only (the hub place id; or, while it's unset, a
-- Studio playtest of a place with a Workspace.Hub), and hidden while
-- a round is running.
--
-- THE BOARD: the HubQueueCountdown part over the pad (hub-spec.md)
-- gets a SurfaceGui on its Front face, parented to PlayerGui and
-- adorned to the part, so each player's board shows their own status.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local vide = require(ReplicatedStorage.Packages.Vide)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local C = require(script.Parent.Parent.UI.Components)
local Base = require(script.Parent.Parent.UI.Components.Base)
local Layout = require(script.Parent.Parent.UI.Layout)
local QueueLogic = require(script.Parent.Parent.UI.QueueLogic)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIScaleController = require(script.Parent.UIScaleController)

local source = vide.source
local create = vide.create
local show = vide.show

local CARD_WIDTH = 208 -- reference px
local TICK = 0.5
local BOARD_TAG = "HubQueueCountdown"
local BOARD_PIXELS_PER_STUD = 28

local TONE_INK: { [QueueLogic.Tone]: Color3 } = {
	neutral = Theme.color.ink,
	success = Theme.color.success,
	warning = Theme.color.warning,
}

local state = source(QueueLogic.new())
-- A plain function, not derive(): Vide only allows derive inside a
-- root, and this is read from two (the card and the board).
local function view(): QueueLogic.View
	return QueueLogic.view(state())
end
local roundState = source(nil :: string?)

local function isHubServer(): boolean
	local hubPlaceId = GameConfig.matchmaking.hubPlaceId
	if hubPlaceId == 0 then
		return RunService:IsStudio() and Workspace:FindFirstChild("Hub") ~= nil
	end
	return game.PlaceId == hubPlaceId
end

local function onTap()
	local nextState, intent = QueueLogic.tap(state(), os.clock())
	state(nextState)
	if intent == "Join" then
		Net.fireServer("QueueJoinIntent", {})
	elseif intent == "Leave" then
		Net.fireServer("QueueLeaveIntent", {})
	end
end

-- The card's bottom-left corner, in the ScreenGui's own coordinates (a
-- CoreUISafeInsets ScreenGui starts at the usable rect). Bottom-left
-- of the screen, except on touch, where Roblox's thumbstick owns that
-- corner (ReservedMove): there it sits just above the thumbstick.
local function anchorFor(usable: Layout.Rect, touch: boolean): UDim2
	local margin = Theme.spacing.lg
	if touch then
		for _, zone in Layout.resolveZones(usable) do
			if zone.kind == "ReservedMove" then
				return UDim2.fromOffset(margin, zone.rect.y - usable.y - margin)
			end
		end
	end
	return UDim2.new(0, margin, 1, -margin)
end

local function mountCard()
	local gui = UIScaleController.createScreen("QueueCard", { displayOrder = Theme.displayOrder.hud })
	local usable = source(UIScaleController.getUsableRect())
	UIScaleController.observeUsableRect(function(rect: Layout.Rect)
		usable(rect)
	end)
	local touch = source(false)
	UIScaleController.observeInputMode(function(mode: Enum.PreferredInput)
		touch(mode == Enum.PreferredInput.Touch)
	end)

	vide.root(function()
		local hasText = function(): boolean
			local v = view()
			return v.headline ~= nil or v.detail ~= nil
		end
		local card = create("Frame")({
			Name = "Queue",
			AnchorPoint = Vector2.new(0, 1),
			Position = function()
				return anchorFor(usable(), touch())
			end,
			Size = UDim2.fromOffset(CARD_WIDTH, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Visible = function()
				local round = roundState()
				return round == nil or round == "WaitingForPlayers"
			end,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				VerticalAlignment = Enum.VerticalAlignment.Bottom,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			show(hasText, function()
				return C.Panel({
					name = "Status",
					elevation = 2,
					size = UDim2.fromScale(1, 0),
					automaticSize = Enum.AutomaticSize.Y,
					padding = Theme.spacing.md,
					gap = Theme.spacing.xs,
					layoutOrder = 1,
					children = {
						Base.text("label", {
							Name = "Headline",
							LayoutOrder = 1,
							Size = UDim2.new(1, 0, 0, Theme.type.label.size + Theme.spacing.xs),
							Text = function()
								return view().headline or ""
							end,
							Visible = function()
								return view().headline ~= nil
							end,
							TextColor3 = function()
								return TONE_INK[view().tone]
							end,
						}),
						Base.text("body", {
							Name = "Detail",
							LayoutOrder = 2,
							Size = UDim2.new(1, 0, 0, 2 * Theme.type.body.size + Theme.spacing.xs),
							Text = function()
								return view().detail or ""
							end,
							Visible = function()
								return view().detail ~= nil
							end,
							TextColor3 = Theme.color.inkMuted,
						}),
					} :: { Instance },
				}) :: any
			end) :: any,
			-- Two buttons rather than one relabelled: Button's variant is
			-- fixed at build time, and Play should read as THE action.
			show(function()
				return view().action == "Join"
			end, function()
				return C.Button({
					label = "Play",
					icon = "bolt",
					variant = "primary",
					width = CARD_WIDTH,
					loading = function()
						return view().busy
					end,
					onActivate = onTap,
					layoutOrder = 2,
				}) :: any
			end) :: any,
			show(function()
				return view().action == "Leave"
			end, function()
				return C.Button({
					label = "Leave queue",
					variant = "secondary",
					width = CARD_WIDTH,
					loading = function()
						return view().busy
					end,
					onActivate = onTap,
					layoutOrder = 2,
				}) :: any
			end) :: any,
			Parent = gui,
		}) :: Frame
		UIScaleController.attachScale(card)
	end)
end

local unmountBoard: (() -> ())? = nil

local function mountBoard(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	if unmountBoard ~= nil then
		(unmountBoard :: () -> ())()
	end
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	unmountBoard = vide.root(function()
		local gui = create("SurfaceGui")({
			Name = "QueueBoard",
			Adornee = part,
			Face = Enum.NormalId.Front,
			SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
			PixelsPerStud = BOARD_PIXELS_PER_STUD,
			LightInfluence = 0,
			ResetOnSpawn = false,
			create("TextLabel")({
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				FontFace = Theme.type.headline.font,
				TextScaled = true,
				TextColor3 = function()
					return TONE_INK[view().tone]
				end,
				Text = function()
					return view().board
				end,
				create("UIPadding")({
					PaddingTop = UDim.new(0.15, 0),
					PaddingBottom = UDim.new(0.15, 0),
					PaddingLeft = UDim.new(0.05, 0),
					PaddingRight = UDim.new(0.05, 0),
				}),
			}),
			Parent = playerGui,
		}) :: SurfaceGui
		vide.cleanup(function()
			gui:Destroy()
		end)
	end)
end

local QueueController: Loader.Controller = {
	name = "QueueController",
	dependencies = { "UIScaleController" },
}

function QueueController:init()
	if not isHubServer() then
		return
	end
	Net.onClientEvent("QueueState", function(payload: any)
		state(QueueLogic.apply(state(), payload))
	end)
	Net.onClientEvent("RoundState", function(payload: any)
		if type(payload) == "table" and type(payload.state) == "string" then
			roundState(payload.state)
		end
	end)
end

function QueueController:start()
	if not isHubServer() then
		return
	end
	mountCard()

	-- The board part can stream in after start; take the latest one.
	for _, part in CollectionService:GetTagged(BOARD_TAG) do
		mountBoard(part)
	end
	CollectionService:GetInstanceAddedSignal(BOARD_TAG):Connect(mountBoard)

	task.spawn(function()
		while true do
			task.wait(TICK)
			local current = state()
			local nextState = QueueLogic.tick(current, os.clock())
			if nextState ~= current then
				state(nextState)
			end
		end
	end)
end

return QueueController
