--!strict
-- The client half of the P2-5 reference task (tasks-catalogue.md #9,
-- `code-playback`) - see src/server/TaskHandlers/CodePlayback.luau for
-- the server half and src/shared/Config/Tasks/CodePlayback.luau for the
-- shared definition. Plain Roblox Instances, not a UI framework -
-- architecture.md's UI framework choice (React-lua/Fusion/Vide) is still
-- an open decision (see its own "Decisions to lock in week 1" table),
-- and this task shouldn't make that call unilaterally on the way to
-- proving the task-framework contract works end to end. If the team
-- locks in a framework later, only this file's internals need to
-- change - the TaskView contract (Types.luau) it implements doesn't
-- care how the UI is built.
--
-- Root frame is anchored low-center (Position Y 0.72) rather than
-- centered - CLAUDE.md's mobile-first, one-thumb constraint means a
-- player's thumb lives in the lower half of a portrait phone screen, not
-- the middle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.Shared.Net)

local LocalPlayer = Players.LocalPlayer

type Challenge = {
	code: { number },
	displaySeconds: number,
}

local screenGui: ScreenGui? = nil
local promptLabel: TextLabel? = nil
local statusLabel: TextLabel? = nil
local keypadFrame: Frame? = nil
local activeStationId: string? = nil
local flashThread: thread? = nil

local function buildGui(): ScreenGui
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "CodePlaybackView"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.IgnoreGuiInset = true

	local frame = Instance.new("Frame")
	frame.Name = "Root"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.72)
	frame.Size = UDim2.fromOffset(280, 220)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.1
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local prompt = Instance.new("TextLabel")
	prompt.Name = "Prompt"
	prompt.Size = UDim2.new(1, 0, 0, 40)
	prompt.Position = UDim2.fromOffset(0, 8)
	prompt.BackgroundTransparency = 1
	prompt.TextColor3 = Color3.new(1, 1, 1)
	prompt.TextScaled = true
	prompt.Font = Enum.Font.GothamBold
	prompt.Text = ""
	prompt.Parent = frame

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Size = UDim2.new(1, 0, 0, 24)
	status.Position = UDim2.fromOffset(0, 48)
	status.BackgroundTransparency = 1
	status.TextColor3 = Color3.fromRGB(200, 200, 200)
	status.TextScaled = true
	status.Font = Enum.Font.Gotham
	status.Text = ""
	status.Parent = frame

	local keypad = Instance.new("Frame")
	keypad.Name = "Keypad"
	keypad.Size = UDim2.new(1, -16, 1, -84)
	keypad.Position = UDim2.fromOffset(8, 76)
	keypad.BackgroundTransparency = 1
	keypad.Visible = false
	keypad.Parent = frame

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromScale(0.31, 0.31)
	layout.CellPadding = UDim2.fromScale(0.03, 0.03)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = keypad

	for digit = 0, 9 do
		local button = Instance.new("TextButton")
		button.Name = string.format("Digit_%d", digit)
		button.Text = tostring(digit)
		button.LayoutOrder = digit
		button.TextScaled = true
		button.Font = Enum.Font.GothamBold
		button.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
		button.TextColor3 = Color3.new(1, 1, 1)
		button.AutoButtonColor = true
		button.Parent = keypad

		local buttonCorner = Instance.new("UICorner")
		buttonCorner.CornerRadius = UDim.new(0, 8)
		buttonCorner.Parent = button

		-- Server is the only source of truth for whether this digit was
		-- right - this button does nothing but report the tap.
		button.Activated:Connect(function()
			if activeStationId == nil then
				return
			end
			Net.fireServer("KeypadDigitSubmit", { stationId = activeStationId, digit = digit })
		end)
	end

	gui.Parent = playerGui

	promptLabel = prompt
	statusLabel = status
	keypadFrame = keypad

	return gui
end

local function ensureGui(): ScreenGui
	if screenGui == nil then
		screenGui = buildGui()
	end
	return screenGui :: ScreenGui
end

local function cancelFlash()
	if flashThread ~= nil then
		task.cancel(flashThread)
		flashThread = nil
	end
end

local function show(stationId: string, challenge: any)
	local typedChallenge = challenge :: Challenge
	local gui = ensureGui()
	local prompt = promptLabel :: TextLabel
	local status = statusLabel :: TextLabel
	local keypad = keypadFrame :: Frame

	activeStationId = stationId
	gui.Enabled = true
	keypad.Visible = false
	status.Text = ""

	cancelFlash()
	flashThread = task.spawn(function()
		local perDigitSeconds = typedChallenge.displaySeconds / math.max(1, #typedChallenge.code)
		for _, digit in typedChallenge.code do
			prompt.Text = tostring(digit)
			task.wait(perDigitSeconds)
		end
		prompt.Text = "Enter the code"
		keypad.Visible = true
		flashThread = nil
	end)
end

local function onResult(stationId: string, success: boolean)
	if activeStationId ~= stationId or statusLabel == nil then
		return
	end

	if success then
		statusLabel.Text = "Done!"
		task.delay(0.6, function()
			if screenGui ~= nil then
				screenGui.Enabled = false
			end
		end)
	else
		-- Can't tell from `success` alone whether that digit was right
		-- (just not the LAST one yet) or actually wrong (progress reset)
		-- - TaskResult only ever carries the whole attempt's outcome, not
		-- per-digit feedback (see Types.luau's own TaskHandler doc
		-- comment on validate's return shape). Never claims "wrong" on a
		-- digit that might have been correct.
		statusLabel.Text = "Keep going"
	end
end

local function hide(stationId: string)
	if activeStationId ~= stationId then
		return
	end
	cancelFlash()
	if screenGui ~= nil then
		screenGui.Enabled = false
	end
	activeStationId = nil
end

local CodePlaybackView = {
	taskId = "code-playback",
	show = show,
	onResult = onResult,
	hide = hide,
}

return CodePlaybackView
