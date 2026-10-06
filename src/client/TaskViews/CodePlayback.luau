--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of the P2-5 reference task (tasks-catalogue.md #9,
-- `code-playback`) - see src/server/TaskHandlers/CodePlayback.luau for
-- the server half and src/shared/Config/Tasks/CodePlayback.luau for the
-- shared definition.
--
-- P6-4 rebuilt this on UI/TaskViewBase as the proof that the base
-- carries the shared decisions: everything that isn't specific to "watch
-- a code, then type it" - the sheet/window, the input lock, close and
-- abort, the timer, the status line, the edge margin - is gone from this
-- file. What's left is the task: flash the digits, then a Sequence
-- keypad (UI/InputAdapters) that reports each press to the server.
-- docs/task-views.md walks through this file as its worked example.
--
-- The display is a calculator LCD with one cell per digit. Watching,
-- each digit lights in its own cell and goes dark before the next
-- (TaskViewLogic.flash), so 9999 reads as four flashes marching across,
-- never one long 9. Entering, the cells fill with the digits the SERVER
-- accepted (the handler's feedback echoes each press), and a wrong one
-- shows ERR and clears.
--
-- Layout: the LCD on top (read, not touched), the keypad at the bottom
-- of the play area where a one-handed thumb lives. The keypad owns only
-- the space BELOW the display and shrinks to fit it: on a short play
-- area (a landscape phone, a small Studio viewport) a full-size pad
-- pinned to the bottom used to cover the code.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local ComponentLogic = require(script.Parent.Parent.UI.Components.ComponentLogic)
local Env = require(script.Parent.Parent.UI.Components.Env)
local InputAdapters = require(script.Parent.Parent.UI.InputAdapters)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)
local TaskViewLogic = require(script.Parent.Parent.UI.TaskViewLogic)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local derive = vide.derive
local source = vide.source

type Challenge = {
	code: { number },
	displaySeconds: number,
}

type Feedback = {
	accepted: boolean,
	entered: number,
	digit: number,
}

local KEY_SIZE = Vector2.new(88, 72)
local DISPLAY_HEIGHT = Theme.spacing.xxxl + Theme.spacing.lg
local CELL_WIDTH = 44
-- Share of each digit's slot it's lit for; the rest is the dark gap.
local FLASH_ON = 0.65
-- Let the sheet finish sliding in before the first digit, or it's missed.
local LEAD_IN = 0.5
local ERROR_SECONDS = 0.7

-- Classic reflective LCD: grey-green glass, near-black segments, and an
-- unlit "8" ghost behind every cell like real segment displays have.
local LCD_GLASS = Color3.fromHex("#9FB08E")
local LCD_INK = Color3.fromHex("#18210F")
local LCD_FONT = Font.fromEnum(Enum.Font.Arcade)

