--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of the Hold reference task (tasks-catalogue.md #3,
-- `alarm-killswitch`) - see src/server/TaskHandlers/AlarmKillswitch.luau
-- for the server half. Built on UI/TaskViewBase like PressureValve.luau:
-- the shell owns the window, close, timer and status line; this file
-- owns the siren, the KILL button and its ring of lamps.
--
-- A steel panel (art: UI/TaskArt) with a red siren flashing on top and a
-- big mushroom KILL button in a hazard-striped collar, labelled PRESS &
-- HOLD. Between the collar and the button a ring of lamps is the hold
-- meter: press and they light amber one by one round the ring over the
-- rolled hold length; let go before the ring is full and it goes dark
-- (the server says so too - `early`). Until the first press a halo
-- breathes behind the button, so it reads as "this is the thing". When
-- the ring fills the view lets go for the player, a hair past full so
-- network jitter never makes an honest hold look short, the ring turns
-- green and the siren dies. The ring is a client-side picture of the
-- server's clock, never read back for validation: only the press/release
-- edges travel.
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

local Env = require(script.Parent.Parent.UI.Components.Env)
local TaskArt = require(script.Parent.Parent.UI.TaskArt)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)

local create = vide.create
local source = vide.source

type Challenge = {
	holdSeconds: number,
}

type Feedback = {
	holding: boolean,
	early: boolean?,
}

