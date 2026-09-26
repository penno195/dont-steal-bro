--!strict
-- The 3-2-1-GO over Intro's last seconds. Display only: the server holds
-- every human still from Loading until Race (StatusEffects' start gate)
-- and releases them on Race regardless of what this shows, so a client
-- that hides or skips the countdown gains nothing.
--
-- Counts against RoundState's endsAt in server time (Clock.now), so every
-- client shows the same digit at the same moment. Sits in the upper
-- third, small enough to leave the middle of the screen clear.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Clock = require(ReplicatedStorage.Shared.Clock)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIScaleController = require(script.Parent.UIScaleController)

local COUNT_FROM = 3
local GO_SECONDS = 0.8
local SIZE = 96

local StartCountdownController: Loader.Controller = {
	name = "StartCountdownController",
	dependencies = { "UIScaleController" },
}

local label: TextLabel? = nil
local ticking: RBXScriptConnection? = nil
local goToken = 0

local function ensureLabel(): TextLabel
	if label ~= nil then
		return label
	end
	local gui = UIScaleController.createScreen("StartCountdown", { displayOrder = Theme.displayOrder.panel })
	local text = Instance.new("TextLabel")
	text.Name = "Count"
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.3)
	text.Size = UDim2.fromOffset(SIZE * 2, SIZE)
	text.BackgroundTransparency = 1
	text.TextColor3 = Theme.color.ink
	text.FontFace = Theme.type.display.font
	text.TextScaled = true
	text.Visible = false
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Theme.color.background
	stroke.Parent = text
	text.Parent = gui
	UIScaleController.attachScale(text)
	label = text
	return text
end

local function stopTicking()
	if ticking ~= nil then
		ticking:Disconnect()
		ticking = nil
	end
end

local function onRoundState(payload: any)
	stopTicking()
	local text = ensureLabel()
	goToken += 1

	if payload.state == "Intro" and typeof(payload.endsAt) == "number" then
		local endsAt = payload.endsAt :: number
		ticking = RunService.Heartbeat:Connect(function()
			local remaining = Clock.secondsRemaining(endsAt, Clock.now())
			local digit = math.ceil(remaining)
			text.Visible = digit >= 1 and digit <= COUNT_FROM
			text.Text = tostring(digit)
			text.TextColor3 = Theme.color.ink
		end)
	elseif payload.state == "Race" then
		local token = goToken
		text.Text = "GO!"
		text.TextColor3 = Theme.color.success
		text.Visible = true
		task.delay(GO_SECONDS, function()
			if goToken == token then
				text.Visible = false
			end
		end)
	else
		text.Visible = false
	end
end

function StartCountdownController:init()
	Net.onClientEvent("RoundState", onRoundState)
end

return StartCountdownController
