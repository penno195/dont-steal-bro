--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of tasks-catalogue.md #8, `breaker-sequence` - see
-- src/server/TaskHandlers/BreakerSequence.luau for the server half.
-- Built on UI/TaskViewBase and the Sequence input adapter, like
-- CodePlayback.luau: the shell owns the window, close, timer and status
-- line; this file owns the breaker bank.
--
-- A row of breakers on a steel panel (art: UI/TaskArt), each with a
-- glass lamp over its lever. Watching, the lamps flash one at a time in
-- the sequence's order (TaskViewLogic.flash) and the bank is locked.
-- Then the player flips them in that order: a flip the SERVER accepted
-- latches up with a green lamp (the handler's feedback echoes it); a
-- wrong one drops every lever and the same sequence flashes again, or a
-- new one after the server's replay cap (feedback carries it).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local Env = require(script.Parent.Parent.UI.Components.Env)
local InputAdapters = require(script.Parent.Parent.UI.InputAdapters)
local TaskArt = require(script.Parent.Parent.UI.TaskArt)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)
local TaskViewLogic = require(script.Parent.Parent.UI.TaskViewLogic)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local source = vide.source

type Challenge = {
	switchCount: number,
	sequence: { number },
}

type Feedback = {
	accepted: boolean,
	entered: number?,
	switch: number?,
	replay: boolean?,
	sequence: { number }?,
}

local KEY_SIZE = Vector2.new(88, 128)
-- The breakers sit in one row, like a real panel: landscape has the width.
local PLATE_INSET = 18 -- how far the steel panel overhangs the bank
local LEVER_ON_Y = 43
local LEVER_OFF_Y = 56
local PER_SWITCH_SECONDS = 0.6
-- Share of each switch's slot its lamp is lit; the rest is the dark gap.
local FLASH_ON = 0.65
-- Let the sheet finish sliding in before the first flash, or it's missed.
local LEAD_IN = 0.5
-- A beat between a miss and the replay, so the drop reads as a miss.
local REPLAY_PAUSE = 0.8

local LAMP_OFF = Color3.fromHex("#3A3A3A")
local LAMP_FLASH = Color3.fromHex("#FFC83D")
local LAMP_ON = Color3.fromHex("#3DDC84")
local LABEL_INK = Color3.fromHex("#0E1015")

local KEY_CODES: { Enum.KeyCode } = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
	Enum.KeyCode.Seven,
	Enum.KeyCode.Eight,
	Enum.KeyCode.Nine,
}

-- Per-attempt feedback handlers, keyed by the attempt's ctx (see
-- FuseRewire.luau for why onProgress can't reach the sources directly).
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

