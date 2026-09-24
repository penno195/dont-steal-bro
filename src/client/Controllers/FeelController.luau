--!strict
-- The physical punch on the game's four big moments (P8-3): finishing a
-- task, qualifying, locking in, and the reveal. FeelLogic holds the
-- numbers and curves; this file applies them:
--
--   shake    Humanoid.CameraOffset, so it rides on whatever the default
--            camera is doing instead of fighting it for the CFrame.
--   hit-stop the local character's playing animation tracks pause for a
--            few frames. Local presentation only - the server's
--            simulation never stops, so it's no gameplay pause.
--   punch    a UIScale on the element a screen bound to the moment's
--            channel (Components/Feel.attach).
--   burst    one pooled ParticleEmitter per colour on the character's
--            root, fired with :Emit - never left emitting.
--   flash    reduced motion's stand-in: an opacity-only full-screen tint.
--
-- Reduced motion is read when the moment fires (FeelLogic.spec picks the
-- variant), so flipping the setting mid-round takes effect on the next
-- moment. docs/audio-and-feel.md §3 is the brief.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Clock = require(ReplicatedStorage.Shared.Clock)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local AudioLogic = require(script.Parent.Parent.UI.AudioLogic)
local DecisionLogic = require(script.Parent.Parent.UI.DecisionLogic)
local Env = require(script.Parent.Parent.UI.Components.Env)
local Feel = require(script.Parent.Parent.UI.Components.Feel)
local FeelLogic = require(script.Parent.Parent.UI.FeelLogic)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIScaleController = require(script.Parent.UIScaleController)

local LATE_TOLERANCE = 0.25
-- The reveal's audio cues that are also feel moments.
local REVEAL_MOMENTS: { [string]: FeelLogic.Moment } = {
	RevealCard = "RevealCard",
	RevealOutcome = "RevealOutcome",
}

local player = Players.LocalPlayer
local selfId = player.UserId

type Timed<T> = { value: T, startedAt: number }
local shakes: { Timed<FeelLogic.Shake> } = {}
local punches: { [string]: Timed<FeelLogic.Punch> } = {}
local flash: Timed<FeelLogic.Flash>? = nil
-- The CameraOffset this controller last added, so it removes exactly
-- that and leaves any other offset alone.
local appliedOffset = Vector3.zero

local flashFrame: Frame? = nil
local emitters: { [string]: ParticleEmitter } = {}
local frozenUntil = 0
local roundToken = 0

local function humanoid(): Humanoid?
	local character = player.Character
	return if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
end

-- HIT-STOP -----------------------------------------------------------

local function hitStop(seconds: number)
	if seconds <= 0 then
		return
	end
	local h = humanoid()
	local animator = if h ~= nil then h:FindFirstChildOfClass("Animator") else nil
	if animator == nil then
		return
	end
	-- Overlapping stops extend the one already running rather than
	-- stacking a second freeze whose restore would fight the first's.
	local now = os.clock()
	if now < frozenUntil then
		frozenUntil = math.max(frozenUntil, now + seconds)
		return
	end
	frozenUntil = now + seconds
	local frozen: { [AnimationTrack]: number } = {}
	for _, animTrack in animator:GetPlayingAnimationTracks() do
		frozen[animTrack] = animTrack.Speed
		animTrack:AdjustSpeed(0)
	end
	local function restore()
		if os.clock() < frozenUntil then
			task.delay(frozenUntil - os.clock(), restore)
			return
		end
		for animTrack, speed in frozen do
			if animTrack.IsPlaying then
				animTrack:AdjustSpeed(speed)
			end
		end
	end
	task.delay(seconds, restore)
end

-- BURST --------------------------------------------------------------

local function emitter(colorToken: string): ParticleEmitter?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	local existing: ParticleEmitter? = emitters[colorToken]
	if existing ~= nil and existing.Parent ~= nil and (existing.Parent :: Instance).Parent == root then
		return existing
	end
	-- New character (respawn) or first use: build on this root.
	local attachment = root:FindFirstChild("FeelBurst")
	if attachment == nil then
		attachment = Instance.new("Attachment")
		attachment.Name = "FeelBurst"
		attachment.Parent = root
	end
	local e = Instance.new("ParticleEmitter")
	e.Name = colorToken
	e.Enabled = false -- only ever fired with :Emit
	e.Rate = 0
	e.Color = ColorSequence.new(Theme.color[colorToken] or Color3.new(1, 1, 1))
	e.LightEmission = 0.6
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	e.SpreadAngle = Vector2.new(180, 180)
	e.Parent = attachment
	emitters[colorToken] = e
	return e
end

