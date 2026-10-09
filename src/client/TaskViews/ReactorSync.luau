--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of the Timing reference task (tasks-catalogue.md #11,
-- `reactor-sync`) - see src/server/TaskHandlers/ReactorSync.luau for the
-- server half. Built on UI/TaskViewBase like PressureValve.luau: the shell
-- owns the window, close, timer and status line; this file owns the
-- gauge and the SYNC button.
--
-- A reactor's CORE OUTPUT gauge (art: UI/TaskArt): a needle swings
-- across a 150-degree arc of tick lamps, and the ticks inside the green
-- band are lit, with a bright marker at each of its exact edges (the
-- ticks alone would round the band to a tick). Track position 0..1 maps
-- linearly to the arc, so "inside the band" on screen is exactly
-- TimingLogic.within.
--
-- The needle is drawn by TimingLogic.position - the SAME function the
-- server checks the stop against - on this attempt's clock (seconds since
-- the view opened, i.e. since the challenge landed). A tap sends that
-- clock reading (TimingSubmit), freezes the needle where it stopped, and
-- waits for the server's verdict: the next sweep's start, speed and band
-- come back in its feedback. Three lamps count syncs; three red lamps are
-- the lives a miss costs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
	bandCenter: number,
	bandHalfWidth: number,
	hitsNeeded: number,
	lives: number,
}

type Feedback = {
	hit: boolean,
	stoppedAt: number,
	hits: number,
	lives: number,
	reset: boolean,
	sweepStart: number,
	period: number,
	bandCenter: number,
}

-- Reference px; the art is drawn at 2x these. layout() scales the panel.
local GAUGE = Vector2.new(320, 220)
local PIVOT = Vector2.new(160, 165) -- the needle's hub on the gauge
local ARC_RADIUS = 115
local ARC_DEGREES = 75 -- either side of straight up
local TICKS = 61
local TICK = Vector2.new(4, 16)
local NEEDLE = Vector2.new(32, 240) -- hub at the image's centre
local LAMP = 28
local LIFE = 20
local ROW_HEIGHT = 30
local BUTTON = Vector2.new(290, 80)
local GAP = Theme.spacing.sm
local WIDTH = GAUGE.X
local HEIGHT = GAUGE.Y + GAP + ROW_HEIGHT + GAP + BUTTON.Y
-- A tap with no answer after this long un-freezes the needle (a dropped
-- stop - too early, or the server had no honest time left for it).
local VERDICT_TIMEOUT = 1

local TICK_OFF = Color3.fromHex("#22364A")
local BAND = Color3.fromHex("#3CCB7F")
local BAND_EDGE = Color3.fromHex("#B8FFD6")
local LAMP_OFF = Color3.fromHex("#3A3F48")
local LIFE_ON = Color3.fromHex("#F0524F")
local BUTTON_COLOUR = Color3.fromHex("#FF9A3C")

-- Per-attempt feedback handlers, keyed by the attempt's ctx (see
-- FuseRewire.luau for why onProgress can't reach the sources directly).
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

local function degrees(pos: number): number
	return (pos * 2 - 1) * ARC_DEGREES
end

local function onArc(pos: number, radius: number): UDim2
	local a = math.rad(degrees(pos))
	return UDim2.fromOffset(PIVOT.X + radius * math.sin(a), PIVOT.Y - radius * math.cos(a))
end

