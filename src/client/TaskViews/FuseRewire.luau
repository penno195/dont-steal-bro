--!strict
-- The client half of P2-6's Drag reference task (tasks-catalogue.md #7,
-- `fuse-rewire`) - see src/server/TaskHandlers/FuseRewire.luau for the
-- server half. Matches CodePlayback.luau's structure/style exactly (see
-- its own header comment for why plain Instances, not a framework).
--
-- WHY A DROPPED FUSE ALWAYS SNAPS BACK TO THE TRAY, EVEN WHEN IT WAS
-- RIGHT: TaskResult only ever carries the WHOLE task's `success`
-- boolean, never which specific drop it was for (the same limitation
-- CodePlayback.luau's view lives with for "wrong digit" vs "correct but
-- not done yet" - see its own onResult). This view genuinely can't tell
-- "that drop locked in" from "that drop bounced," so it never guesses -
-- every drop snaps back immediately, and only the eventual `success =
-- true` (every slot filled) changes anything visually. This is also why
-- success can't animate each fuse into its resolved slot: the correct
-- mapping is server-private BY DESIGN (see the server handler's header
-- comment) - the client never learns it, win or lose.
--
-- Every touch target here is well past the 44pt minimum and each hit
-- area (the Frame/Button itself) is larger than the icon drawn inside it
-- (P2-6's own requirements) - fuses and slots are both 64x64 hit areas
-- with a smaller 40x40 visual centered inside. The whole play area is
-- anchored low-center with margin on every side, so a drag never needs
-- to approach a screen edge.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(script.Parent.Types)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIScaleController = require(script.Parent.Parent.Controllers.UIScaleController)

type Challenge = {
	fuseIds: { string },
	slotIds: { string },
}

local screenGui: ScreenGui? = nil
local statusLabel: TextLabel? = nil
local activeStationId: string? = nil
local slotFrames: { Frame } = {}

local function isPrimaryInput(inputType: Enum.UserInputType): boolean
	return inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1
end

local function slotAtScreenPosition(screenPosition: Vector2): Frame?
	for _, slot in slotFrames do
		local topLeft = slot.AbsolutePosition
		local size = slot.AbsoluteSize
		if
			screenPosition.X >= topLeft.X
			and screenPosition.X <= topLeft.X + size.X
			and screenPosition.Y >= topLeft.Y
			and screenPosition.Y <= topLeft.Y + size.Y
		then
			return slot
		end
	end
	return nil
end

local function makeHitArea(parent: Instance, name: string, labelText: string): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.fromOffset(64, 64)
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button

	local visual = Instance.new("Frame")
	visual.Name = "Visual"
	visual.AnchorPoint = Vector2.new(0.5, 0.5)
	visual.Position = UDim2.fromScale(0.5, 0.5)
	visual.Size = UDim2.fromOffset(40, 40)
	visual.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
	visual.Parent = button

	local visualCorner = Instance.new("UICorner")
	visualCorner.CornerRadius = UDim.new(0, 6)
	visualCorner.Parent = visual

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = labelText
	label.Parent = visual

	return button
end

local function makeDraggable(fuseId: string, button: TextButton)
	local dragging = false
	local homePosition = button.Position

	local function screenPositionOf(input: InputObject): Vector2
		return Vector2.new(input.Position.X, input.Position.Y)
	end

	button.InputBegan:Connect(function(input: InputObject)
		if not isPrimaryInput(input.UserInputType) then
			return
		end
		dragging = true
		button.ZIndex = 10
	end)

	button.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.Touch
			and input.UserInputType ~= Enum.UserInputType.MouseMovement
		then
			return
		end
		local screenPosition = screenPositionOf(input)
		button.Position =
			UDim2.fromOffset(screenPosition.X - button.AbsoluteSize.X / 2, screenPosition.Y - button.AbsoluteSize.Y / 2)
	end)

	button.InputEnded:Connect(function(input: InputObject)
		if not dragging or not isPrimaryInput(input.UserInputType) then
			return
		end
		dragging = false
		button.ZIndex = 1

		local droppedSlot = slotAtScreenPosition(screenPositionOf(input))
		button.Position = homePosition -- see this file's header comment for why this always snaps back

		if droppedSlot ~= nil and activeStationId ~= nil then
			local slotId = droppedSlot.Name
			Net.fireServer("FuseDropSubmit", { stationId = activeStationId, fuseId = fuseId, slotId = slotId })
		end
	end)
end

local function buildGui(): ScreenGui
	-- P6-7: on the safe-area screen and anchored to its bottom edge, so
	-- the tray stays on a landscape phone. Input positions and
	-- AbsolutePosition then share the space InputAdapters.pointOf uses.
	local gui = UIScaleController.createScreen("FuseRewireView", { displayOrder = Theme.displayOrder.panel + 1 })
	gui.Enabled = false

	local frame = Instance.new("Frame")
	frame.Name = "Root"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -Theme.spacing.md)
	frame.Size = UDim2.fromOffset(320, 260)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.1
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Size = UDim2.new(1, 0, 0, 32)
	status.Position = UDim2.fromOffset(0, 8)
	status.BackgroundTransparency = 1
	status.TextColor3 = Color3.new(1, 1, 1)
	status.TextScaled = true
	status.Font = Enum.Font.GothamBold
	status.Text = "Drag each fuse to a slot"
	status.Parent = frame

	local slots = Instance.new("Frame")
	slots.Name = "Slots"
	slots.Size = UDim2.new(1, -32, 0, 64)
	slots.Position = UDim2.fromOffset(16, 56)
	slots.BackgroundTransparency = 1
	slots.Parent = frame

	local slotsLayout = Instance.new("UIListLayout")
	slotsLayout.FillDirection = Enum.FillDirection.Horizontal
	slotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	slotsLayout.Padding = UDim.new(0, 16)
	slotsLayout.Parent = slots

	local tray = Instance.new("Frame")
	tray.Name = "Tray"
	tray.Size = UDim2.new(1, -32, 0, 64)
	tray.Position = UDim2.fromOffset(16, 168)
	tray.BackgroundTransparency = 1
	tray.Parent = frame

	local trayLayout = Instance.new("UIListLayout")
	trayLayout.FillDirection = Enum.FillDirection.Horizontal
	trayLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	trayLayout.Padding = UDim.new(0, 16)
	trayLayout.Parent = tray

	local slotLabels = { "A", "B", "C", "D" }
	local slots_: { Frame } = {}
	for index, letter in slotLabels do
		local slot = makeHitArea(slots, string.format("slot-%d", index), letter)
		table.insert(slots_, slot :: any)
	end

	for index = 1, 4 do
		local fuseId = string.format("fuse-%d", index)
		local button = makeHitArea(tray, fuseId, tostring(index))
		makeDraggable(fuseId, button)
	end

	statusLabel = status
	slotFrames = slots_

	return gui
