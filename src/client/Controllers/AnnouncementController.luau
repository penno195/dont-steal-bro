--!strict
-- Staff announcements on screen (staff-tools.md step 6). AnnounceService
-- sends Announcement to everyone in every server, Hub, match and
-- practice, mid-race included (owner, 2026-10-18). This draws it as a
-- big banner in the upper third, holds it for its reading time, fades
-- it, then shows the next one waiting (AnnounceLogic.enqueue).
--
-- Display only and never interactive: the banner sinks no input, so a
-- racer's thumb still reaches whatever is under it. The text arrives
-- already through the text filter.
--
-- STYLE lives in the constants below, so the look can be swapped in one
-- place (the owner wants it to match the Squishie merge game's
-- announcements, whose source isn't in this repo).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local AnnounceLogic = require(ReplicatedStorage.Shared.AnnounceLogic)
local Env = require(script.Parent.Parent.UI.Components.Env)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIScaleController = require(script.Parent.UIScaleController)

-- ===== style =================================================================
-- Reference px (UIScaleController scales them). Landscape's short side
-- is ~360, so the banner sits in the upper third and clears the middle.
local WIDTH = 620
local HEIGHT = 118
local CENTRE_Y = 0.28 -- of the screen's height
local PAD = Theme.spacing.md
local HEADER_H = 22
local HEADER_FORMAT = "ANNOUNCEMENT FROM %s" -- the staff member's display name
local HEADER_COLOR = Theme.color.primary
local MESSAGE_STYLE = "headline" -- Theme.type; the display face, outlined
local MESSAGE_COLOR = Theme.color.ink
local MESSAGE_STROKE = 3 -- thicker than the usual outline, it's over a map
local BAND_COLOR = Theme.color.background
local BAND_TRANSPARENCY = 0.25
local RIM_COLOR = Theme.color.primary
local RIM_THICKNESS = 2
-- Motion: drops in from above with a small overshoot, then fades as it
-- drifts up. Reduced motion keeps the fades and drops the movement.
local SLIDE_PX = 40
local IN_SECONDS = 0.35
local OUT_SECONDS = 0.5
local OUT_DRIFT_PX = 12

local config = GameConfig.liveOps

local AnnouncementController: Loader.Controller = {
	name = "AnnouncementController",
	dependencies = { "UIScaleController" },
}

type Banner = {
	band: Frame,
	rim: UIStroke,
	header: TextLabel,
	headerStroke: UIStroke,
	message: TextLabel,
	messageStroke: UIStroke,
}

local banner: Banner? = nil
local queue: { AnnounceLogic.Banner } = {}
local showing = false

local function stroke(parent: Instance, color: Color3, thickness: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = parent
	return s
end

local function ensureBanner(): Banner
	if banner ~= nil then
		return banner
	end
	local gui = UIScaleController.createScreen("Announcement", { displayOrder = Theme.displayOrder.toast })

	local band = Instance.new("Frame")
	band.Name = "Banner"
	band.AnchorPoint = Vector2.new(0.5, 0.5)
	band.Position = UDim2.fromScale(0.5, CENTRE_Y)
	band.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	band.BackgroundColor3 = BAND_COLOR
	band.Active = false
	band.Visible = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.radius.md
	corner.Parent = band
	local rim = stroke(band, RIM_COLOR, RIM_THICKNESS)
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, PAD)
	padding.PaddingRight = UDim.new(0, PAD)
	padding.PaddingTop = UDim.new(0, Theme.spacing.sm)
	padding.PaddingBottom = UDim.new(0, Theme.spacing.sm)
	padding.Parent = band

	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, HEADER_H)
	header.BackgroundTransparency = 1
	header.TextColor3 = HEADER_COLOR
	header.TextTruncate = Enum.TextTruncate.AtEnd -- a long display name
	Theme.applyText(header, "label")
	header.FontFace = Theme.type.display.font
	local headerStroke = stroke(header, Theme.outline.color, Theme.outline.thickness)
	header.Parent = band

	local message = Instance.new("TextLabel")
	message.Name = "Message"
	message.Position = UDim2.fromOffset(0, HEADER_H)
	message.Size = UDim2.new(1, 0, 1, -HEADER_H)
	message.BackgroundTransparency = 1
	message.TextColor3 = MESSAGE_COLOR
	message.TextWrapped = true
	Theme.applyText(message, MESSAGE_STYLE)
	-- applyText's outline, made heavier; made here if the style has none.
	local outline = message:FindFirstChild("Outline") :: UIStroke?
	local messageStroke = outline or stroke(message, Theme.outline.color, MESSAGE_STROKE)
	messageStroke.Thickness = MESSAGE_STROKE
	message.Parent = band

	band.Parent = gui
	UIScaleController.attachScale(band)
	banner = {
		band = band,
		rim = rim,
		header = header,
		headerStroke = headerStroke,
		message = message,
		messageStroke = messageStroke,
	}
	return banner :: Banner
end

-- Every part's transparency at once: 0 = fully shown, 1 = gone.
local function fade(b: Banner, alpha: number, seconds: number, position: UDim2, style: Enum.EasingStyle): Tween
	local info = TweenInfo.new(seconds, style, Enum.EasingDirection.Out)
	local band = BAND_TRANSPARENCY + (1 - BAND_TRANSPARENCY) * alpha
	TweenService:Create(b.rim, info, { Transparency = alpha }):Play()
	TweenService:Create(b.header, info, { TextTransparency = alpha }):Play()
	TweenService:Create(b.headerStroke, info, { Transparency = alpha }):Play()
	TweenService:Create(b.message, info, { TextTransparency = alpha }):Play()
	TweenService:Create(b.messageStroke, info, { Transparency = alpha }):Play()
	local main = TweenService:Create(b.band, info, { BackgroundTransparency = band, Position = position })
	main:Play()
	return main
end

local function setAlpha(b: Banner, alpha: number)
	b.band.BackgroundTransparency = BAND_TRANSPARENCY + (1 - BAND_TRANSPARENCY) * alpha
	b.rim.Transparency = alpha
	b.header.TextTransparency = alpha
	b.headerStroke.Transparency = alpha
	b.message.TextTransparency = alpha
	b.messageStroke.Transparency = alpha
end

local function showNext()
	local item = table.remove(queue, 1)
	if item == nil then
		showing = false
		return
	end
	showing = true
	local b = ensureBanner()
	local still = Env.reducedMotion()
	local home = UDim2.fromScale(0.5, CENTRE_Y)
	local function offset(px: number): UDim2
		return if still then home else home + UDim2.fromOffset(0, px)
	end

	b.header.Text = string.format(HEADER_FORMAT, string.upper(item.from))
	b.message.Text = item.text
	setAlpha(b, 1)
	b.band.Position = offset(-SLIDE_PX)
	b.band.Visible = true
	fade(b, 0, IN_SECONDS, home, if still then Enum.EasingStyle.Linear else Enum.EasingStyle.Back)

	local hold = AnnounceLogic.holdSeconds(item.text, config.announceMinSeconds, config.announceMaxSeconds)
	task.delay(IN_SECONDS + hold, function()
		local out = fade(b, 1, OUT_SECONDS, offset(-OUT_DRIFT_PX), Enum.EasingStyle.Quad)
		out.Completed:Wait()
		b.band.Visible = false
		showNext()
	end)
end

function AnnouncementController:init()
	Net.onClientEvent("Announcement", function(payload: any)
		local item = AnnounceLogic.readBanner(payload)
		if item == nil then
			return
		end
		AnnounceLogic.enqueue(queue, item)
		if not showing then
			showNext()
		end
	end)
end

return AnnouncementController
