--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of tasks-catalogue.md #13, `airlock-cycle` - see
-- src/server/TaskHandlers/AirlockCycle.luau for the server half. Built on
-- UI/TaskViewBase like ReactorSync.luau, and drawn from the same shared
-- sweep maths (src/shared/TimingLogic.luau) on the same attempt clock.
--
-- A track with the airlock door fixed in the middle. Two red hazard
-- lights travel it together with a gap between them; tap SEAL while the
-- door is inside the gap. A good seal slams the door shut; a bad one
-- flashes the track red, and after a beat the gap sweeps again.

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
	gapHalfWidth: number,
	door: number,
}

type Feedback = {
	sealed: boolean,
	gapAt: number,
	sweepStart: number?,
}

-- Reference px; layout() scales the whole panel to the area.
local WIDTH = 300
local TRACK_HEIGHT = 72
local BUTTON_HEIGHT = 96
local GAP = Theme.spacing.lg
-- The track's ends are padded so the hazards stay visible as the gap
-- reaches 0 or 1 (the gap's edges overhang it by gapHalfWidth).
local INSET = 0.12
local HAZARD_WIDTH = 10
local VERDICT_TIMEOUT = 1 -- see ReactorSync.luau

local TRACK = Color3.fromHex("#1E242C")
local DOOR_FRAME = Color3.fromHex("#8C96A3")
local DOOR_SHUT = Color3.fromHex("#C9D1DB")
local HAZARD = Color3.fromHex("#FF3B30")
local MISS_FLASH = 0.35

-- Per-attempt feedback handlers, keyed by the attempt's ctx (see
-- FuseRewire.luau for why onProgress can't reach the sources directly).
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

local function trackX(pos: number): number
	return INSET + pos * (1 - 2 * INSET)
end

return TaskViewBase.define({
	taskId = "airlock-cycle",
	title = "Airlock Cycle",
	explainer = "Tap SEAL when the door is in the gap between the two red lights.",

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local openedAt = os.clock()
		local function clock(): number
			return os.clock() - openedAt
		end

		local sweepStart = challenge.sweepStart
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

		ctx.setStatus("Seal it in the gap")

		local function onTap()
			local now = clock()
			if sealed() or frozenAt ~= nil or now <= sweepStart then
				return
			end
			frozenAt = now
			ctx.submit("TimingSubmit", { at = now })
		end

		local function hazard(side: number): Instance
			return create("Frame")({
				Name = if side < 0 then "HazardLeft" else "HazardRight",
				AnchorPoint = Vector2.new(0.5, 0.5),
				BorderSizePixel = 0,
				ZIndex = 3,
				Position = function()
					return UDim2.fromScale(trackX(gap() + side * challenge.gapHalfWidth), 0.5)
				end,
				Size = UDim2.new(0, HAZARD_WIDTH, 0.8, 0),
				BackgroundColor3 = HAZARD,
				Base.corner(Theme.radius.sm),
			})
		end

		local doorWidth = (1 - 2 * INSET) * 0.06
		local track = create("Frame")({
			Name = "Track",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, TRACK_HEIGHT),
			BackgroundColor3 = function()
				return if missFlash() then Theme.color.danger else TRACK
			end,
			ClipsDescendants = true,
			Base.corner(Theme.radius.md),
			-- The gap between the hazards, faintly lit so it reads as a window.
			create("Frame")({
				Name = "Gap",
				AnchorPoint = Vector2.new(0.5, 0.5),
				BorderSizePixel = 0,
				Position = function()
					return UDim2.fromScale(trackX(gap()), 0.5)
				end,
				Size = UDim2.fromScale(challenge.gapHalfWidth * 2 * (1 - 2 * INSET), 0.8),
				BackgroundColor3 = Theme.color.success,
				BackgroundTransparency = 0.7,
			}),
			create("Frame")({
				Name = "Door",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(trackX(challenge.door), 0.5),
				Size = UDim2.fromScale(doorWidth, 1),
				ZIndex = 2,
				BackgroundColor3 = function()
					return if sealed() then DOOR_SHUT else TRACK
				end,
				create("UIStroke")({ Color = DOOR_FRAME, Thickness = 3 }),
			}),
			hazard(-1),
			hazard(1),
		}) :: Frame

		local button = Base.interactive({
			name = "SealButton",
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
							Text = "SEAL",
							TextColor3 = Theme.color.onPrimary,
						}),
					}),
				}
			end,
		})
		button.LayoutOrder = 2

		local natural = TRACK_HEIGHT + GAP + BUTTON_HEIGHT
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