end

local function ensureGui(): ScreenGui
	if screenGui == nil then
		screenGui = buildGui()
	end
	return screenGui :: ScreenGui
end

local function show(stationId: string, _challenge: any)
	-- `_challenge.fuseIds`/`slotIds` aren't needed to build the UI - the
	-- fixed 4 fuses/4 slots this view always renders already match them
	-- 1:1 by construction (see FuseRewire.luau's own start()). A task
	-- with a variable slot count would read them here instead.
	local gui = ensureGui()
	local status = statusLabel :: TextLabel

	activeStationId = stationId
	gui.Enabled = true
	status.Text = "Drag each fuse to a slot"

	Types.freezeCamera()
end

local function onResult(stationId: string, success: boolean)
	if activeStationId ~= stationId or statusLabel == nil then
		return
	end

	if success then
		Types.unfreezeCamera()
		statusLabel.Text = "Done!"
		task.delay(0.6, function()
			if screenGui ~= nil then
				screenGui.Enabled = false
			end
		end)
	else
		statusLabel.Text = "Keep going"
	end
end

local function hide(stationId: string)
	if activeStationId ~= stationId then
		return
	end
	Types.unfreezeCamera()
	if screenGui ~= nil then
		screenGui.Enabled = false
	end
	activeStationId = nil
end

local FuseRewireView = {
	taskId = "fuse-rewire",
	show = show,
	onResult = onResult,
	hide = hide,
}

return FuseRewireView
