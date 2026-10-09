--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of tasks-catalogue.md #13, `airlock-cycle` - see
-- src/server/TaskHandlers/AirlockCycle.luau for the server half. Built on
-- UI/TaskViewBase like ReactorSync.luau, and drawn from the same shared
-- sweep maths (src/shared/TimingLogic.luau) on the same attempt clock.
--
-- A steel airlock channel (art: UI/TaskArt) with the open doorway fixed
-- on it, marked by yellow arrows above and below. Two red hazard lights
-- travel the channel together with a lit green window between them; tap
-- SEAL while the doorway is inside the window. A good seal slams the
-- door's shutter down and the window flashes; a bad one flashes the
-- channel red, and after a beat the window sweeps again.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local Env = require(script.Parent.Parent.UI.Components.Env)
local TaskArt = require(script.Parent.Parent.UI.TaskArt)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)
local Theme = require(script.Parent.Parent.UI.Theme)
local TimingLogic = require(ReplicatedStorage.Shared.TimingLogic)

local create = vide.create
local source = vide.source

type Challenge = {
	sweepStart: number,
	period: number,
	gapHalfWidth: number,
	door: number,
}

type Feedback = {
	sealed: boolean,
	gapAt: number,
	sweepStart: number?,
}

-- Reference px; the art is drawn at 2x these. layout() scales the panel.
local TRACK = Vector2.new(320, 150)
-- The channel inside the hazard stripes, on the track art.
local CHANNEL_POS = Vector2.new(23, 32)
local CHANNEL = Vector2.new(274, 86)
local BUTTON = Vector2.new(290, 80)
local GAP = Theme.spacing.sm
local WIDTH = TRACK.X
local HEIGHT = TRACK.Y + GAP + BUTTON.Y
-- The channel's ends are padded so the lights stay visible as the window
-- reaches 0 or 1 (its edges overhang it by gapHalfWidth).
local INSET = 0.12
local DOOR_WIDTH = 26
local SHUTTER_RAISED = 0.7 -- share of the shutter hidden above the doorway
local LIGHT = 20
local VERDICT_TIMEOUT = 1 -- see ReactorSync.luau
local MISS_FLASH = 0.35

local WINDOW = Color3.fromHex("#3CCB7F")
local HAZARD = Color3.fromHex("#FF3B30")
local DOORWAY = Color3.fromHex("#05080C")
local DOOR_FRAME = Color3.fromHex("#C9D1DB")
local ARROW = Color3.fromHex("#FFC21A")
local BUTTON_COLOUR = Color3.fromHex("#3BA7FF")

-- Per-attempt feedback handlers, keyed by the attempt's ctx (see
-- FuseRewire.luau for why onProgress can't reach the sources directly).
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

local function trackX(pos: number): number
	return INSET + pos * (1 - 2 * INSET)
end

