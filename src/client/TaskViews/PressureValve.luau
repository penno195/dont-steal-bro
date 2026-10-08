--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of P2-6's Tap reference task (tasks-catalogue.md #1,
-- `pressure-valve`) - see src/server/TaskHandlers/PressureValve.luau for
-- the server half. Built on UI/TaskViewBase like CodePlayback.luau: the
-- shell owns the window, close, timer and status line; this file owns
-- the gauge, the pump button and the steam.
--
-- A pressure gauge (rendered from the Meshy gauge/needle models, brand
-- logo painted out) with a needle that every tap kicks further round.
-- The needle follows the SERVER's count - each accepted tap's feedback
-- says how far round it is (0..1) - so a tap the server dropped as too
-- fast never moves it. At the top it sits in the red band and steam
-- blasts out of the gauge; "Done!" follows (at once, or after the
-- server's too-fast-to-be-human hold, which the steam covers).
--
-- Too slow and the gauge vents: the server restarts the count, the
-- feedback says `reset`, and the needle drops back. The bar under the
-- gauge is the time left - a client-side approximation of the server's
-- window, restarted on each reset, never read back for validation.
--
-- The whole lower half of the play area is the pump button, well past
-- the 44-point minimum and nowhere near an edge: one thumb, no aim.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local Env = require(script.Parent.Parent.UI.Components.Env)
local TaskArt = require(script.Parent.Parent.UI.TaskArt)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local source = vide.source

type Challenge = {
	meterFillSeconds: number,
}

type Feedback = {
	progress: number,
	reset: boolean,
}

-- Art. gauge.png is 512 square, centred on the dial's pivot; the needle
-- and cap are centred on the same point, so all three share a centre.
local GAUGE_IMAGE = "rbxassetid://120868314841567"
local NEEDLE_IMAGE = "rbxassetid://99030123318339"
local CAP_IMAGE = "rbxassetid://81076900098251"
local STEAM_IMAGE = "rbxassetid://113995447343495"
task.spawn(function()
	pcall(ContentProvider.PreloadAsync, ContentProvider, { GAUGE_IMAGE, NEEDLE_IMAGE, CAP_IMAGE, STEAM_IMAGE })
end)
-- Needle and cap edges as a share of the gauge image's edge.
local NEEDLE_SIZE = 0.44
local CAP_SIZE = 0.125
-- Share of the art's height above the gauge's rim (transparent).
local ART_TOP = 0.22
-- Where the steam leaves: the top of the gauge's rim.
local STEAM_ORIGIN = Vector2.new(0.5, 0.24)
-- The dial runs 0..10 over 270 degrees, 0 at bottom-left.
local ANGLE_EMPTY = -135
local ANGLE_FULL = 135

-- The button's native edge; layout() scales it to BUTTON_SHARE of the
-- gauge, centred FITTING_Y of the way down it (over the brass fitting).
local BUTTON = 132
local BUTTON_SHARE = 0.42
local FITTING_Y = 0.9
local BAR = 14
local GAP = Theme.spacing.md
-- How quickly the needle catches up with the server's count (per second).
local NEEDLE_RATE = 14
local STEAM_PUFFS = 7
local HISS_SECONDS = 0.12 -- a puff this often while it keeps venting

-- Per-attempt feedback handlers, keyed by the attempt's ctx (see
-- FuseRewire.luau for why onProgress can't reach the sources directly).
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

local function image(props: { [any]: any }): ImageLabel
	local merged: { [any]: any } = {
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
	}
	for k, v in props do
		merged[k] = v
	end
	return create("ImageLabel")(merged) :: ImageLabel
end

-- One puff: rises from the rim, drifts sideways, swells and fades.
local function puff(parent: GuiObject, index: number)
	local spread = (index / (STEAM_PUFFS - 1) - 0.5) * 2 -- -1..1
	local p = image({
		Name = "Steam",
		Image = STEAM_IMAGE,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(STEAM_ORIGIN.X + spread * 0.04, STEAM_ORIGIN.Y),
		Size = UDim2.fromScale(0.12, 0.12),
		Rotation = spread * 20,
		ImageTransparency = 0.1,
		ZIndex = 5,
		Parent = parent,
	})
	local rise = 0.2 + math.random() * 0.12
	local seconds = 1.1 + math.random() * 0.4
	-- Shoots out fast and swells; stays dense most of the way, then thins.
	TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(STEAM_ORIGIN.X + spread * 0.32, STEAM_ORIGIN.Y - rise),
		Size = UDim2.fromScale(0.32, 0.32),
		Rotation = spread * 60,
	}):Play()
	local fade = TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		ImageTransparency = 1,
	})
	fade.Completed:Once(function()
		p:Destroy()
	end)
	fade:Play()