-- Reference px; the art is drawn at 2x these. layout() scales the panel.
local PLATE = Vector2.new(240, 280)
local SIREN = 72
local SIREN_OVERLAP = 20 -- the siren's base sits on the plate's top edge
local WELL = Vector2.new(120, 116) -- the button's centre on the plate
local BUTTON = 120
local RING_RADIUS = 71.5 -- between the collar and the button
local LAMPS = 24
local LAMP = 12
local WIDTH = PLATE.X
local HEIGHT = SIREN - SIREN_OVERLAP + PLATE.Y
-- Released for the player this long past a full ring (see header).
local RELEASE_MARGIN_SECONDS = 0.1
local FLASH_RATE = 4 -- siren flashes per second while the alarm blares
local SIREN_ON = Color3.new(1, 1, 1)
local SIREN_OFF = Color3.fromRGB(95, 80, 80)
local SIREN_GLOW = Color3.fromHex("#FF3B30")
local LAMP_OFF = Color3.fromHex("#3A3F48")
local LAMP_HOLD = Color3.fromHex("#FFC53D")
local LAMP_DONE = Color3.fromHex("#3CCB7F")
local BUTTON_HELD = Color3.fromRGB(200, 200, 200)
local BREATHE_RATE = 1.6 -- the idle halo's breaths per second

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
	explainer = "Press and HOLD the red KILL button until the ring of lights is full. Let go early and it resets.",
	contentSize = Vector2.new(WIDTH, HEIGHT),

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local holdSeconds = math.max(0.5, challenge.holdSeconds)

		local pressInput: InputObject? = nil -- the touch/click holding it down
		local pressedAt = 0
		local finishing = false -- released for the player; waiting on the server
		local everPressed = false
		local fill = source(0)
		local held = source(false)
		local silenced = source(false)
		local sirenLit = source(true)
		local breath = source(0) -- 0..1, the idle halo

		local function press(input: InputObject)
			if pressInput ~= nil or finishing or silenced() then
				return
			end
			pressInput = input
			pressedAt = os.clock()
			everPressed = true
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
				ctx.setStatus("Let go too soon - hold it longer", "Bad")
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
			local still = Env.reducedMotion()
			sirenLit(not silenced() and (still or math.floor((now - startedAt) * FLASH_RATE * 2) % 2 == 0))
			breath(
				if everPressed or still then 0 else 0.5 - 0.5 * math.cos((now - startedAt) * BREATHE_RATE * 2 * math.pi)
			)
		end)
		vide.cleanup(function()
			conn:Disconnect()
			endConn:Disconnect()
		end)

		handlers[ctx] = function(feedback: Feedback)
			if feedback.holding or not feedback.early then
				if not feedback.holding then
					-- The server counted it: the alarm dies before "Done!".
					silenced(true)
					fill(1)
					ctx.setStatus("Alarm off!", "Good")
				end
				return
			end
			-- Early by the server's clock: our own release already reset
			-- the ring, unless we let go for the player and jitter ate the
			-- margin - then it's on us, so just ask again without a buzz.
			if finishing then
				finishing = false
				fill(0)
				ctx.setStatus("Hold it again", "Active")
			end
		end

		ctx.setStatus("Press and hold KILL")

		-- The hold meter: lamp i lights once the fill passes its share,
		-- clockwise from the top.
		local ring: { Instance } = {}
		for i = 1, LAMPS do
			local angle = (i - 0.5) / LAMPS * 2 * math.pi
			table.insert(
				ring,
				TaskArt.lamp({
					name = "Lamp" .. i,
					size = LAMP,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset(
						WELL.X + RING_RADIUS * math.sin(angle),
						WELL.Y - RING_RADIUS * math.cos(angle)
					),
					ZIndex = 2,
					colour = function()
						if silenced() then
							return LAMP_DONE
						end
						return if fill() * LAMPS >= i - 0.5 then LAMP_HOLD else LAMP_OFF
					end,
				})
			)
		end

		local button = create("ImageButton")({
			Name = "KillButton",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Image = "",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(WELL.X, WELL.Y),
			Size = UDim2.fromOffset(BUTTON, BUTTON),
			ZIndex = 3,
			InputBegan = function(input: InputObject)
				if isPress(input) then
					press(input)
				end
			end,
			TaskArt.glow({
				size = BUTTON * 1.5,
				Position = UDim2.fromScale(0.5, 0.5),
				colour = Color3.fromHex("#FFE2B0"),
				transparency = function()
					return 1 - breath() * 0.6
				end,
			}),
			create("ImageLabel")({
				Name = "Cap",
				BackgroundTransparency = 1,
				Image = TaskArt.image.killButton,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				-- Pushed in while held, like a real mushroom button.
				Size = function()
					return if held() then UDim2.fromScale(0.9, 0.9) else UDim2.fromScale(1, 1)
				end,
				ImageColor3 = function()
					return if held() then BUTTON_HELD else Color3.new(1, 1, 1)
				end,
			}),
		}) :: ImageButton
		table.insert(ring, button)

		local plate = create("ImageLabel")({
			Name = "Plate",
			BackgroundTransparency = 1,
			Image = TaskArt.image.killPlate,
			Position = UDim2.fromOffset(0, SIREN - SIREN_OVERLAP),
			Size = UDim2.fromOffset(PLATE.X, PLATE.Y),
			ring,
		}) :: ImageLabel

		local panel = create("Frame")({
			Name = "Panel",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(WIDTH, HEIGHT),
			TaskArt.glow({
				size = SIREN * 2.2,
				Position = UDim2.fromOffset(WIDTH / 2, SIREN * 0.45),
				colour = SIREN_GLOW,
				transparency = function()
					return if sirenLit() then 0.35 else 1
				end,
			}),
			plate,
			create("ImageLabel")({
				Name = "Siren",
				BackgroundTransparency = 1,
				Image = TaskArt.image.siren,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromOffset(WIDTH / 2, 0),
				Size = UDim2.fromOffset(SIREN, SIREN),
				ZIndex = 2,
				ImageColor3 = function()
					return if sirenLit() then SIREN_ON else SIREN_OFF
				end,
			}),
		}) :: Frame

		local fit = create("UIScale")({ Parent = panel }) :: UIScale
		local function layout()
			local s = Env.scale()
			local size = ctx.area.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 or s <= 0 then
				return
			end
			-- Shrinks to fit; never grows past 1.3x so it stays crisp.
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
