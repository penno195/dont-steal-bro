--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The hub's Play button and queue status (P5-1's client half). The
-- rules - which intent a tap sends, what each QueueState says - live in
-- UI/QueueLogic (pure, tested). This file wires them to the remotes,
-- the screen, and the board over the queue pad.
--
-- PRACTICE (design-decisions.md Q7): a Practice button beside Play and
-- a Party button that opens PartyController's panel. Which join buttons
-- show depends on the party (PartyViewLogic.queueButtons): solo gets
-- both, a party's leader gets Practice only, a member gets neither.
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
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local C = require(script.Parent.Parent.UI.Components)
local Base = require(script.Parent.Parent.UI.Components.Base)
local Icons = require(script.Parent.Parent.UI.Components.Icons)
local Layout = require(script.Parent.Parent.UI.Layout)
local LockerLogic = require(script.Parent.Parent.UI.LockerLogic)
local PartyViewLogic = require(script.Parent.Parent.UI.PartyViewLogic)
local QueueLogic = require(script.Parent.Parent.UI.QueueLogic)
local Theme = require(script.Parent.Parent.UI.Theme)
local MenuController = require(script.Parent.MenuController)
local PartyController = require(script.Parent.PartyController)
local UIScaleController = require(script.Parent.UIScaleController)

local source = vide.source
local create = vide.create
local show = vide.show
local switch = vide.switch
local indexes = vide.indexes

local CARD_WIDTH = 208 -- reference px
local STRIP_TILE = 40 -- reference px
-- How far the status panel tucks under the button below it.
local STATUS_TUCK = 10 -- reference px

local powerUpIds: { string } = {}
for _, entry in PowerUps do
	table.insert(powerUpIds, entry.def.id)
end
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
-- Set by MatchmakingService on a private hub server. Never changes
-- while the server runs, so a plain read is enough.
local function practiceServer(): boolean
	return workspace:GetAttribute("PracticeServer") == true
end

local function view(): QueueLogic.View
	return QueueLogic.view(state(), practiceServer())
end

