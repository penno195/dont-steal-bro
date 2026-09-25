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
-- Layout: the digit display on top (read, not touched), the keypad at
-- the bottom of the play area where a one-handed thumb lives. The
-- keypad owns only the space BELOW the display and shrinks to fit it:
-- on a short play area (a landscape phone, a small Studio viewport) a
-- full-size pad pinned to the bottom used to cover the code.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local ComponentLogic = require(script.Parent.Parent.UI.Components.ComponentLogic)
local Env = require(script.Parent.Parent.UI.Components.Env)
local InputAdapters = require(script.Parent.Parent.UI.InputAdapters)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local derive = vide.derive
local source = vide.source

type Challenge = {
	code: { number },
	displaySeconds: number,
}

local KEY_SIZE = Vector2.new(88, 72)
local DISPLAY_HEIGHT = Theme.spacing.xxxl + Theme.spacing.lg

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

return TaskViewBase.define({
	taskId = "code-playback",
	title = "Code Playback",

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		local display = source("")
		local entering = source(false)

		-- Flash each digit, then open the keypad. Cancelled with the view:
		-- the thread checks `alive` rather than being task.cancel'd, so a
		-- close mid-wait can't leave a half-written source behind.
		local alive = true
		vide.cleanup(function()
			alive = false
		end)
		ctx.setStatus("Watch", "Active")
		task.spawn(function()
			local perDigit = challenge.displaySeconds / math.max(1, #challenge.code)
			for _, digit in challenge.code do
				if not alive then
					return
				end
				display(tostring(digit))
				task.wait(perDigit)
			end
			if alive then
				display("")
				entering(true)
				ctx.setStatus("Enter the code")
			end
		end)

		local lastPressed = source("")

		return {
			Base.text("display", {
				Name = "CodeDisplay",
				Size = UDim2.new(1, 0, 0, DISPLAY_HEIGHT),
				-- While entering, echoes the last key pressed so a player sees
				-- the press registered without hearing it. Not a running
				-- code: the client can't know if a wrong digit reset progress.
				Text = function()
					return if entering() then lastPressed() else display()
				end,
				TextColor3 = function()
					return if entering() then Theme.color.inkMuted else Theme.color.ink
				end,
			}) :: Instance,
			(function()
				local grid = InputAdapters.Sequence({
					keys = KEYS,
					columns = 3,
					keySize = KEY_SIZE,
					disabled = function()
						return not entering()
					end,
					onPress = function(id: string)
						-- The server alone knows whether that digit was right.
						ctx.submit("KeypadDigitSubmit", { digit = tonumber(id) })
						lastPressed(id)
						ctx.cue("Active")
					end,
					visual = function(key, state)
						return keyVisual(key, state)
					end,
				})
				grid.AnchorPoint = Vector2.new(0.5, 1)
				grid.Position = UDim2.fromScale(0.5, 1)

				local keypadArea = create("Frame")({
					Name = "KeypadArea",
					BackgroundTransparency = 1,
					Position = UDim2.fromOffset(0, DISPLAY_HEIGHT + Theme.spacing.sm),
					Size = UDim2.new(1, 0, 1, -(DISPLAY_HEIGHT + Theme.spacing.sm)),
				}) :: Frame
				-- Shrink-only fit. Both absolute sizes carry the same
				-- ancestor scaling, so their ratio is scale-independent;
				-- the grid's own UIScale is divided back out first.
				local fitScale = create("UIScale")({ Parent = grid }) :: UIScale
				local function fit()
					local room, native = keypadArea.AbsoluteSize, grid.AbsoluteSize / fitScale.Scale
					if room.X <= 0 or room.Y <= 0 or native.X <= 0 or native.Y <= 0 then
						return
					end
					local scale = math.min(1, room.X / native.X, room.Y / native.Y)
					if math.abs(scale - fitScale.Scale) > 0.001 then
						fitScale.Scale = scale
					end
				end
				local sizeChanged = keypadArea:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
				vide.cleanup(function()
					sizeChanged:Disconnect()
				end)
				grid.Parent = keypadArea
				task.defer(fit)
				return keypadArea :: Instance
			end)(),
		}
	end,

	-- A non-final result can't say whether that digit was right but not
	-- the last, or wrong (progress reset) - TaskResult carries only the
	-- whole attempt's outcome. So it never claims "wrong".
	onProgress = function(ctx)
		ctx.setStatus("Keep going", "Active")
	end,
})