end

return TaskViewBase.define({
	taskId = "pressure-valve",
	title = "Pressure Valve",
	explainer = "Tap PUMP fast to push the needle into the red and blow the steam. Too slow and the pressure leaks away - watch the bar.",
	-- layout() at its cap: the gauge as big as the button allows.
	contentSize = Vector2.new(
		BUTTON / BUTTON_SHARE,
		BUTTON / BUTTON_SHARE * (FITTING_Y + BUTTON_SHARE / 2) + GAP + BAR
	),

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local windowSeconds = math.max(0.5, challenge.meterFillSeconds)

		local target = 0 -- 0..1, the server's count
		local shown = 0 -- 0..1, where the needle is drawn
		local venting = false
		local cycleStarted = os.clock()
		local timeLeft = source(1)

		-- Placed by layout() below: stacked on a tall area, side by side
		-- on a wide one (a monitor's window is only ~260 reference px tall).
		local gauge = create("Frame")({
			Name = "Gauge",
			BackgroundTransparency = 1,
			create("UIAspectRatioConstraint")({ AspectRatio = 1 }),
		}) :: Frame
		-- The art is centred on the needle's pivot, so its top ~22% is
		-- empty. The dial is drawn oversized and nudged up so the gauge
		-- body, not the empty square, fills the frame.
		local dial = create("Frame")({
			Name = "Dial",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, -ART_TOP / (1 - ART_TOP)),
			Size = UDim2.fromScale(1 / (1 - ART_TOP), 1 / (1 - ART_TOP)),
			Parent = gauge,
		}) :: Frame
		local face = image({ Name = "Face", Image = GAUGE_IMAGE, Size = UDim2.fromScale(1, 1), Parent = dial })
		local needle = image({
			Name = "Needle",
			Image = NEEDLE_IMAGE,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(NEEDLE_SIZE, NEEDLE_SIZE),
			Rotation = ANGLE_EMPTY,
			ZIndex = 2,
			Parent = dial,
		})
		image({
			Name = "Cap",
			Image = CAP_IMAGE,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(CAP_SIZE, CAP_SIZE),
			ZIndex = 3,
			Parent = dial,
		})

		-- A big first blast, then it keeps hissing until the view closes
		-- (which covers the server's too-fast hold before "Done!").
		local lastPuff = 0
		local function vent()
			if venting then
				return
			end
			venting = true
			lastPuff = os.clock()
			for i = 0, STEAM_PUFFS - 1 do
				puff(dial, i)
			end
		end

		local startedAt = os.clock()
		local conn = RunService.Heartbeat:Connect(function(dt)
			local calm = Env.reducedMotion()
			shown = if calm then target else shown + (target - shown) * (1 - math.exp(-NEEDLE_RATE * dt))
			-- Under pressure the needle trembles, more the higher it is.
			local wobble = if calm then 0 else math.sin((os.clock() - startedAt) * 45) * 1.5 * shown
			needle.Rotation = ANGLE_EMPTY + (ANGLE_FULL - ANGLE_EMPTY) * shown + wobble
			-- At the top the whole gauge shudders while it vents.
			face.Position = if venting and not calm
				then UDim2.fromOffset(math.random(-2, 2), math.random(-2, 2))
				else UDim2.new()
			if not venting then
				timeLeft(math.clamp(1 - (os.clock() - cycleStarted) / windowSeconds, 0, 1))
			elseif os.clock() - lastPuff > HISS_SECONDS then
				lastPuff = os.clock()
				puff(dial, math.random(0, STEAM_PUFFS - 1))
			end
		end)
		vide.cleanup(function()
			conn:Disconnect()
		end)

		handlers[ctx] = function(feedback: Feedback)
			if feedback.reset then
				-- The gauge vented while they were slow: the needle falls back.
				cycleStarted = os.clock()
				shown = 0
				ctx.setStatus("Too slow, pressure lost", "Bad")
				ctx.cue("Bad")
			end
			target = math.clamp(feedback.progress, 0, 1)
			if target >= 1 then
				ctx.setStatus("Venting!", "Good")
				vent()
			elseif not feedback.reset then
				ctx.setStatus("Keep pumping!", "Active")
			end
		end

		ctx.setStatus("Tap to build pressure")

		local bar = TaskArt.meter(timeLeft, function()
			return if timeLeft() < 0.3 then Theme.color.danger else Theme.color.warning
		end)
		bar.Name = "TimeLeft"
		bar.AnchorPoint = Vector2.new(0.5, 0)

		local button = Base.interactive({
			name = "PumpButton",
			size = Vector2.new(BUTTON, BUTTON),
			radius = Theme.radius.pill,
			anchorPoint = Vector2.new(0.5, 0),
			onActivate = function()
				if not venting then
					ctx.submit("TapSubmit")
				end
			end,
			-- (Base.interactive already bounces the visual on press.)
			visual = function()
				return {
					-- The red mushroom cap (UI/TaskArt), lettered here.
					create("ImageLabel")({
						Name = "Surface",
						BackgroundTransparency = 1,
						Image = TaskArt.image.cap,
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(1, 1),
						Base.text("headline", {
							AnchorPoint = Vector2.new(0.5, 0.5),
							Position = UDim2.fromScale(0.5, 0.52),
							Size = UDim2.fromScale(0.72, 0.3),
							Text = "PUMP",
							TextColor3 = Color3.fromHex("#FFF4F2"),
							create("UIStroke")({ Color = Color3.fromHex("#5A0606"), Thickness = 2.5 }),
						}),
					}),
				}
			end,
		})

		-- One piece: the gauge on top and the pump button sat over its
		-- brass fitting like a valve cap, the time bar just under that.
		-- Everything scales off the gauge's edge G (reference px - the
		-- area's absolute size divided by the UI scale), which is as big
		-- as the area allows, capped so the button stays thumb-sized
		-- rather than a billboard.
		local fit = create("UIScale")({ Parent = button }) :: UIScale
		button.ZIndex = 2 -- over the gauge it overlaps
		local function layout()
			local s = Env.scale()
			local size = ctx.area.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 or s <= 0 then
				return
			end
			local w, h = size.X / s, size.Y / s
			-- Stack height: fitting centre + half the button + bar.
			local perG = FITTING_Y + BUTTON_SHARE / 2
			local g = math.min(w, (h - GAP - BAR) / perG, BUTTON / BUTTON_SHARE)
			local b = g * BUTTON_SHARE
			local top = (h - (g * perG + GAP + BAR)) / 2
			fit.Scale = b / BUTTON
			gauge.AnchorPoint = Vector2.new(0.5, 0)
			gauge.Position = UDim2.new(0.5, 0, 0, top)
			gauge.Size = UDim2.fromOffset(g, g)
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.Position = UDim2.new(0.5, 0, 0, top + g * FITTING_Y)
			bar.Position = UDim2.new(0.5, 0, 0, top + g * FITTING_Y + b / 2 + GAP)
			bar.Size = UDim2.fromOffset(g * 0.6, BAR)
		end
		local areaChanged = ctx.area:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		vide.cleanup(function()
			areaChanged:Disconnect()
		end)
		vide.effect(function()
			Env.scale() -- re-lay on a scale change too
			task.defer(layout)
		end)

		return { gauge :: Instance, bar :: Instance, button :: Instance }
	end,

	-- Let the payoff play before COMPLETE covers it.
	payoffSeconds = 1,

	onProgress = function(ctx, feedback)
		local handle = handlers[ctx]
		if handle ~= nil and type(feedback) == "table" then
			handle(feedback :: Feedback)
		end
	end,
})
