--!strict
-- The client half of P2-6's Tap reference task (tasks-catalogue.md #1,
-- `pressure-valve`) - see src/server/TaskHandlers/PressureValve.luau for
-- the server half. Matches CodePlayback.luau's structure/style exactly
-- (see its own header comment for why plain Instances, not a framework).
--
-- One large tap zone, well past the 44pt minimum (P2-6's own
-- requirement) - 220x220 offset - anchored low-center like CodePlayback,
-- clear of every screen edge, so nothing about hitting it needs
-- precision. The gauge fill bar is purely decorative pacing (the server
-- never tells the client WHEN it actually resets internally - see the
-- server handler's own header comment on why this stays a client-side
-- approximation) - never authoritative over pass/fail.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(script.Parent.Types)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIScaleController = require(script.Parent.Parent.Controllers.UIScaleController)

type Challenge = {
	meterFillSeconds: number,
}

local screenGui: ScreenGui? = nil
local statusLabel: TextLabel? = nil
local gaugeFill: Frame? = nil
local activeStationId: string? = nil
local gaugeThread: thread? = nil

local function buildGui(): ScreenGui
	-- P6-7: on the safe-area screen and anchored to its bottom edge. The
	-- old centre-at-72% put the tap zone ~50 px off a landscape phone.
	local gui = UIScaleController.createScreen("PressureValveView", { displayOrder = Theme.displayOrder.panel + 1 })
	gui.Enabled = false

	local frame = Instance.new("Frame")
	frame.Name = "Root"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -Theme.spacing.md)
	frame.Size = UDim2.fromOffset(260, 320)
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
	status.Text = "Tap!"
	status.Parent = frame

	-- The gauge track and its fill - a purely cosmetic pressure
	-- indicator, never read back for validation.
	local gaugeTrack = Instance.new("Frame")
	gaugeTrack.Name = "GaugeTrack"
	gaugeTrack.Size = UDim2.new(1, -32, 0, 20)
	gaugeTrack.Position = UDim2.fromOffset(16, 44)
	gaugeTrack.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
	gaugeTrack.Parent = frame

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 10)
	trackCorner.Parent = gaugeTrack

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
	fill.Parent = gaugeTrack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 10)
	fillCorner.Parent = fill

	-- The tap zone itself - hit area (the whole button) generously
	-- larger than the visible ring drawn inside it (P2-6's own "hit
	-- areas larger than the visuals" requirement).
	local button = Instance.new("TextButton")
	button.Name = "TapZone"
	button.Size = UDim2.fromOffset(220, 220)
	button.Position = UDim2.new(0.5, 0, 1, -20)
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Text = ""
	button.AutoButtonColor = true
	button.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
	button.Parent = frame

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0.5, 0)
	buttonCorner.Parent = button

	local ring = Instance.new("Frame")
	ring.Name = "Visual"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(140, 140)
	ring.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
	ring.Parent = button

	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(0.5, 0)
	ringCorner.Parent = ring

	button.Activated:Connect(function()
		if activeStationId == nil then
			return
		end
		Net.fireServer("TapSubmit", { stationId = activeStationId })
	end)

	statusLabel = status
	gaugeFill = fill

	return gui
end

local function ensureGui(): ScreenGui
	if screenGui == nil then
		screenGui = buildGui()
	end
	return screenGui :: ScreenGui
end

local function cancelGaugeLoop()
	if gaugeThread ~= nil then
		task.cancel(gaugeThread)
		gaugeThread = nil
	end
end

local function show(stationId: string, challenge: any)
	local typedChallenge = challenge :: Challenge
	local gui = ensureGui()
	local status = statusLabel :: TextLabel
	local fill = gaugeFill :: Frame

	activeStationId = stationId
	gui.Enabled = true
	status.Text = "Tap!"
	fill.Size = UDim2.fromScale(0, 1)

	Types.freezeCamera()

	cancelGaugeLoop()
	gaugeThread = task.spawn(function()
		local fillSeconds = math.max(0.5, typedChallenge.meterFillSeconds)
		local startedAt = os.clock()
		while true do
			local elapsed = (os.clock() - startedAt) % fillSeconds
			fill.Size = UDim2.fromScale(elapsed / fillSeconds, 1)
			task.wait()
		end
	end)
end

local function onResult(stationId: string, success: boolean)
	if activeStationId ~= stationId or statusLabel == nil then
		return
	end

	if success then
		cancelGaugeLoop()
		Types.unfreezeCamera()
		statusLabel.Text = "Done!"
		task.delay(0.6, function()
			if screenGui ~= nil then
				screenGui.Enabled = false
			end
		end)
	else
		-- Can't tell from `success` alone whether that tap advanced
		-- progress or the gauge just maxed and reset (TaskResult doesn't
		-- carry that distinction - see PressureValve.luau's own header
		-- comment) - so this never claims "wrong," only that the attempt
		-- continues.
		statusLabel.Text = "Keep going!"
	end
end

local function hide(stationId: string)
	if activeStationId ~= stationId then
		return
	end
	cancelGaugeLoop()
	Types.unfreezeCamera()
	if screenGui ~= nil then
		screenGui.Enabled = false
	end
	activeStationId = nil
end

local PressureValveView = {
	taskId = "pressure-valve",
	show = show,
	onResult = onResult,
	hide = hide,
}

return PressureValveView
