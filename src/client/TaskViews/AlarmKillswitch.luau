--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of the Hold reference task (tasks-catalogue.md #3,
-- `alarm-killswitch`) - see src/server/TaskHandlers/AlarmKillswitch.luau
-- for the server half. Built on UI/TaskViewBase like PressureValve.luau:
-- the shell owns the window, close, timer and status line; this file
-- owns the beacon, the KILL button and the hold bar.
--
-- A red alarm beacon flashes over a big mushroom KILL button. Press and
-- the bar under it fills over the rolled hold length; let go before it
-- is full and it empties (the server says so too - `early`). When the
-- bar fills the view lets go for the player, a hair past full so
-- network jitter never makes an honest hold look short, and the beacon
-- goes dark. The bar is a client-side picture of the server's clock,
-- never read back for validation: only the press/release edges travel.
--
-- The button is Base.interactive's job everywhere else, but it only
-- reports a finished tap; Hold needs the press and the release, so this
-- view watches its own input. The release is caught on UserInputService,
-- not the button, so a thumb that slides off before lifting still ends
-- the hold rather than leaving it stuck down.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local Env = require(script.Parent.Parent.UI.Components.Env)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local source = vide.source

type Challenge = {
	holdSeconds: number,
}

type Feedback = {
	holding: boolean,
	early: boolean?,
}

-- Reference px. layout() scales the whole stack to fit the area.
local BEACON = 56
local BUTTON = 150
local BAR = 12
local GAP = Theme.spacing.md
-- Released for the player this long past a full bar (see header).
local RELEASE_MARGIN_SECONDS = 0.1
local FLASH_RATE = 4 -- beacon flashes per second while the alarm blares
local BEACON_ON = Color3.fromHex("#FF3B30")
local BEACON_OFF = Color3.fromHex("#4A1512")
local BUTTON_RIM = Color3.fromHex("#5A0F14")

-- Per-attempt feedback handlers, keyed by the attempt's ctx (see
-- FuseRewire.luau for why onProgress can't reach the sources directly).
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

local function isPress(input: InputObject): boolean
	local t = input.UserInputType
	return t == Enum.UserInputType.MouseButton1
		or t == Enum.UserInputType.Touch
		or input.KeyCode == Enum.KeyCode.ButtonA
		or input.KeyCode == Enum.KeyCode.Return
end