return TaskViewBase.define({
	taskId = "airlock-cycle",
	title = "Airlock Cycle",
	explainer = "Tap SEAL when the door is inside the green window between the two red lights.",
	contentSize = Vector2.new(WIDTH, HEIGHT),

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local openedAt = os.clock()
		local function clock(): number
			return os.clock() - openedAt
		end

		local sweepStart = challenge.sweepStart
		local half = challenge.gapHalfWidth
		local gap = source(0)
		local frozenAt: number? = nil
		local sealed = source(false)
		local missFlash = source(false)
		local missSerial = 0

		local conn = RunService.Heartbeat:Connect(function()
			if frozenAt ~= nil and clock() - frozenAt > VERDICT_TIMEOUT then
				frozenAt = nil
			end
			if frozenAt == nil and not sealed() then
				gap(TimingLogic.position(clock(), sweepStart, challenge.period))
			end
		end)
		vide.cleanup(function()
			conn:Disconnect()
		end)

		handlers[ctx] = function(feedback: Feedback)
			frozenAt = nil
			gap(feedback.gapAt)
			if feedback.sealed then
				sealed(true)
				ctx.setStatus("Sealed!", "Good")
				return
			end
			if feedback.sweepStart ~= nil then
				sweepStart = feedback.sweepStart
			end
			missSerial += 1
			local mine = missSerial
			missFlash(true)
			task.delay(MISS_FLASH, function()
				if mine == missSerial then
					missFlash(false)
				end
			end)
			ctx.setStatus("Bad seal - try again", "Bad")
			ctx.cue("Bad")
		end

		ctx.setStatus("Seal the door in the green")

		local function onTap()
			local now = clock()
			if sealed() or frozenAt ~= nil or now <= sweepStart then
				return
			end
			frozenAt = now
			ctx.submit("TimingSubmit", { at = now })
		end

		-- The lights go green once the door is sealed.
		local function light(): Color3
			return if sealed() then WINDOW else HAZARD
		end

		local function edge(side: number): Instance
			local x = function()
				return UDim2.fromScale(trackX(gap() + side * half), 0.5)
			end
			return create("Frame")({
				Name = if side < 0 then "HazardLeft" else "HazardRight",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = x,
				Size = UDim2.new(0, LIGHT, 1, 0),
				ZIndex = 4,
				TaskArt.glow({
					size = LIGHT * 2.4,
					Position = UDim2.fromScale(0.5, 0.5),
					colour = light,
					transparency = 0.35,
					ZIndex = 4,
				}),
				create("Frame")({
					Name = "Beam",
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.fromScale(0.5, 0),
					Size = UDim2.new(0, 4, 1, 0),
					BorderSizePixel = 0,
					BackgroundColor3 = light,
					ZIndex = 4,
				}),
				TaskArt.lamp({
					size = LIGHT,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					colour = light,
					ZIndex = 5,
				}),
			})
		end

		-- The door's shutter, mostly raised (its foot shows, so the doorway
		-- reads as a door) until a good seal slams it down.
		local shutter = create("ImageLabel")({
			Name = "Shutter",
			BackgroundTransparency = 1,
			Image = TaskArt.image.airlockDoor,
			ScaleType = Enum.ScaleType.Stretch,
			Position = UDim2.fromScale(0, -SHUTTER_RAISED),
			Size = UDim2.fromScale(1, 1),
			ZIndex = 3,
		}) :: ImageLabel
		vide.effect(function()
			if sealed() then
				local tween = if Env.reducedMotion()
					then TweenInfo.new(0)
					else TweenInfo.new(0.18, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
				TweenService:Create(shutter, tween, { Position = UDim2.fromScale(0, 0) }):Play()
			end
		end)

		local channel = create("Frame")({
			Name = "Channel",
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Position = UDim2.fromOffset(CHANNEL_POS.X, CHANNEL_POS.Y),
			Size = UDim2.fromOffset(CHANNEL.X, CHANNEL.Y),
			-- The window between the lights, lit so it reads as "safe".
			create("Frame")({
				Name = "Window",
				AnchorPoint = Vector2.new(0.5, 0.5),
				BorderSizePixel = 0,
				Position = function()
					return UDim2.fromScale(trackX(gap()), 0.5)
				end,
				Size = UDim2.fromScale(half * 2 * (1 - 2 * INSET), 1),
				BackgroundColor3 = WINDOW,
				BackgroundTransparency = function()
					return if sealed() then 0.4 else 0.6
				end,
				ZIndex = 1,
			}),
			create("Frame")({
				Name = "Doorway",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(trackX(challenge.door), 0),
				Size = UDim2.new(0, DOOR_WIDTH, 1, 0),
				BackgroundColor3 = DOORWAY,
				BackgroundTransparency = 0.15,
				ClipsDescendants = true,
				ZIndex = 2,
				create("UIStroke")({ Color = DOOR_FRAME, Thickness = 3 }),
				shutter,
			}),
			edge(-1),
			edge(1),
			create("Frame")({
				Name = "MissFlash",
				Size = UDim2.fromScale(1, 1),
				BorderSizePixel = 0,
				BackgroundColor3 = Theme.color.danger,
				BackgroundTransparency = function()
					return if missFlash() then 0.5 else 1
				end,
				ZIndex = 6,
			}),
		}) :: Frame

		local function arrow(below: boolean): Instance
			return Base.text("label", {
				Name = if below then "ArrowBelow" else "ArrowAbove",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(
					CHANNEL_POS.X + CHANNEL.X * trackX(challenge.door),
					if below then CHANNEL_POS.Y + CHANNEL.Y + 15 else CHANNEL_POS.Y - 16
				),
				Size = UDim2.fromOffset(24, 16),
				Text = if below then "▲" else "▼",
				TextColor3 = ARROW,
				ZIndex = 2,
				create("UIStroke")({ Color = Color3.fromHex("#0E1015"), Thickness = 1.5 }),
			})
		end

		local track = create("ImageLabel")({
			Name = "Track",
			LayoutOrder = 1,
			BackgroundTransparency = 1,
			Image = TaskArt.image.airlockTrack,
			Size = UDim2.fromOffset(TRACK.X, TRACK.Y),
			{ channel :: Instance, arrow(false), arrow(true) },
		}) :: ImageLabel

		local button = Base.interactive({
			name = "SealButton",
			size = BUTTON,
			radius = UDim.new(0, 20),
			onActivate = onTap,
			visual = TaskArt.button("SEAL", BUTTON_COLOUR),
		})
		button.LayoutOrder = 2

		local panel = create("Frame")({
			Name = "Panel",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(WIDTH, HEIGHT),
			create("UIListLayout")({
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, GAP),
			}),
			track,
			button,
		}) :: Frame

		local fit = create("UIScale")({ Parent = panel }) :: UIScale
		local function layout()
			local s = Env.scale()
			local size = ctx.area.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 or s <= 0 then
				return
			end
			fit.Scale = math.min(size.X / s / WIDTH, size.Y / s / HEIGHT, 1.3)
		end
		local areaChanged = ctx.area:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		vide.cleanup(function()
			areaChanged:Disconnect()
		end)
		vide.effect(function()
			Env.scale() -- re-lay on a scale change too
			task.defer(layout)
		end)

		return { panel :: Instance }
	end,

	onProgress = function(ctx, feedback)
		local handle = handlers[ctx]
		if handle ~= nil and type(feedback) == "table" then
			handle(feedback :: Feedback)
		end
	end,
})