-- Phone-keypad order: 1-9, then 0 alone on the last row.
local DIGIT_KEYS: { Enum.KeyCode } = {
	Enum.KeyCode.Zero,
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
local KEYS: { InputAdapters.SequenceKey } = {}
for _, digit in { 1, 2, 3, 4, 5, 6, 7, 8, 9, 0 } do
	table.insert(KEYS, { id = tostring(digit), label = tostring(digit), keyCode = DIGIT_KEYS[digit + 1] })
end

-- Per-attempt feedback handlers, keyed by the attempt's ctx (see
-- FuseRewire.luau for why onProgress can't reach the sources directly).
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

local function keyVisual(key: InputAdapters.SequenceKey, state: Base.Source<Base.State>): { Instance }
	local style = derive(function()
		return ComponentLogic.variantStyle("secondary", state())
	end)
	return {
		create("Frame")({
			Name = "Surface",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Env.animate(function(): Color3
				return Theme.color[style().fill]
			end, Theme.motion.fast),
			Base.corner(Theme.radius.md),
			-- The idle fill matches the card; the outline makes it a key.
			create("UIStroke")({
				BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = Theme.color.line,
				Thickness = 2,
			}),
			Base.text("headline", {
				Size = UDim2.fromScale(1, 1),
				Text = key.label,
				TextColor3 = function()
					return Theme.color[style().ink]
				end,
			}),
		}),
	}
end

local function lcdText(props: { [any]: any }): TextLabel
	local merged: { [any]: any } = {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		FontFace = LCD_FONT,
		TextScaled = true,
		TextColor3 = LCD_INK,
	}
	for k, v in props do
		merged[k] = v
	end
	return create("TextLabel")(merged) :: TextLabel
end

return TaskViewBase.define({
	taskId = "code-playback",
	title = "Code Playback",
	explainer = "Watch the code flash up, one digit per box, then type it on the keypad. A wrong digit clears it and you start again.",

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local count = #challenge.code
		local perDigit = challenge.displaySeconds / math.max(1, count)

		-- Watching: which cell is up and whether it's lit this instant.
		local showing: Base.Source<number?> & ((number?) -> number?) = source(nil) :: any
		local lit = source(false)
		local entering = source(false)
		-- Entering: the digits the server has accepted, in order.
		local typed: Base.Source<{ number }> & (({ number }) -> { number }) = source({}) :: any
		local showError = source(false)
		local errorSerial = 0

		ctx.setStatus("Watch", "Active")
		local startedAt = os.clock() + LEAD_IN
		local flashConn: RBXScriptConnection
		flashConn = RunService.Heartbeat:Connect(function()
			local index, on = TaskViewLogic.flash(os.clock() - startedAt, perDigit, count, FLASH_ON)
			if index == nil and os.clock() >= startedAt then
				flashConn:Disconnect()
				showing(nil)
				lit(false)
				entering(true)
				ctx.setStatus("Enter the code")
				return
			end
			if index ~= showing() then
				showing(index)
			end
			if on ~= lit() then
				lit(on)
			end
		end)
		vide.cleanup(function()
			flashConn:Disconnect()
		end)

		handlers[ctx] = function(feedback: Feedback)
			if feedback.accepted then
				local nextTyped = table.clone(typed())
				-- `entered` is authoritative: trim to it before appending.
				while #nextTyped >= feedback.entered do
					table.remove(nextTyped)
				end
				table.insert(nextTyped, feedback.digit)
				typed(nextTyped)
				ctx.setStatus(string.format("%d of %d", #nextTyped, count), "Active")
			else
				typed({})
				errorSerial += 1
				local mine = errorSerial
				showError(true)
				task.delay(ERROR_SECONDS, function()
					if mine == errorSerial then
						showError(false)
					end
				end)
				ctx.setStatus("Wrong, start again", "Bad")
				ctx.cue("Bad")
			end
		end

		local function cellText(i: number): string
			if entering() then
				local digit = typed()[i]
				return if digit ~= nil then tostring(digit) else ""
			end
			return if showing() == i and lit() then tostring(challenge.code[i]) else ""
		end

		local cells: { Instance } = {}
		for i = 1, count do
			table.insert(
				cells,
				create("Frame")({
					Name = "Cell" .. i,
					LayoutOrder = i,
					BackgroundTransparency = 1,
					Size = UDim2.new(0, CELL_WIDTH, 1, 0),
					-- The unlit segment ghost.
					lcdText({
						Name = "Ghost",
						Text = "8",
						TextTransparency = 0.93,
						Visible = function()
							return not showError()
						end,
					}),
					lcdText({
						Name = "Digit",
						Text = function()
							return cellText(i)
						end,
						Visible = function()
							return not showError()
						end,
					}),
					-- Cursor under the cell the code is up to (or the next to type).
					create("Frame")({
						Name = "Cursor",
						AnchorPoint = Vector2.new(0.5, 1),
						Position = UDim2.new(0.5, 0, 1, 2),
						Size = UDim2.new(0.8, 0, 0, 3),
						BorderSizePixel = 0,
						BackgroundColor3 = LCD_INK,
						BackgroundTransparency = function()
							local here = if entering() then #typed() + 1 == i else showing() == i
							return if here and not showError() then 0.2 else 1
						end,
					}),
				})
			)
		end

		local lcd = create("Frame")({
			Name = "CodeDisplay",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromOffset(
				count * CELL_WIDTH + (count - 1) * Theme.spacing.sm + 2 * Theme.spacing.lg,
				DISPLAY_HEIGHT
			),
			BackgroundColor3 = Theme.color.surface,
			Base.corner(Theme.radius.md),
			create("UIPadding")({
				PaddingTop = UDim.new(0, Theme.spacing.sm),
				PaddingBottom = UDim.new(0, Theme.spacing.sm),
				PaddingLeft = UDim.new(0, Theme.spacing.sm),
				PaddingRight = UDim.new(0, Theme.spacing.sm),
			}),
			create("Frame")({
				Name = "Glass",
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = LCD_GLASS,
				Base.corner(Theme.radius.sm),
				create("UIStroke")({
					BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Color = LCD_INK,
					Transparency = 0.6,
					Thickness = 2,
				}),
				create("UIPadding")({
					PaddingTop = UDim.new(0, Theme.spacing.xs),
					PaddingBottom = UDim.new(0, Theme.spacing.sm),
				}),
				create("Frame")({
					Name = "Cells",
					BackgroundTransparency = 1,
					Size = UDim2.fromScale(1, 1),
					create("UIListLayout")({
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = UDim.new(0, Theme.spacing.sm),
					}),
					cells,
				}),
				lcdText({
					Name = "Error",
					Text = "ERR",
					Visible = showError,
				}),
			}),
		}) :: Frame
		-- 4 cells come to ~232 reference px; the narrowest play area (a
		-- 270-point phone at the 0.75 scale floor) is ~312, so no fit pass.

		local keypadArea = create("Frame")({
			Name = "KeypadArea",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, DISPLAY_HEIGHT + Theme.spacing.sm),
			Size = UDim2.new(1, 0, 1, -(DISPLAY_HEIGHT + Theme.spacing.sm)),
		}) :: Frame

		-- Two pads, one shown: a phone-style 3x4 when the room under the
		-- LCD is tall, a 5x2 when it's short and wide (a monitor's window,
		-- a landscape phone) - where a 3x4 shrinks to keys too small to hit.
		-- The hidden pad is disabled, so a keyboard digit fires only once.
		local wide = source(false)
		local fits: { () -> number } = {}
		local function pad(columns: number, isWide: boolean): Frame
			local active = function()
				return wide() == isWide
			end
			local grid = InputAdapters.Sequence({
				keys = KEYS,
				columns = columns,
				keySize = KEY_SIZE,
				disabled = function()
					return not entering() or not active()
				end,
				onPress = function(id: string)
					-- The server alone knows whether that digit was right;
					-- the LCD fills in when its feedback lands.
					ctx.submit("KeypadDigitSubmit", { digit = tonumber(id) })
					ctx.cue("Active")
				end,
				visual = function(key, state)
					return keyVisual(key, state)
				end,
			})
			grid.Name = if isWide then "WideKeypad" else "Keypad"
			grid.AnchorPoint = Vector2.new(0.5, 1)
			grid.Position = UDim2.fromScale(0.5, 1)
			vide.effect(function()
				grid.Visible = active()
			end)
			-- Shrink-only fit. Both absolute sizes carry the same
			-- ancestor scaling, so their ratio is scale-independent;
			-- the grid's own UIScale is divided back out first.
			local fitScale = create("UIScale")({ Parent = grid }) :: UIScale
			-- Returns the scale it settled on, so relayout can compare pads.
			table.insert(fits, function(): number
				local room, native = keypadArea.AbsoluteSize, grid.AbsoluteSize / fitScale.Scale
				if room.X <= 0 or room.Y <= 0 or native.X <= 0 or native.Y <= 0 then
					return 0
				end
				local scale = math.min(1, room.X / native.X, room.Y / native.Y)
				if math.abs(scale - fitScale.Scale) > 0.001 then
					fitScale.Scale = scale
				end
				return scale
			end)
			grid.Parent = keypadArea
			return grid
		end
		pad(3, false)
		pad(5, true)

		-- Whichever pad keeps its keys bigger wins; the familiar phone
		-- layout unless the wide one is clearly better.
		local function relayout()
			local tall, wideScale = fits[1](), fits[2]()
			if tall > 0 then
				wide(wideScale > tall * 1.15)
			end
		end
		local sizeChanged = keypadArea:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
		vide.cleanup(function()
			sizeChanged:Disconnect()
		end)
		task.defer(relayout)

		return { lcd :: Instance, keypadArea :: Instance }
	end,

	onProgress = function(ctx, feedback)
		local handle = handlers[ctx]
		if handle ~= nil and type(feedback) == "table" then
			handle(feedback :: Feedback)
		else
			ctx.setStatus("Keep going", "Active")
		end
	end,
})
