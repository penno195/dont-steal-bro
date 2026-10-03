--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of the Timing reference task (tasks-catalogue.md #11,
-- `reactor-sync`) - see src/server/TaskHandlers/ReactorSync.luau for the
-- server half. Built on UI/TaskViewBase like PressureValve.luau: the shell
-- owns the window, close, timer and status line; this file owns the dial
-- and the SYNC button.
--
-- The needle is drawn by TimingLogic.position - the SAME function the
-- server checks the stop against - on this attempt's clock (seconds since
-- the view opened, i.e. since the challenge landed). A tap sends that
-- clock reading (TimingSubmit), freezes the needle where it stopped, and
-- waits for the server's verdict: the next sweep's start, speed and band
-- come back in its feedback. Three lamps count syncs; three pips are the
-- lives a miss costs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local Env = require(script.Parent.Parent.UI.Components.Env)
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

-- Reference px; layout() scales the whole panel to the area.
local WIDTH = 300
local LAMP = 22
local DIAL_HEIGHT = 56
local BUTTON_HEIGHT = 96
local GAP = Theme.spacing.md
-- A tap with no answer after this long un-freezes the needle (a dropped
-- stop - too early, or the server had no honest time left for it).
local VERDICT_TIMEOUT = 1

local DIAL_FACE = Color3.fromHex("#14202B")
local NEEDLE = Color3.fromHex("#F2F5F8")
local LAMP_OFF = Color3.fromHex("#3A3A3A")
local LAMP_ON = Color3.fromHex("#3DDC84")

-- Per-attempt feedback handlers, keyed by the attempt's ctx (see
-- FuseRewire.luau for why onProgress can't reach the sources directly).
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

local function row(children: { Instance }, height: number, order: number): Frame
	return create("Frame")({
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, height),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.sm),
		}),
		children,
	}) :: Frame
end

return TaskViewBase.define({
	taskId = "reactor-sync",
	title = "Reactor Sync",
	explainer = "Tap SYNC while the needle is in the green band. Three syncs in a row win it. Each miss costs a life, and losing all three starts you over.",

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local openedAt = os.clock()
		local function clock(): number
			return os.clock() - openedAt
		end

		local sweepStart = challenge.sweepStart
		local period = challenge.period
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

		local lamps: { Instance } = {}
		for i = 1, challenge.hitsNeeded do
			table.insert(
				lamps,
				create("Frame")({
					Name = "Sync" .. i,
					Size = UDim2.fromOffset(LAMP, LAMP),
					BackgroundColor3 = function()
						return if hits() >= i then LAMP_ON else LAMP_OFF
					end,
					Base.corner(Theme.radius.pill),
				})
			)
		end
		local pips: { Instance } = {}
		for i = 1, challenge.lives do
			table.insert(
				pips,
				create("Frame")({
					Name = "Life" .. i,
					Size = UDim2.fromOffset(LAMP * 0.6, LAMP * 0.6),
					BackgroundColor3 = function()
						return if lives() >= i then Theme.color.danger else LAMP_OFF
					end,
					Base.corner(Theme.radius.pill),
				})
			)
		end

		local dial = create("Frame")({
			Name = "Dial",
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, DIAL_HEIGHT),
			BackgroundColor3 = DIAL_FACE,
			ClipsDescendants = true,
			Base.corner(Theme.radius.md),
			create("Frame")({
				Name = "Band",
				AnchorPoint = Vector2.new(0.5, 0),
				BorderSizePixel = 0,
				Position = function()
					return UDim2.fromScale(band(), 0)
				end,
				Size = UDim2.fromScale(challenge.bandHalfWidth * 2, 1),
				BackgroundColor3 = Theme.color.success,
				BackgroundTransparency = 0.25,
			}),
			create("Frame")({
				Name = "Needle",
				AnchorPoint = Vector2.new(0.5, 0),
				BorderSizePixel = 0,
				Position = function()
					return UDim2.fromScale(needle(), 0)
				end,
				Size = UDim2.new(0, 4, 1, 0),
				BackgroundColor3 = NEEDLE,
			}),
		}) :: Frame

		local button = Base.interactive({
			name = "SyncButton",
			size = Vector2.new(WIDTH, BUTTON_HEIGHT),
			radius = Theme.radius.lg,
			onActivate = onTap,
			visual = function()
				return {
					create("Frame")({
						Name = "Surface",
						Size = UDim2.fromScale(1, 1),
						BackgroundColor3 = Theme.color.primary,
						Base.corner(Theme.radius.lg),
						Base.text("headline", {
							Size = UDim2.fromScale(1, 1),
							Text = "SYNC",
							TextColor3 = Theme.color.onPrimary,
						}),
					}),
				}
			end,
		})
		button.LayoutOrder = 4

		local natural = LAMP + GAP + LAMP * 0.6 + GAP + DIAL_HEIGHT + GAP + BUTTON_HEIGHT
		local panel = create("Frame")({
			Name = "Panel",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(WIDTH, natural),
			create("UIListLayout")({
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, GAP),
			}),
			row(lamps, LAMP, 1),
			row(pips, LAMP * 0.6, 2),
			dial,
			button,
		}) :: Frame

		local fit = create("UIScale")({ Parent = panel }) :: UIScale
		local function layout()
			local s = Env.scale()
			local size = ctx.area.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 or s <= 0 then
				return
			end
			fit.Scale = math.min(size.X / s / WIDTH, size.Y / s / natural, 1.3)
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