return TaskViewBase.define({
	taskId = "breaker-sequence",
	title = "Breaker Sequence",
	explainer = "Watch the lamps flash, then flip the breakers in the same order. A wrong flip drops them all and the lamps flash again.",
	-- One row of breakers on the panel (the adapter spaces keys Theme.spacing.md).
	contentSize = function(challenge)
		local n = math.clamp(challenge.switchCount, 1, #KEY_CODES)
		return Vector2.new(n * KEY_SIZE.X + (n - 1) * Theme.spacing.md + 2 * PLATE_INSET, KEY_SIZE.Y + 2 * PLATE_INSET)
	end,

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local switchCount = math.clamp(challenge.switchCount, 1, #KEY_CODES)
		local sequence = challenge.sequence

		-- Watching: the switch whose lamp is lit this instant.
		local flashing: Base.Source<number?> & ((number?) -> number?) = source(nil) :: any
		local watching = source(true)
		-- Entering: the switches the server has accepted.
		local latched: Base.Source<{ [number]: boolean }> & (({ [number]: boolean }) -> { [number]: boolean }) =
			source({}) :: any
		local entered = 0

		local flashStart = os.clock() + LEAD_IN
		local function watch(delay: number)
			flashStart = os.clock() + delay
			flashing(nil)
			watching(true)
			ctx.setStatus("Watch the lamps", "Active")
		end
		watch(LEAD_IN)

		local conn = RunService.Heartbeat:Connect(function()
			if not watching() or os.clock() < flashStart then
				return
			end
			local index, on = TaskViewLogic.flash(os.clock() - flashStart, PER_SWITCH_SECONDS, #sequence, FLASH_ON)
			if index == nil then
				flashing(nil)
				watching(false)
				ctx.setStatus("Flip them in order")
				return
			end
			local lit = if on then sequence[index] else nil
			if lit ~= flashing() then
				flashing(lit)
			end
		end)
		vide.cleanup(function()
			conn:Disconnect()
		end)

		handlers[ctx] = function(feedback: Feedback)
			if feedback.accepted and feedback.switch ~= nil then
				local nextLatched = table.clone(latched())
				nextLatched[feedback.switch] = true
				latched(nextLatched)
				entered = feedback.entered or (entered + 1)
				ctx.setStatus(string.format("%d of %d", entered, #sequence), "Active")
				return
			end
			-- A miss: every lever drops, then the flash runs again.
			latched({})
			entered = 0
			if feedback.sequence ~= nil then
				sequence = feedback.sequence
			end
			ctx.cue("Bad")
			watch(REPLAY_PAUSE)
			ctx.setStatus(if feedback.sequence ~= nil then "New sequence!" else "Wrong, watch again", "Bad")
		end

		local keys: { InputAdapters.SequenceKey } = {}
		for i = 1, switchCount do
			table.insert(keys, { id = tostring(i), label = tostring(i), keyCode = KEY_CODES[i] })
		end

		local function switchVisual(key: InputAdapters.SequenceKey): { Instance }
			local n = tonumber(key.id) :: number
			local isOn = function(): boolean
				return latched()[n] == true
			end
			local lampColour = Env.animate(function(): Color3
				if flashing() == n then
					return LAMP_FLASH
				end
				return if isOn() then LAMP_ON else LAMP_OFF
			end, Theme.motion.fast)
			-- The module art (UI/TaskArt): lamp socket centred 20 down,
			-- lever slot 41..97, number plate 107..119 (reference px).
			return {
				create("ImageLabel")({
					Name = "Breaker",
					BackgroundTransparency = 1,
					Image = TaskArt.image.breaker,
					Size = UDim2.fromScale(1, 1),
					TaskArt.glow({
						size = 64,
						Position = UDim2.fromOffset(KEY_SIZE.X / 2, 20),
						colour = lampColour,
						transparency = function()
							return if flashing() == n or isOn() then 0.3 else 1
						end,
					}) :: Instance,
					TaskArt.lamp({
						name = "Lamp",
						size = 28,
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromOffset(KEY_SIZE.X / 2, 20),
						colour = lampColour,
					}),
					-- The lever, thrown up to ON when latched.
					create("ImageLabel")({
						Name = "Lever",
						BackgroundTransparency = 1,
						Image = TaskArt.image.lever,
						AnchorPoint = Vector2.new(0.5, 0),
						Size = UDim2.fromOffset(36, 40),
						Position = Env.animate(function(): UDim2
							return UDim2.fromOffset(KEY_SIZE.X / 2, if isOn() then LEVER_ON_Y else LEVER_OFF_Y)
						end, Theme.motion.fast),
					}),
					TaskArt.label("label", {
						Name = "Number",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromOffset(KEY_SIZE.X / 2, 113.5),
						Size = UDim2.fromOffset(48, 11),
						Text = key.label,
						TextColor3 = LABEL_INK,
					}),
				}),
			}
		end

		local bank = InputAdapters.Sequence({
			keys = keys,
			columns = switchCount,
			keySize = KEY_SIZE,
			disabled = watching,
			onPress = function(id: string)
				local n = tonumber(id)
				-- A latched breaker is already in; flipping it again is a miss
				-- the player can see coming, so it isn't sent.
				if n == nil or latched()[n] then
					return
				end
				ctx.submit("KeypadDigitSubmit", { digit = n })
				ctx.cue("Active")
			end,
			visual = function(key)
				return switchVisual(key)
			end,
		})
		bank.Name = "BreakerBank"
		bank.AnchorPoint = Vector2.new(0.5, 0.5)
		bank.Position = UDim2.fromScale(0.5, 0.5)
		-- The steel panel the breakers are bolted to, overhanging the bank.
		TaskArt.plate({
			Position = UDim2.fromOffset(-PLATE_INSET, -PLATE_INSET),
			Size = UDim2.new(1, 2 * PLATE_INSET, 1, 2 * PLATE_INSET),
			ZIndex = 0,
		}).Parent =
			bank

		-- Shrink-only fit to the play area (see CodePlayback.luau's pads),
		-- counting the panel's overhang.
		local fitScale = create("UIScale")({ Parent = bank }) :: UIScale
		local function fit()
			local room = ctx.area.AbsoluteSize
			local native = bank.AbsoluteSize / fitScale.Scale + Vector2.one * 2 * PLATE_INSET * Env.scale()
			if room.X <= 0 or room.Y <= 0 or native.X <= 0 or native.Y <= 0 then
				return
			end
			local scale = math.min(1, room.X / native.X, room.Y / native.Y)
			if math.abs(scale - fitScale.Scale) > 0.001 then
				fitScale.Scale = scale
			end
		end
		local sizeChanged = ctx.area:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
		vide.cleanup(function()
			sizeChanged:Disconnect()
		end)
		task.defer(fit)

		return { bank :: Instance }
	end,

	onProgress = function(ctx, feedback)
		local handle = handlers[ctx]
		if handle ~= nil and type(feedback) == "table" then
			handle(feedback :: Feedback)
		end
	end,
})