local function burst(b: FeelLogic.Burst)
	local e = emitter(b.colorToken)
	if e == nil then
		return
	end
	e.Speed = NumberRange.new(b.speed * 0.6, b.speed)
	e.Lifetime = NumberRange.new(b.lifetime * 0.7, b.lifetime)
	e:Emit(b.count)
end

-- MOMENTS ------------------------------------------------------------

local function fire(moment: FeelLogic.Moment)
	local spec = FeelLogic.spec(moment, Env.reducedMotion())
	local now = os.clock()
	if spec.shake ~= nil then
		table.insert(shakes, { value = spec.shake, startedAt = now })
	end
	if spec.punch ~= nil then
		punches[FeelLogic.CHANNEL[moment]] = { value = spec.punch, startedAt = now }
	end
	if spec.flash ~= nil and flashFrame ~= nil then
		flash = { value = spec.flash, startedAt = now }
		flashFrame.BackgroundColor3 = Theme.color[spec.flash.colorToken] or Color3.new(1, 1, 1)
	end
	if spec.burst ~= nil then
		burst(spec.burst)
	end
	hitStop(spec.hitStop)
end

local function onHeartbeat()
	local now = os.clock()

	-- Shake: the strongest running shake this frame, not the sum.
	local x, y = 0, 0
	for i = #shakes, 1, -1 do
		local s = shakes[i]
		local t = now - s.startedAt
		if t >= s.value.duration then
			table.remove(shakes, i)
		else
			local sx, sy = FeelLogic.shakeOffset(s.value, t)
			x, y = FeelLogic.stronger(x, y, sx, sy)
		end
	end
	local offset = Vector3.new(x, y, 0)
	if offset ~= appliedOffset then
		local h = humanoid()
		if h ~= nil then
			h.CameraOffset = h.CameraOffset - appliedOffset + offset
		end
		appliedOffset = offset
	end

	for channel, p in punches do
		local scale = FeelLogic.punchScale(p.value, now - p.startedAt)
		Feel.set(channel, scale)
		if scale == 1 then
			punches[channel] = nil
		end
	end

	if flash ~= nil and flashFrame ~= nil then
		local tr = FeelLogic.flashTransparency(flash.value, now - flash.startedAt)
		flashFrame.BackgroundTransparency = tr
		if tr >= 1 then
			flash = nil
		end
	end
end

local function onReveal(payload: any)
	local reveal = DecisionLogic.parseReveal(payload)
	if reveal == nil then
		return
	end
	local seats = 0
	for _ in reveal.choices do
		seats += 1
	end
	local token = roundToken
	local schedule = AudioLogic.revealSchedule(seats, DecisionLogic.TIMING)
	for _, entry in schedule do
		local moment: FeelLogic.Moment? = REVEAL_MOMENTS[entry.cue]
		local delay = reveal.revealAt + entry.at - Clock.now()
		if moment ~= nil and delay >= -LATE_TOLERANCE then
			local m: FeelLogic.Moment = moment
			task.delay(math.max(0, delay), function()
				if token == roundToken then
					fire(m)
				end
			end)
		end
	end
end

-- CONTROLLER ---------------------------------------------------------

local FeelController: Loader.Controller = {
	name = "FeelController",
	dependencies = { "UIScaleController" },
}

function FeelController.fire(moment: FeelLogic.Moment)
	fire(moment)
end

function FeelController:init()
	Net.onClientEvent("RoundState", function(payload: any)
		local state = if type(payload) == "table" then payload.state else nil
		if state == "Loading" or state == "Cleanup" or state == "WaitingForPlayers" then
			roundToken += 1
		end
	end)
	Net.onClientEvent("TaskResult", function(payload: any)
		if type(payload) == "table" and payload.success == true then
			fire("TaskComplete")
		end
	end)
	Net.onClientEvent("TaskQualificationResult", function(payload: any)
		if type(payload) == "table" and type(payload.qualifiers) == "table" then
			if table.find(payload.qualifiers, selfId) ~= nil then
				fire("Qualified")
			end
		end
	end)
	Net.onClientEvent("DecisionLockedIn", function(payload: any)
		if type(payload) == "table" and payload.playerId == selfId then
			fire("LockIn")
		end
	end)
	Net.onClientEvent("DecisionReveal", onReveal)
end

function FeelController:start()
	local gui = UIScaleController.createScreen("FeelFlash", {
		displayOrder = Theme.displayOrder.toast + 5,
		fullBleed = true,
	})
	local frame = Instance.new("Frame")
	frame.Name = "Flash"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Active = false
	frame.Parent = gui
	flashFrame = frame

	RunService.Heartbeat:Connect(onHeartbeat)
end

return FeelController