return TaskViewBase.define({
	taskId = "alarm-killswitch",
	title = "Alarm Killswitch",
	explainer = "Press and HOLD the KILL button until the bar fills. Let go early and it resets.",

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local holdSeconds = math.max(0.5, challenge.holdSeconds)

		local pressInput: InputObject? = nil -- the touch/click holding it down
		local pressedAt = 0
		local finishing = false -- released for the player; waiting on the server
		local silenced = false
		local fill = source(0)
		local held = source(false)

		local function press(input: InputObject)
			if pressInput ~= nil or finishing or silenced then
				return
			end
			pressInput = input
			pressedAt = os.clock()
			held(true)
			ctx.submit("HoldSubmit", { pressed = true })
			ctx.setStatus("Keep holding...", "Active")
		end

		local function release(early: boolean)
			if pressInput == nil then
				return
			end
			pressInput = nil
			held(false)
			ctx.submit("HoldSubmit", { pressed = false })
			if early then
				fill(0)
				ctx.setStatus("Let go too soon", "Bad")
				ctx.cue("Bad")
			else
				finishing = true
			end
		end

		local endConn = UserInputService.InputEnded:Connect(function(input)
			local current = pressInput
			if current == nil then
				return
			end
			-- A touch is its own InputObject; a mouse or key matches by kind.
			local same = (input :: any) == current
				or (
					input.UserInputType ~= Enum.UserInputType.Touch
					and input.UserInputType == current.UserInputType
					and input.KeyCode == current.KeyCode
				)
			if same then
				release(true)
			end
		end)

		local beacon = create("Frame")({
			Name = "Beacon",
			AnchorPoint = Vector2.new(0.5, 0),
			BackgroundColor3 = BEACON_ON,
			Base.corner(Theme.radius.pill),
			create("UIStroke")({ Color = BUTTON_RIM, Thickness = 3 }),
		}) :: Frame

		local startedAt = os.clock()
		local conn = RunService.Heartbeat:Connect(function()
			local now = os.clock()
			if pressInput ~= nil then
				local t = now - pressedAt
				fill(math.clamp(t / holdSeconds, 0, 1))
				if t >= holdSeconds + RELEASE_MARGIN_SECONDS then
					release(false)
				end
			end
			-- Flashes until silenced; a steady glow under reduced motion.
			if silenced then
				beacon.BackgroundColor3 = BEACON_OFF
			elseif Env.reducedMotion() then
				beacon.BackgroundColor3 = BEACON_ON
			else
				local on = math.floor((now - startedAt) * FLASH_RATE * 2) % 2 == 0
				beacon.BackgroundColor3 = if on then BEACON_ON else BEACON_OFF
			end
		end)
		vide.cleanup(function()
			conn:Disconnect()
			endConn:Disconnect()
		end)

		handlers[ctx] = function(feedback: Feedback)
			if feedback.holding or not feedback.early then
				if not feedback.holding then
					-- The server counted it: the alarm dies before "Done!".
					silenced = true
					fill(1)
					ctx.setStatus("Alarm off!", "Good")
				end
				return
			end
			-- Early by the server's clock: our own release already reset
			-- the bar, unless we let go for the player and jitter ate the
			-- margin - then it's on us, so just ask again without a buzz.
			if finishing then
				finishing = false
				fill(0)
				ctx.setStatus("Hold it again", "Active")
			end
		end

		ctx.setStatus("Hold KILL to silence it")

		local bar = create("Frame")({
			Name = "HoldBar",
			AnchorPoint = Vector2.new(0.5, 0),
			BackgroundColor3 = Theme.color.surface,
			Base.corner(Theme.radius.pill),
			create("Frame")({
				Name = "Fill",
				BorderSizePixel = 0,
				Size = function()
					return UDim2.fromScale(fill(), 1)
				end,
				BackgroundColor3 = function()
					return if fill() >= 1 then Theme.color.success else Theme.color.warning
				end,
				Base.corner(Theme.radius.pill),
			}),
		}) :: Frame

		local button = create("TextButton")({
			Name = "KillButton",
			Text = "",
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(0.5, 0),
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(BUTTON, BUTTON),
			InputBegan = function(input: InputObject)
				if isPress(input) then
					press(input)
				end
			end,
			create("Frame")({
				Name = "Surface",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				-- Pushed in while held, like a real mushroom button.
				Size = function()
					return if held() then UDim2.fromScale(0.92, 0.92) else UDim2.fromScale(1, 1)
				end,
				BackgroundColor3 = Theme.color.danger,
				Base.corner(Theme.radius.pill),
				create("UIStroke")({
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Color = BUTTON_RIM,
					Thickness = 6,
				}),
				create("UIGradient")({
					Rotation = 90,
					Color = function()
						local low = if held() then Color3.fromRGB(140, 140, 140) else Color3.fromRGB(170, 170, 170)
						return ColorSequence.new(Color3.new(1, 1, 1), low)
					end,
				}),
				Base.text("headline", {
					Size = UDim2.fromScale(1, 1),
					Text = "KILL",
					TextColor3 = Theme.color.onDanger,
				}),
			}),
		}) :: TextButton

		-- Beacon, button and bar stacked and centred, scaled down as one
		-- when the area is short (a monitor's window is ~260 reference px).
		local stack = create("Frame")({
			Name = "Panel",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(BUTTON, BEACON + GAP + BUTTON + GAP + BAR),
		}) :: Frame
		local fit = create("UIScale")({ Parent = stack }) :: UIScale
		beacon.Size = UDim2.fromOffset(BEACON, BEACON)
		beacon.Position = UDim2.fromScale(0.5, 0)
		beacon.Parent = stack
		button.Position = UDim2.new(0.5, 0, 0, BEACON + GAP)
		button.Parent = stack
		bar.Size = UDim2.fromOffset(BUTTON, BAR)
		bar.Position = UDim2.new(0.5, 0, 0, BEACON + GAP + BUTTON + GAP)
		bar.Parent = stack

		local function layout()
			local s = Env.scale()
			local size = ctx.area.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 or s <= 0 then
				return
			end
			local w, h = size.X / s, size.Y / s
			local natural = stack.Size.Y.Offset
			-- Shrinks to fit; never grows past 1.4x so it stays thumb-sized.
			fit.Scale = math.min(w / BUTTON, h / natural, 1.4)
		end
		local areaChanged = ctx.area:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		vide.cleanup(function()
			areaChanged:Disconnect()
		end)
		vide.effect(function()
			Env.scale() -- re-lay on a scale change too
			task.defer(layout)
		end)

		return { stack :: Instance }
	end,

	onProgress = function(ctx, feedback)
		local handle = handlers[ctx]
		if handle ~= nil and type(feedback) == "table" then
			handle(feedback :: Feedback)
		end
	end,
})