-- Which join buttons the party allows (design-decisions.md Q7: ranked
-- is solo, and only a party's leader queues it for Practice).
local function buttons(): PartyViewLogic.QueueButtons
	return PartyViewLogic.queueButtons(PartyController.state(), Players.LocalPlayer.UserId, practiceServer())
end
local roundState = source(nil :: string?)

local function isHubServer(): boolean
	local hubPlaceId = GameConfig.matchmaking.hubPlaceId
	if hubPlaceId == 0 then
		return RunService:IsStudio() and Workspace:FindFirstChild("Hub") ~= nil
	end
	return game.PlaceId == hubPlaceId
end

-- `practice`: the Practice button (or a party leader's only button).
-- The server decides what the line really is; a private hub is
-- practice whatever this says.
local function onTap(practice: boolean?)
	local nextState, intent = QueueLogic.tap(state(), os.clock())
	state(nextState)
	if intent == "Join" then
		Net.fireServer("QueueJoinIntent", if practice then { mode = "Practice" } else {})
	elseif intent == "Leave" then
		Net.fireServer("QueueLeaveIntent", {})
	end
end

-- The card's bottom-left corner, in the ScreenGui's own coordinates (a
-- CoreUISafeInsets ScreenGui starts at the usable rect). Bottom-left
-- of the screen, except on touch, where Roblox's thumbstick owns that
-- corner (ReservedMove): there it sits just above the thumbstick, or,
-- when the card is taller than the room above it (a landscape phone:
-- it grew up under Roblox's top bar on an iPhone), on the bottom edge
-- just right of the thumbstick. `height` is the card's rendered height.
local function anchorFor(usable: Layout.Rect, touch: boolean, height: number): UDim2
	local margin = Theme.spacing.lg
	if touch then
		for _, zone in Layout.resolveZones(usable) do
			if zone.kind == "ReservedMove" then
				local above = zone.rect.y - usable.y - margin
				if height <= above - margin then
					return UDim2.fromOffset(margin, above)
				end
				return UDim2.new(0, zone.rect.x - usable.x + zone.rect.width + margin, 1, -margin)
			end
		end
	end
	return UDim2.new(0, margin, 1, -margin)
end

-- THE LOADOUT STRIP, above the status while queued (design-decisions.md
-- Q8, "the Locker and choosing a loadout"): what goes into the race, or
-- last round's picks with a one-tap "Same as last round". Nothing is
-- asked of a player who doesn't care; the loadout never re-arms itself.

local STRIP_CAPTION: { [LockerLogic.StripMode]: string } = {
	Set = "Taking into the race",
	Offer = "Last round",
	None = "No power-ups picked",
}

local function stripTile(tile: () -> LockerLogic.StripTile, index: number, offer: () -> boolean): Instance
	local id = function(): string?
		return tile().powerUpId
	end
	local ink = function(): Color3
		return if offer() then Theme.color.inkMuted else Theme.color.ink
	end
	local icons: { [string]: any } = {}
	for _, powerUpId in powerUpIds do
		icons[powerUpId] = function()
			return Icons.view(powerUpId, STRIP_TILE - 12, ink)
		end
	end
	return create("Frame")({
		Name = "Tile" .. index,
		LayoutOrder = index,
		Size = UDim2.fromOffset(STRIP_TILE, STRIP_TILE),
		BackgroundColor3 = Base.STAGE_BACKGROUND,
		Base.corner(Theme.radius.sm),
		Base.stage({ rim = Theme.color.line, thickness = 1 }),
		create("Frame")({
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(STRIP_TILE - 12, STRIP_TILE - 12),
			BackgroundTransparency = 1,
			switch(id)(icons) :: any,
		}),
		-- Owned stock always carries its count. Red 0: last round's
		-- pick has run out, and "Same as last round" will leave it empty.
		Base.text("caption", {
			Name = "Count",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -2, 1, 0),
			Size = UDim2.fromOffset(STRIP_TILE, Theme.type.caption.size),
			Visible = function()
				return id() ~= nil
			end,
			Text = function()
				return if tile().stock > 0 then "×" .. tile().stock else "0"
			end,
			TextColor3 = function()
				return if tile().stock > 0 then Theme.color.ink else Theme.color.danger
			end,
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
	})
end

local function loadoutStrip(): Instance
	local strip = function(): LockerLogic.Strip?
		local s = MenuController.storeState()
		return if s then LockerLogic.strip(s :: any) else nil
	end
	local tiles = function(): { LockerLogic.StripTile }
		local s = strip()
		return if s then s.tiles else {}
	end
	local offer = function(): boolean
		local s = strip()
		return s ~= nil and s.mode == "Offer"
	end
	local inner = CARD_WIDTH - 2 * Theme.spacing.md

	return C.Panel({
		name = "Loadout",
		elevation = 2,
		size = UDim2.fromScale(1, 0),
		automaticSize = Enum.AutomaticSize.Y,
		padding = Theme.spacing.md,
		gap = Theme.spacing.xs,
		layoutOrder = 0,
		children = {
			Base.text("caption", {
				Name = "Caption",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, Theme.type.caption.size + Theme.spacing.xxs),
				Text = function()
					local s = strip()
					return if s then STRIP_CAPTION[s.mode] else ""
				end,
				TextColor3 = Theme.color.inkMuted,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			create("Frame")({
				Name = "Row",
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, Theme.touch.iconButton),
				BackgroundTransparency = 1,
				create("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Theme.spacing.xs),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				indexes(tiles, function(tile: () -> LockerLogic.StripTile, index: number)
					return stripTile(tile, index, offer)
				end) :: any,
				C.IconButton({
					icon = "locker",
					label = "Locker",
					variant = "ghost",
					onActivate = MenuController.openLocker,
					layoutOrder = 10,
				}),
			}),
			show(offer, function()
				return C.Button({
					label = "Same as last round",
					variant = "secondary",
					width = inner,
					onActivate = MenuController.repeatLastLoadout,
					layoutOrder = 3,
				}) :: any
			end) :: any,
		} :: { Instance },
	})
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
		-- Idle with nothing from the server to say: why a button is
		-- missing ("Parties play Practice only."), if one is.
		local detail = function(): string?
			local v = view()
			if v.action == "Join" and state().message == nil then
				return buttons().note or v.detail
			end
			return v.detail
		end
		local hasText = function(): boolean
			return view().headline ~= nil or detail() ~= nil
		end
		local joining = function(): boolean
			return view().action == "Join"
		end
		-- The full-width primary: Play, or Practice for a party leader,
		-- who has no ranked button (ranked is solo).
		local mainButton = function(): boolean
			local b = buttons()
			return joining() and (b.play or b.practice)
		end
		local hasButton = function(): boolean
			return mainButton() or view().action == "Leave"
		end
		local practiceBeside = function(): boolean
			local b = buttons()
			return joining() and b.play and b.practice
		end
		-- Rendered height (after the UIScale); moving the card never
		-- resizes it, so placing from it can't feed back.
		local height = source(0)
		local card = create("Frame")({
			Name = "Queue",
			AnchorPoint = Vector2.new(0, 1),
			Position = function()
				return anchorFor(usable(), touch(), height())
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
			show(function()
				return view().action == "Leave" and MenuController.storeState() ~= nil
			end, loadoutStrip) :: any,
			-- The status panel and the button it's about, the panel tucked
			-- under the button's top edge so they read as one piece.
			create("Frame")({
				Name = "Stack",
				LayoutOrder = 1,
				Size = UDim2.fromOffset(CARD_WIDTH, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				create("UIListLayout")({
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Left,
					Padding = UDim.new(0, -STATUS_TUCK),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				show(hasText, function()
					local panel = C.Panel({
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
									return detail() or ""
								end,
								Visible = function()
									return detail() ~= nil
								end,
								TextColor3 = Theme.color.inkMuted,
							}),
							-- The strip the button below covers.
							create("Frame")({
								Name = "Tuck",
								LayoutOrder = 3,
								Size = UDim2.fromOffset(0, STATUS_TUCK),
								BackgroundTransparency = 1,
								Visible = hasButton,
							}),
						} :: { Instance },
					}) :: Frame
					panel.ZIndex = 1
					return panel
				end) :: any,
				-- Two buttons rather than one relabelled: Button's variant is
				-- fixed at build time, and Play should read as THE action.
				show(mainButton, function()
					local button = C.Button({
						label = function(): string
							return if buttons().play then "Play" else "Practice"
						end,
						icon = "bolt",
						variant = "primary",
						width = CARD_WIDTH,
						loading = function()
							return view().busy
						end,
						onActivate = function()
							onTap(not buttons().play)
						end,
						layoutOrder = 2,
					}) :: GuiObject
					button.ZIndex = 2
					return button
				end) :: any,
				show(function()
					return view().action == "Leave"
				end, function()
					local button = C.Button({
						label = "Leave queue",
						variant = "secondary",
						width = CARD_WIDTH,
						loading = function()
							return view().busy
						end,
						onActivate = onTap,
						layoutOrder = 3,
					}) :: GuiObject
					button.ZIndex = 2
					return button
				end) :: any,
			}),
			-- Practice (when Play is the main button) and the party panel.
			-- Gone once the match is committed, like every other button.
			show(function()
				return view().action ~= nil
			end, function()
				return create("Frame")({
					Name = "Secondary",
					LayoutOrder = 3,
					Size = UDim2.fromOffset(CARD_WIDTH, Theme.touch.iconButton),
					BackgroundTransparency = 1,
					create("UIListLayout")({
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Theme.spacing.sm),
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
					show(practiceBeside, function()
						return C.Button({
							label = "Practice",
							variant = "secondary",
							compact = true,
							width = CARD_WIDTH - Theme.touch.iconButton - Theme.spacing.sm,
							disabled = function()
								return view().busy
							end,
							onActivate = function()
								onTap(true)
							end,
							layoutOrder = 1,
						}) :: any
					end) :: any,
					C.IconButton({
						icon = "party",
						label = "Party",
						variant = "secondary",
						onActivate = PartyController.openPanel,
						layoutOrder = 2,
					}),
				}) :: any
			end) :: any,
			Parent = gui,
		}) :: Frame
		card:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			height(card.AbsoluteSize.Y)
		end)
		height(card.AbsoluteSize.Y)
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
	dependencies = { "UIScaleController", "MenuController", "PartyController" },
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
