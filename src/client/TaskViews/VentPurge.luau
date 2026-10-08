--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of tasks-catalogue.md #2, `vent-purge` - see
-- src/server/TaskHandlers/VentPurge.luau for the server half. Built on
-- UI/TaskViewBase like PressureValve.luau, whose Tap shape it shares.
--
-- One piece of art: the biohazard purge tank, its brass button already
-- painted on with "TAP HERE TO PURGE" above it. The tap target sits over
-- that button (drawn larger than the brass so a thumb can't miss it).
-- A thermometer beside the tank is the purge progress, following the
-- SERVER's count, so a tap dropped as too fast never moves it. Full, and
-- toxic goo pours out of the pipe until the view closes (which covers
-- the server's too-fast-to-be-human hold before "Done!").
--
-- Too slow and the gas meter fills: the server restarts the count, the
-- feedback says `reset`, and the thermometer drops back. The bar under
-- the tank is that gas meter - a client-side approximation of the
-- server's window, restarted on each reset, never read back.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local Env = require(script.Parent.Parent.UI.Components.Env)
local TaskArt = require(script.Parent.Parent.UI.TaskArt)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local source = vide.source

type Challenge = {
	gasFillSeconds: number,
}

type Feedback = {
	progress: number,
	reset: boolean,
}

-- Art: 502x498, transparent PNG cropped to the tank. Points below are shares of it.
local TANK_IMAGE = "rbxassetid://104118102672304"
task.spawn(function()
	pcall(ContentProvider.PreloadAsync, ContentProvider, { TANK_IMAGE })
end)
local TANK_ASPECT = 502 / 498
local BRASS_CENTRE = Vector2.new(0.294, 0.806)
local OUTLET = Vector2.new(0.99, 0.468) -- the pipe's open mouth, facing right

-- The button's native edge; layout() scales it to BUTTON_SHARE of the
-- tank's width - about twice the brass, so it's comfortably thumb-sized.
local BUTTON = 132
local BUTTON_SHARE = 0.34
local MAX_TANK = 340 -- reference px; past this the button is a billboard
local THERMO_SHARE = 0.17 -- thermometer width as a share of tank height
local BAR = 14
local GAP = Theme.spacing.md

local FILL_RATE = 14 -- how quickly the mercury catches up (per second)
local KICK = 0.035 -- the tank's squash on each tap
local GOO = Color3.fromHex("#8BE04E")
local GOO_DARK = Color3.fromHex("#3F8A1E")
local GOO_EVERY = 0.03 -- seconds between blobs while it pours
local GOO_LIFE = 1.1
local GRAVITY = 2.6 -- tank heights per second squared

-- Per-attempt feedback handlers, keyed by the attempt's ctx (see
-- FuseRewire.luau for why onProgress can't reach the sources directly).
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

type Blob = { frame: Frame, pos: Vector2, vel: Vector2, age: number, size: number }

return TaskViewBase.define({
	taskId = "vent-purge",
	title = "Vent Purge",
	explainer = "Tap the brass button fast to fill the gauge and purge the tank. Too slow and the gas builds back up - watch the bar.",
	-- layout() at its cap: the tank at MAX_TANK with the thermometer beside it.
	contentSize = Vector2.new(MAX_TANK * (TANK_ASPECT + THERMO_SHARE) + GAP, MAX_TANK + GAP + BAR),

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local windowSeconds = math.max(0.5, challenge.gasFillSeconds)

		local target = 0 -- 0..1, the server's count
		local shown = 0 -- 0..1, where the mercury is drawn
		local kick = 0
		local purging = false
		local cycleStarted = os.clock()
		local gasLeft = source(1)

		local tank = create("Frame")({
			Name = "Tank",
			BackgroundTransparency = 1,
		}) :: Frame
		local tankScale = create("UIScale")({ Parent = tank }) :: UIScale
		local art = create("ImageLabel")({
			Name = "Art",
			Image = TANK_IMAGE,
			BackgroundTransparency = 1,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromScale(1, 1),
			Parent = tank,
		}) :: ImageLabel

		-- The thermometer: a pill-shaped tube over a round bulb, both
		-- filled with the same green, the tube's fill rising from the
		-- bulb. Built from frames, so it scales with no art at all.
		local thermo = create("Frame")({ Name = "Thermometer", BackgroundTransparency = 1 }) :: Frame
		local tube = create("Frame")({
			Name = "Tube",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromScale(0.46, 0.84),
			BackgroundColor3 = Theme.color.surface,
			Base.corner(Theme.radius.pill),
			create("UIStroke")({ Color = Color3.fromHex("#0E1015"), Thickness = 3 }),
			Parent = thermo,
		}) :: Frame
		local mercury = create("Frame")({
			Name = "Mercury",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 1),
			Size = UDim2.fromScale(0.62, 0.1),
			BackgroundColor3 = Theme.color.success,
			BorderSizePixel = 0,
			Base.corner(Theme.radius.pill),
			Parent = tube,
		}) :: Frame
		for i = 1, 4 do
			create("Frame")({
				Name = "Tick",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0.72, 1 - i / 5),
				Size = UDim2.new(0.28, 0, 0, 2),
				BackgroundColor3 = Theme.color.inkMuted,
				BackgroundTransparency = 0.3,
				BorderSizePixel = 0,
				Parent = tube,
			})
		end
		local bulb = create("Frame")({
			Name = "Bulb",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 1),
			Size = UDim2.fromScale(1, 0.24),
			BackgroundColor3 = Theme.color.success,
			ZIndex = 2,
			create("UIAspectRatioConstraint")({ AspectRatio = 1 }),
			Base.corner(UDim.new(0.5, 0)),
			create("UIStroke")({ Color = Color3.fromHex("#0E1015"), Thickness = 3 }),
			Parent = thermo,
		}) :: Frame

		-- Goo: blobs leave the pipe's mouth moving right, arc down under
		-- gravity, and thin out. Positions are in tank-frame scale units.
		local blobs: { Blob } = {}
		local lastBlob = 0
		local function spawnBlob()
			local size = 0.035 + math.random() * 0.035
			local frame = create("Frame")({
				Name = "Goo",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromScale(size, size * TANK_ASPECT),
				BackgroundColor3 = if math.random() < 0.3 then GOO_DARK else GOO,
				BorderSizePixel = 0,
				ZIndex = 4,
				Base.corner(UDim.new(0.5, 0)),
				Parent = tank,
			}) :: Frame
			table.insert(blobs, {
				frame = frame,
				pos = OUTLET + Vector2.new(0, (math.random() - 0.5) * 0.04),
				vel = Vector2.new(0.35 + math.random() * 0.3, -0.1 - math.random() * 0.2),
				age = 0,
				size = size,
			})
		end
		local function purge()
			if purging then
				return
			end
			purging = true
			lastBlob = os.clock()
			for _ = 1, 10 do
				spawnBlob()
			end
		end

		local conn = RunService.Heartbeat:Connect(function(dt)
			local calm = Env.reducedMotion()
			shown = if calm then target else shown + (target - shown) * (1 - math.exp(-FILL_RATE * dt))
			mercury.Size = UDim2.fromScale(0.62, 0.1 + 0.9 * shown)
			local full = shown > 0.98
			bulb.BackgroundColor3 = if full then GOO else Theme.color.success
			mercury.BackgroundColor3 = bulb.BackgroundColor3

			kick = if calm then 0 else kick * math.exp(-18 * dt)
			tankScale.Scale = 1 - kick
			-- While it purges, the whole tank judders.
			art.Position = if purging and not calm
				then UDim2.fromOffset(math.random(-2, 2), math.random(-2, 2))
				else UDim2.new()

			if not purging then
				gasLeft(math.clamp(1 - (os.clock() - cycleStarted) / windowSeconds, 0, 1))
			elseif os.clock() - lastBlob > GOO_EVERY then
				lastBlob = os.clock()
				spawnBlob()
			end

			for i = #blobs, 1, -1 do
				local blob = blobs[i]
				blob.age += dt
				if blob.age >= GOO_LIFE then
					blob.frame:Destroy()
					table.remove(blobs, i)
				else
					blob.vel += Vector2.new(0, GRAVITY * dt)
					blob.pos += blob.vel * dt
					blob.frame.Position = UDim2.fromScale(blob.pos.X, blob.pos.Y)
					blob.frame.BackgroundTransparency = math.max(0, (blob.age / GOO_LIFE - 0.6) / 0.4)
				end
			end
		end)
		vide.cleanup(function()
			conn:Disconnect()
		end)

		handlers[ctx] = function(feedback: Feedback)
			if feedback.reset then
				-- The gas meter filled while they were slow: start again.
				cycleStarted = os.clock()
				shown = 0
				ctx.setStatus("Gas built up, purge again", "Bad")
				ctx.cue("Bad")
			end
			target = math.clamp(feedback.progress, 0, 1)
			if target >= 1 then
				ctx.setStatus("Purging!", "Good")
				purge()
			elseif not feedback.reset then
				ctx.setStatus("Keep tapping!", "Active")
			end
		end

		ctx.setStatus("Tap the button to purge")

		local bar = TaskArt.meter(gasLeft, function()
			return if gasLeft() < 0.3 then Theme.color.danger else Theme.color.warning
		end)
		bar.Name = "GasMeter"
		bar.AnchorPoint = Vector2.new(0.5, 0)

		-- Mostly invisible: the art already draws the button. A faint ring
		-- marks it, and it's what Base.interactive bounces on press.
		local button = Base.interactive({
			name = "PurgeButton",
			size = Vector2.new(BUTTON, BUTTON),
			radius = Theme.radius.pill,
			anchorPoint = Vector2.new(0.5, 0.5),
			onActivate = function()
				if not purging then
					kick = KICK
					ctx.submit("TapSubmit")
				end
			end,
			visual = function()
				return {
					create("Frame")({
						Name = "Ring",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(0.62, 0.62),
						BackgroundTransparency = 1,
						Base.corner(Theme.radius.pill),
						create("UIStroke")({ Color = Color3.new(1, 1, 1), Thickness = 3, Transparency = 0.45 }),
					}),
				}
			end,
		})
		local fit = create("UIScale")({ Parent = button }) :: UIScale
		button.ZIndex = 3

		-- Thermometer | tank side by side, the gas meter under the tank.
		-- Everything scales off the tank's height H (reference px).
		local function layout()
			local s = Env.scale()
			local size = ctx.area.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 or s <= 0 then
				return
			end
			local w, h = size.X / s, size.Y / s
			local th = math.min(h - GAP - BAR, (w - GAP) / (TANK_ASPECT + THERMO_SHARE), MAX_TANK)
			local tw = th * TANK_ASPECT
			local mw = th * THERMO_SHARE
			local left = (w - (mw + GAP + tw)) / 2
			local top = (h - (th + GAP + BAR)) / 2
			local tankLeft = left + mw + GAP

			thermo.Position = UDim2.fromOffset(left, top + th * 0.2)
			thermo.Size = UDim2.fromOffset(mw, th * 0.75)
			tank.Position = UDim2.fromOffset(tankLeft, top)
			tank.Size = UDim2.fromOffset(tw, th)
			local b = tw * BUTTON_SHARE
			fit.Scale = b / BUTTON
			button.Position = UDim2.fromOffset(tankLeft + tw * BRASS_CENTRE.X, top + th * BRASS_CENTRE.Y)
			bar.Position = UDim2.fromOffset(tankLeft + tw / 2, top + th + GAP)
			bar.Size = UDim2.fromOffset(tw * 0.6, BAR)
		end
		local areaChanged = ctx.area:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		vide.cleanup(function()
			areaChanged:Disconnect()
		end)
		vide.effect(function()
			Env.scale() -- re-lay on a scale change too
			task.defer(layout)
		end)

		return { thermo :: Instance, tank :: Instance, bar :: Instance, button :: Instance }
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
