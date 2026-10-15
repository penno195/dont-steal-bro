--!strict
-- The tutorial reward's "spin and win" reveal in the Hub (owner,
-- 2026-10-15). Before the claim pop-up opens: the screen dims, gold rays
-- turn behind a "?" prize that punches on every tick of the spin
-- (PrizeRevealLogic's timeline; MenuController plays the sounds), then
-- on the reveal a white flash, the prize bursts, confetti flies, and
-- the rays keep turning slowly behind the claim pop-up until it closes.
--
-- Display only, like ClaimPopup: the reward was paid on the match
-- server. Built from plain Instances rather than Vide, since every
-- property here is driven frame by frame rather than by state.
--
-- Layers: the backdrop and rays sit one band under the modal so the
-- claim pop-up opens over them; the flash and confetti sit one over it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Env = require(script.Parent.Parent.Components.Env)
local Theme = require(script.Parent.Parent.Theme)
local UIScaleController = require(script.Parent.Parent.Parent.Controllers.UIScaleController)

local PrizeReveal = {}

local RAYS = 12
local RAY_LENGTH = 900 -- reference px, past the corners of any screen
local RAY_WIDTH = 70
local SPIN_SPEED = 220 -- the rays' degrees per second at the spin's start
local IDLE_SPEED = 18 -- and behind the claim pop-up
local PRIZE_SIZE = 140
local PUNCH = 1.14 -- the prize's scale on each tick, easing back to 1
local CONFETTI = 70
local CONFETTI_LIFE = 2.6 -- seconds
local GRAVITY = 900 -- px/s^2

local function new<T>(className: string, props: { [string]: any }): T
	local instance = Instance.new(className) :: any
	for key, value in props do
		if key ~= "Parent" then
			instance[key] = value
		end
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance :: T
end

local function corner(parent: Instance, radius: number)
	new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

export type Handle = {
	tick: () -> (), -- one tick of the spin: the prize punches
	reveal: () -> (), -- the prize bursts, flash and confetti
	close: () -> (), -- fades everything out and cleans up
}

-- Puts the spin on screen and returns its handle. `spin` is the seconds
-- until the reveal, which slows the rays to IDLE_SPEED over that time.
function PrizeReveal.open(spin: number): Handle
	local reduced = Env.reducedMotion()
	local back = UIScaleController.createScreen("PrizeRevealBack", {
		displayOrder = Theme.displayOrder.modal - 1,
		fullBleed = true,
	})
	local front = UIScaleController.createScreen("PrizeRevealFront", {
		displayOrder = Theme.displayOrder.modal + 2,
		fullBleed = true,
	})

	local dim = new("Frame", {
		Name = "Dim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.color.scrim,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = back,
	}) :: Frame
	TweenService:Create(dim, TweenInfo.new(Env.duration(0.25)), { BackgroundTransparency = 0.35 }):Play()

	-- The rays: thin wedges fanned round the centre, fading out along
	-- their length, turned as one.
	local wheel = new("Frame", {
		Name = "Rays",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		Parent = back,
	}) :: Frame
	for i = 1, RAYS do
		local ray = new("Frame", {
			Name = "Ray" .. i,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(RAY_WIDTH, RAY_LENGTH),
			Rotation = 0,
			BackgroundColor3 = if i % 2 == 0 then Theme.color.primary else Theme.color.rim,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			Parent = wheel,
		}) :: Frame
		-- Rotation turns a frame about its centre, so each ray lives in a
		-- holder centred on the wheel and is offset out from it.
		local holder = new("Frame", {
			Name = "Arm" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(RAY_WIDTH, RAY_LENGTH * 2),
			Rotation = (i - 1) * 360 / RAYS,
			BackgroundTransparency = 1,
			Parent = wheel,
		}) :: Frame
		ray.Position = UDim2.fromScale(0.5, 0.5)
		ray.Parent = holder
		new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.6, 0.75),
				NumberSequenceKeypoint.new(1, 0.35),
			}),
			Parent = ray,
		})
	end
	local wheelScale = new("UIScale", { Scale = 0.3, Parent = wheel }) :: UIScale
	TweenService:Create(
		wheelScale,
		TweenInfo.new(Env.duration(0.5), Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()

	-- The prize: a gold box with a "?", on the safe-area scale.
	local prizeHolder = new("Frame", {
		Name = "PrizeHolder",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(PRIZE_SIZE, PRIZE_SIZE),
		BackgroundTransparency = 1,
		Parent = back,
	}) :: Frame
	local unscale = UIScaleController.attachScale(prizeHolder)
	local prize = new("TextLabel", {
		Name = "Prize",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.color.primary,
		BorderSizePixel = 0,
		Text = "?",
		TextColor3 = Theme.color.ink,
		Parent = prizeHolder,
	}) :: TextLabel
	Theme.applyText(prize, "display")
	-- The display style stops at 48 px; the "?" should fill its box.
	local fit = prize:FindFirstChildOfClass("UITextSizeConstraint")
	if fit then
		fit.MaxTextSize = PRIZE_SIZE
	end
	new("UIPadding", {
		PaddingTop = UDim.new(0.14, 0),
		PaddingBottom = UDim.new(0.06, 0),
		Parent = prize,
	})
	corner(prize, 24)
	new("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = Theme.color.rim,
		Thickness = 5,
		Parent = prize,
	})
	local prizeScale = new("UIScale", { Scale = 0, Parent = prize }) :: UIScale
	TweenService:Create(
		prizeScale,
		TweenInfo.new(Env.duration(0.35), Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()

	-- Rays slow from SPIN_SPEED to IDLE_SPEED across the spin, like the
	-- wheel the ticks belong to; the prize shakes harder as it nears.
	local started = os.clock()
	local revealed = false
	local angle = 0
	local spinConn = RunService.RenderStepped:Connect(function(dt: number)
		if reduced then
			return
		end
		local progress = math.clamp((os.clock() - started) / spin, 0, 1)
		local speed = if revealed then IDLE_SPEED else SPIN_SPEED + (IDLE_SPEED - SPIN_SPEED) * progress
		angle = (angle + speed * dt) % 360
		wheel.Rotation = angle
		if not revealed then
			local shake = 2 + 10 * progress
			prize.Rotation = math.sin(os.clock() * 40) * shake
		end
	end)

	local function tick()
		if revealed then
			return
		end
		prizeScale.Scale = PUNCH
		TweenService:Create(prizeScale, TweenInfo.new(Env.duration(0.12)), { Scale = 1 }):Play()
	end

	local confettiConn: RBXScriptConnection? = nil

	local function confetti()
		local camera = workspace.CurrentCamera
		local view = if camera then camera.ViewportSize else Vector2.new(1280, 720)
		local origin = view / 2
		local colors = {
			Theme.color.primary,
			Theme.color.rim,
			Theme.color.brand,
			Theme.color.above,
			Theme.color.success,
			Theme.color.ink,
		}
		type Piece = { frame: Frame, velocity: Vector2, position: Vector2, spin: number }
		local pieces: { Piece } = {}
		local rng = Random.new()
		for i = 1, CONFETTI do
			local heading = rng:NextNumber(0, math.pi * 2)
			local speed = rng:NextNumber(350, 900)
			local frame = new("Frame", {
				Name = "Confetti",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(rng:NextInteger(8, 14), rng:NextInteger(14, 22)),
				BackgroundColor3 = colors[(i % #colors) + 1],
				BorderSizePixel = 0,
				Rotation = rng:NextNumber(0, 360),
				Parent = front,
			}) :: Frame
			table.insert(pieces, {
				frame = frame,
				-- Biased upward, so it bursts up and rains down.
				velocity = Vector2.new(math.cos(heading), math.sin(heading) - 0.6) * speed,
				position = origin,
				spin = rng:NextNumber(-540, 540),
			})
		end
		local born = os.clock()
		confettiConn = RunService.RenderStepped:Connect(function(dt: number)
			local age = os.clock() - born
			local fade = math.clamp((age - CONFETTI_LIFE * 0.6) / (CONFETTI_LIFE * 0.4), 0, 1)
			for _, piece in pieces do
				piece.velocity = Vector2.new(piece.velocity.X * (1 - 1.2 * dt), piece.velocity.Y + GRAVITY * dt)
				piece.position += piece.velocity * dt
				piece.frame.Position = UDim2.fromOffset(piece.position.X, piece.position.Y)
				piece.frame.Rotation += piece.spin * dt
				piece.frame.BackgroundTransparency = fade
			end
			if age >= CONFETTI_LIFE then
				for _, piece in pieces do
					piece.frame:Destroy()
				end
				if confettiConn then
					confettiConn:Disconnect()
					confettiConn = nil
				end
			end
		end)
	end

	local function reveal()
		if revealed then
			return
		end
		revealed = true
		prize.Rotation = 0
		-- The prize bursts: a quick swell as it fades, handing over to the
		-- claim pop-up's own bounce in.
		TweenService:Create(prizeScale, TweenInfo.new(Env.duration(0.25)), { Scale = 1.8 }):Play()
		TweenService:Create(prize, TweenInfo.new(Env.duration(0.25)), {
			BackgroundTransparency = 1,
			TextTransparency = 1,
		}):Play()
		local stroke = prize:FindFirstChildOfClass("UIStroke")
		if stroke then
			TweenService:Create(stroke, TweenInfo.new(Env.duration(0.25)), { Transparency = 1 }):Play()
		end
		if reduced then
			return
		end
		local flash = new("Frame", {
			Name = "Flash",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			Parent = front,
		}) :: Frame
		TweenService:Create(flash, TweenInfo.new(0.6, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
		wheelScale.Scale = 1.25
		TweenService
			:Create(wheelScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
			:Play()
		confetti()
	end

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		TweenService:Create(dim, TweenInfo.new(Env.duration(0.3)), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(wheelScale, TweenInfo.new(Env.duration(0.3)), { Scale = 0 }):Play()
		task.delay(Env.duration(0.3) + 0.05, function()
			spinConn:Disconnect()
			if confettiConn then
				confettiConn:Disconnect()
				confettiConn = nil
			end
			unscale()
			-- createScreen replaces by name, so only destroy our own.
			local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
			if back.Parent == playerGui then
				back:Destroy()
			end
			if front.Parent == playerGui then
				front:Destroy()
			end
		end)
	end

	return { tick = tick, reveal = reveal, close = close }
end

return PrizeReveal