return TaskViewBase.define({
	taskId = "reactor-sync",
	title = "Reactor Sync",
	explainer = "Tap SYNC while the needle is in the green zone. Three syncs win it. Each miss costs a red light, and losing all three starts you over.",
	contentSize = Vector2.new(WIDTH, HEIGHT),

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local openedAt = os.clock()
		local function clock(): number
			return os.clock() - openedAt
		end

		local sweepStart = challenge.sweepStart
		local period = challenge.period
		local half = challenge.bandHalfWidth
		local band = source(challenge.bandCenter)
		local hits = source(0)
		local lives = source(challenge.lives)
		local needle = source(0)
		local frozenAt: number? = nil -- clock() of an unanswered tap

		local conn = RunService.Heartbeat:Connect(function()
			if frozenAt ~= nil and clock() - frozenAt > VERDICT_TIMEOUT then
				frozenAt = nil
			end
			if frozenAt == nil then
				needle(TimingLogic.position(clock(), sweepStart, period))
			end
		end)
		vide.cleanup(function()
			conn:Disconnect()
		end)

		handlers[ctx] = function(feedback: Feedback)
			frozenAt = nil
			needle(feedback.stoppedAt)
			sweepStart, period = feedback.sweepStart, feedback.period
			band(feedback.bandCenter)
			hits(feedback.hits)
			lives(feedback.lives)
			if feedback.hit then
				ctx.setStatus(string.format("Synced %d of %d", feedback.hits, challenge.hitsNeeded), "Good")
				ctx.cue("Good")
			elseif feedback.reset then
				ctx.setStatus("Out of lives - start over", "Bad")
				ctx.cue("Bad")
			else
				ctx.setStatus("Missed!", "Bad")
				ctx.cue("Bad")
			end
		end

		ctx.setStatus("Stop the needle in the green")

		local function onTap()
			local now = clock()
			if frozenAt ~= nil or now <= sweepStart then
				return
			end
			frozenAt = now
			ctx.submit("TimingSubmit", { at = now })
		end

		local gaugeChildren: { Instance } = {}
		for i = 0, TICKS - 1 do
			local pos = i / (TICKS - 1)
			table.insert(
				gaugeChildren,
				create("Frame")({
					Name = "Tick" .. i,
					AnchorPoint = Vector2.new(0.5, 0.5),
					BorderSizePixel = 0,
					Position = onArc(pos, ARC_RADIUS),
					Size = UDim2.fromOffset(TICK.X, TICK.Y),
					Rotation = degrees(pos),
					BackgroundColor3 = function()
						return if TimingLogic.within(pos, band(), half) then BAND else TICK_OFF
					end,
					Base.corner(Theme.radius.pill),
				})
			)
		end
		for _, side in { -1, 1 } do
			table.insert(
				gaugeChildren,
				create("Frame")({
					Name = if side < 0 then "BandStart" else "BandEnd",
					AnchorPoint = Vector2.new(0.5, 0.5),
					BorderSizePixel = 0,
					Position = function()
						return onArc(math.clamp(band() + side * half, 0, 1), ARC_RADIUS)
					end,
					Rotation = function()
						return degrees(math.clamp(band() + side * half, 0, 1))
					end,
					Size = UDim2.fromOffset(3, TICK.Y + 12),
					BackgroundColor3 = BAND_EDGE,
					ZIndex = 2,
					Base.corner(Theme.radius.pill),
				})
			)
		end
		table.insert(
			gaugeChildren,
			create("ImageLabel")({
				Name = "Needle",
				BackgroundTransparency = 1,
				Image = TaskArt.image.needle,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(PIVOT.X, PIVOT.Y),
				Size = UDim2.fromOffset(NEEDLE.X, NEEDLE.Y),
				ZIndex = 3,
				Rotation = function()
					return degrees(needle())
				end,
			})
		)

		local gauge = create("ImageLabel")({
			Name = "Gauge",
			LayoutOrder = 1,
			BackgroundTransparency = 1,
			Image = TaskArt.image.gauge,
			Size = UDim2.fromOffset(GAUGE.X, GAUGE.Y),
			gaugeChildren,
		}) :: ImageLabel

		local readout: { Instance } = {
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, Theme.spacing.xs),
			}),
		}
		for i = 1, challenge.hitsNeeded do
			table.insert(
				readout,
				TaskArt.lamp({
					name = "Sync" .. i,
					size = LAMP,
					LayoutOrder = i,
					colour = function()
						return if hits() >= i then BAND else LAMP_OFF
					end,
				})
			)
		end
		table.insert(
			readout,
			create("Frame")({
				Name = "Spacer",
				BackgroundTransparency = 1,
				LayoutOrder = 50,
				Size = UDim2.fromOffset(28, 1),
			})
		)
		for i = 1, challenge.lives do
			table.insert(
				readout,
				TaskArt.lamp({
					name = "Life" .. i,
					size = LIFE,
					LayoutOrder = 100 + i,
					colour = function()
						return if lives() >= i then LIFE_ON else LAMP_OFF
					end,
				})
			)
		end

		local button = Base.interactive({
			name = "SyncButton",
			size = BUTTON,
			radius = UDim.new(0, 20),
			onActivate = onTap,
			visual = TaskArt.button("SYNC", BUTTON_COLOUR),
		})
		button.LayoutOrder = 3

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
			gauge,
			create("Frame")({
				Name = "Readout",
				LayoutOrder = 2,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
				readout,
			}),
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
