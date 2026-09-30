--!strict
-- Feeds the Decision Studio screen (P6-5, UI/Screens/DecisionStudio.luau)
-- and mounts it for the DecisionStudio round state. The screen never
-- touches a remote: every DecisionService payload lands here, is parsed
-- by DecisionLogic, and is written into a Vide source.
--
-- WHAT THIS CLIENT EVER HOLDS, AND WHEN (the P6-5 secrecy audit; the
-- full version is docs/decision-studio.md):
--   - its OWN choice, from the moment its own hold completes. Nobody
--     else's: `locked` is a set of ids, because DecisionLockedIn is only
--     ever {playerId}.
--   - everyone's choices from DecisionReveal, the first and only packet
--     that carries them.
--   - its own streak before/after from DecisionPersonalResult, which the
--     server fires to this player alone, after the reveal.
-- Nothing is written to an Attribute, a ValueObject or anything else
-- that replicates; it's all Lua locals and Vide sources.
--
-- The screen outlives the phase machine on purpose: DecisionService
-- moves the round to Results about a second after the reveal packet, but
-- the reveal plays for DecisionLogic.revealLength seconds. The screen
-- stays up through Results until the player dismisses it or the round
-- leaves Results. A results screen (P6-6) should wait on isActive().

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local vide = require(ReplicatedStorage.Packages.Vide)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local DecisionLogic = require(script.Parent.Parent.UI.DecisionLogic)
local DecisionStudio = require(script.Parent.Parent.UI.Screens.DecisionStudio)
local FinaleLoading = require(script.Parent.Parent.UI.Screens.FinaleLoading)
local InputLock = require(script.Parent.Parent.UI.InputLock)
local NPCBubbleController = require(script.Parent.NPCBubbleController)
local StudioChatController = require(script.Parent.StudioChatController)
local UIScaleController = require(script.Parent.UIScaleController)

local source = vide.source

-- Speaking and typing are polled getters (StudioChatController), so they
-- are sampled a few times a second while the screen is up, and written
-- only when something changed.
local TALK_INTERVAL = 0.25

local selfId = Players.LocalPlayer.UserId
local T = DecisionLogic.TIMING

-- Annotated, not inferred: luau-lsp widens a string-literal union
-- inside source() back to `string`, and the Store wants the union.
local phase: DecisionStudio.Settable<DecisionLogic.Phase?> = source(nil)
local endsAt = source(nil :: number?)
local seats = source({} :: { DecisionStudio.Seat })
local isFinalist = source(false)
local locked = source({} :: { [number]: boolean })
local talk: DecisionStudio.Settable<{ [number]: DecisionStudio.Talk }> = source({})
local acked = source(false)
local reveal = source(nil :: DecisionLogic.Reveal?)
local personal = source(nil :: DecisionLogic.Personal?)
local chat = source(nil :: DecisionLogic.Rect?)
local keyboard = source(nil :: number?)

local finalists = source({} :: { FinaleLoading.Finalist })

-- The Intro's ready-up: who the server says is ready, and whether WE
-- closed the loading card (spectators can close it too; only a
-- finalist's tap is sent).
local readyIds = source({} :: { [number]: boolean })
local dismissed = source(false)

local ids: { number } = {}
local leftIds: { [number]: boolean } = {}

local function nameOf(id: number): string
	if id < 0 then
		return NPCBubbleController.getNPCName(id) or "Finalist"
	end
	local player = Players:GetPlayerByUserId(id)
	return if player then player.DisplayName else "Finalist"
end

local function setFinalists(list: { number })
	local out: { FinaleLoading.Finalist } = {}
	for _, id in list do
		table.insert(out, table.freeze({ id = id, name = nameOf(id) }))
	end
	finalists(out)
end

local function rebuildSeats()
	local list: { DecisionStudio.Seat } = {}
	for _, id in ids do
		table.insert(
			list,
			table.freeze({
				id = id,
				name = nameOf(id),
				isSelf = id == selfId,
				isNPC = id < 0,
				left = leftIds[id] == true,
			})
		)
	end
	seats(list)
	isFinalist(table.find(ids, selfId) ~= nil)
	setFinalists(ids)
end

-- Sending: the one intent, then the SAME choice again if the server's
-- echo doesn't come back (a dropped remote). The server keeps the first
-- and silently drops repeats, so a resend can never change anything.
local sendToken = 0
local function send(choice: DecisionLogic.Choice)
	acked(false)
	sendToken += 1
	local token = sendToken
	Net.fireServer("DecisionChooseIntent", { choice = choice })
	task.spawn(function()
		for _ = 1, T.ackRetries do
			task.wait(T.ackTimeout)
			if sendToken ~= token or acked() or phase() ~= "Choose" then
				return
			end
			Net.fireServer("DecisionChooseIntent", { choice = choice })
		end
	end)
end

local function chooseOpen(): boolean
	return phase() == "Choose" and isFinalist() and reveal() == nil
end

local confirm, press, release, _stopConfirm = DecisionStudio.confirmer(send, chooseOpen)

local unmount: (() -> ())? = nil
local talkThread: thread? = nil

local function stopTalk()
	if talkThread ~= nil then
		task.cancel(talkThread)
		talkThread = nil
	end
	talk({})
end

local function startTalk()
	stopTalk()
	talkThread = task.spawn(function()
		while true do
			local nextTalk: { [number]: DecisionStudio.Talk } = {}
			local changed = false
			local current = talk()
			for _, id in ids do
				local value: DecisionStudio.Talk? = nil
				if StudioChatController.isPlayerSpeaking(id) then
					value = "speaking"
				elseif StudioChatController.isPlayerTyping(id) then
					value = "typing"
				end
				if value ~= nil then
					nextTalk[id] = value
				end
				if current[id] ~= value then
					changed = true
				end
			end
			if changed then
				talk(nextTalk)
			end
			task.wait(TALK_INTERVAL)
		end
	end)
end

local function resetStudio()
	sendToken += 1
	locked({})
	acked(false)
	reveal(nil)
	personal(nil)
	confirm(DecisionLogic.OPEN)
end

-- The spectator close-up's on/off (see SPECTATOR CLOSE-UP below).
local watching = source(false)
local cameraTypeBefore: Enum.CameraType? = nil

local function setWatching(on: boolean)
	local camera = Workspace.CurrentCamera
	if on == watching() or camera == nil then
		return
	end
	watching(on)
	if on then
		cameraTypeBefore = camera.CameraType
		camera.CameraType = Enum.CameraType.Scriptable
	else
		camera.CameraType = cameraTypeBefore or Enum.CameraType.Custom
		cameraTypeBefore = nil
	end
end

local function hide()
	if unmount ~= nil then
		(unmount :: () -> ())()
		unmount = nil
	end
	stopTalk()
end

local store: DecisionStudio.Store = {
	selfId = selfId,
	isFinalist = isFinalist,
	seats = seats,
	phase = phase,
	endsAt = endsAt,
	phaseSeconds = {
		Intro = GameConfig.studioTimers.introNewPlayerSeconds, -- the longest the Intro can run
		Negotiate = GameConfig.studioTimers.negotiateSeconds,
		Choose = GameConfig.studioTimers.chooseSeconds,
	},
	locked = locked,
	talk = talk,
	confirm = confirm,
	acked = acked,
	reveal = reveal,
	personal = personal,
	chat = chat,
	keyboard = keyboard,
	waiting = function(): string?
		if phase() ~= "Intro" or not dismissed() then
			return nil
		end
		local finalistIds: { number } = {}
		local left: { [number]: boolean } = {}
		for _, seat in seats() do
			table.insert(finalistIds, seat.id)
			left[seat.id] = seat.left
		end
		return DecisionLogic.waitingNotice(isFinalist(), finalistIds, readyIds(), left)
	end,
	press = press,
	release = release,
	dismiss = hide,
	send = StudioChatController.send,
	typing = StudioChatController.noteTyping,
	watching = function(): boolean
		return watching()
	end,
	toggleWatch = function()
		if not isFinalist() then
			setWatching(not watching())
		end
	end,
}

-- STAGE CAMERA. StudioStageService moves this player onto a podium or a
-- lookout, turned to face the podiums, but the default camera keeps the
-- angle it had in the race, which left the stage off to one side. So
-- whenever the character jumps (the placement, a respawn back to the
-- same spot), the camera is put behind it, looking at the stage's
-- centre (the nearest StudioAnchor: race maps can carry their own, far
-- away). The lookouts sit well above the podiums, so a level look would
-- go over them. Only on those jumps: the player turns the camera freely
-- in between.
local SNAP_JUMP_STUDS = 20
local CAMERA_BACK_STUDS = 12
local CAMERA_UP_STUDS = 5

local cameraWatch: RBXScriptConnection? = nil

local function nearestStageCentre(from: Vector3): Vector3?
	local best: Vector3?, bestDistance = nil, math.huge
	for _, anchor in CollectionService:GetTagged("StudioAnchor") do
		if anchor:IsA("BasePart") and anchor:IsDescendantOf(Workspace) then
			local distance = (anchor.Position - from).Magnitude
			if distance < bestDistance then
				best, bestDistance = anchor.Position, distance
			end
		end
	end
	return best
end

-- SPECTATOR CLOSE-UP. From the balcony the podiums are a long way off:
-- the finalists are small, their bubbles hard to read, and their voices
-- faint, because Roblox hears through an AudioListener on the camera.
-- "Watch" moves this spectator's camera in close - so all three get
-- better at once. The eye sits on the straight line from the stage
-- centre to the spectator's own head, WATCH_STUDS out: the spectator can
-- see the podiums from where they stand, so that line is clear of rock.
-- Their character stays on the balcony, and the server still keeps it
-- there; only this client's view moves.
local WATCH_STUDS = 22
local WATCH_LOOK_UP_STUDS = 3 -- aim at chest height, not the podium tops

local function watchCFrame(root: BasePart): CFrame?
	local centre = nearestStageCentre(root.Position)
	if centre == nil then
		return nil
	end
	local target = centre + Vector3.new(0, WATCH_LOOK_UP_STUDS, 0)
	local head = root.Position + Vector3.new(0, 1.5, 0)
	local toward = head - target
	if toward.Magnitude < 1e-3 then
		return nil
	end
	local eye = target + toward.Unit * math.min(WATCH_STUDS, toward.Magnitude)
	return CFrame.lookAt(eye, target)
end

local function snapCamera(root: BasePart)
	local camera = Workspace.CurrentCamera
	local centre = nearestStageCentre(root.Position)
	local toward = if centre ~= nil then centre - root.Position else root.CFrame.LookVector
	local flat = Vector3.new(toward.X, 0, toward.Z)
	if camera == nil or flat.Magnitude < 1e-3 then
		return
	end
	flat = flat.Unit
	local eye = root.Position - flat * CAMERA_BACK_STUDS + Vector3.new(0, CAMERA_UP_STUDS, 0)
	camera.CFrame = CFrame.lookAt(eye, centre or root.Position + flat * CAMERA_BACK_STUDS)
end

-- STANDING STILL ON THE PODIUM. The server anchors a finalist's root
-- part to hold them there. A character anchored mid-stride stops
-- stepping its Humanoid, so Humanoid.Running never fires the speed-0
-- that tells the default Animate script to go idle: the run animation
-- played on the spot for the whole finale (2026-09-26 playtest). So,
-- while this client's own root is anchored: its movement input is off
-- (a held thumbstick would keep asking to run), the walk/run tracks are
-- stopped, and the rig's own idle is played in their place. Animation
-- replicates from the owning client, so everyone sees the idle.
local MOVE_ANIM_FOLDERS: { [string]: boolean } = { run = true, walk = true }
local heldIdle: AnimationTrack? = nil

local function releaseIdle()
	if heldIdle ~= nil then
		heldIdle:Stop(0.2)
		heldIdle = nil
	end
end

local function settleOnPodium(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = if humanoid ~= nil then humanoid:FindFirstChildOfClass("Animator") else nil
	if animator == nil then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		local anim = track.Animation :: Animation?
		local folder = if anim ~= nil then anim.Parent else nil
		if folder ~= nil and MOVE_ANIM_FOLDERS[string.lower(folder.Name)] then
			track:Stop(0.2)
		end
	end
	releaseIdle()
	local animate = character:FindFirstChild("Animate")
	local idleFolder = if animate ~= nil then animate:FindFirstChild("idle") else nil
	local idle = if idleFolder ~= nil then idleFolder:FindFirstChildWhichIsA("Animation") else nil
	if idle ~= nil then
		local track = animator:LoadAnimation(idle :: Animation)
		track.Looped = true
		track:Play(0.2)
		heldIdle = track
	end
end

local function setHeld(character: Model?, held: boolean)
	InputLock.holdMovement(held)
	if held and character ~= nil then
		settleOnPodium(character)
	else
		releaseIdle()
	end
end

local function watchPlacement()
	if cameraWatch ~= nil then
		return
	end
	local last: Vector3? = nil
	local wasAnchored = false
	cameraWatch = RunService.RenderStepped:Connect(function()
		local character = Players.LocalPlayer.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		if root == nil or not root:IsA("BasePart") then
			last = nil
			if wasAnchored then
				wasAnchored = false
				setHeld(nil, false)
			end
			return
		end
		local at = root.Position
		if watching() and isFinalist() then
			setWatching(false) -- promoted onto a podium mid-finale (Q3)
		end
		if watching() then
			local camera = Workspace.CurrentCamera
			local view = watchCFrame(root)
			if camera ~= nil and view ~= nil then
				camera.CFrame = view
			end
		elseif last == nil or (at - last).Magnitude > SNAP_JUMP_STUDS then
			snapCamera(root)
		end
		last = at
		if root.Anchored ~= wasAnchored then
			wasAnchored = root.Anchored
			setHeld(character, wasAnchored)
		end
	end)
end

local function unwatchPlacement()
	if cameraWatch ~= nil then
		cameraWatch:Disconnect()
		cameraWatch = nil
	end
	setHeld(nil, false)
	setWatching(false)
end

-- THE LOADING CARD (UI/Screens/FinaleLoading). Up from the moment the
-- race resolves (Qualified) until the Studio's Intro ends, so the move
-- onto the set happens behind it and the Studio opens on Negotiate.
local unmountLoading: (() -> ())? = nil

local function hideLoading()
	if unmountLoading ~= nil then
		(unmountLoading :: () -> ())()
		unmountLoading = nil
	end
end

-- "Got it". Closing the card starts nothing by itself - the server ends
-- the Intro only once every finalist is ready.
local function dismissLoading()
	if dismissed() then
		return
	end
	dismissed(true)
	hideLoading()
	if isFinalist() then
		Net.fireServer("DecisionReadyIntent", {})
	end
end

local function showLoading()
	if unmountLoading == nil then
		unmountLoading = FinaleLoading.mount(UIScaleController, {
			selfId = selfId,
			finalists = finalists,
			canDismiss = function()
				return phase() == "Intro"
			end,
			onDismiss = dismissLoading,
		})
	end
end

local function show()
	if unmount == nil then
		unmount = DecisionStudio.mount(UIScaleController, store)
		startTalk()
	end
	watchPlacement()
end

-- Roblox's chat window, so the seats can sit below it. Read through the
-- documented ChatWindowConfiguration (see StudioChatController for why
-- the documented seam and not the default chat UI's hierarchy).
local function watchChat()
	local config = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
	if config == nil then
		return
	end
	local function read()
		if not config.Enabled then
			chat(nil)
			return
		end
		local p, s = config.AbsolutePosition, config.AbsoluteSize
		chat({ x = p.X, y = p.Y, width = s.X, height = s.Y })
	end
	config:GetPropertyChangedSignal("AbsolutePosition"):Connect(read)
	config:GetPropertyChangedSignal("AbsoluteSize"):Connect(read)
	config:GetPropertyChangedSignal("Enabled"):Connect(read)
	read()
end

-- The on-screen keyboard's top edge, so the hold buttons can ride above
-- it (P6-7). Screen pixels, like the chat window's rect.
local function watchKeyboard()
	local function read()
		if not UserInputService.OnScreenKeyboardVisible then
			keyboard(nil)
			return
		end
		keyboard(UserInputService.OnScreenKeyboardPosition.Y)
	end
	UserInputService:GetPropertyChangedSignal("OnScreenKeyboardVisible"):Connect(read)
	UserInputService:GetPropertyChangedSignal("OnScreenKeyboardPosition"):Connect(read)
	read()
end

local DecisionStudioController: Loader.Controller = {
	name = "DecisionStudioController",
	dependencies = { "UIScaleController", "StudioChatController", "NPCBubbleController" },

	isActive = function(): boolean
		return unmount ~= nil
	end,
}

function DecisionStudioController:init()
	Net.onClientEvent("RoundState", function(payload: any)
		if payload.state == "Qualified" then
			dismissed(false)
			readyIds({})
			showLoading()
		elseif payload.state ~= "DecisionStudio" then
			hideLoading()
			-- Not at Qualified: TaskQualificationResult fires just before it.
			if payload.state == "Race" then
				finalists({})
			end
		end
		if payload.state == "DecisionStudio" then
			show()
		else
			unwatchPlacement()
			if payload.state ~= "Results" then
				hide()
			end
		end
	end)

	-- Names the finalists on the loading card as the race resolves. DecisionParticipants replaces this list (after any Q3
	-- promotion) once the Studio opens.
	Net.onClientEvent("TaskQualificationResult", function(payload: any)
		if type(payload) ~= "table" or type(payload.qualifiers) ~= "table" then
			return
		end
		local list: { number } = {}
		for _, raw in payload.qualifiers :: { any } do
			if type(raw) == "number" then
				table.insert(list, raw)
			end
		end
		setFinalists(list)
	end)

	Net.onClientEvent("DecisionParticipants", function(payload: any)
		resetStudio()
		ids = {}
		leftIds = {}
		for _, raw in (payload.qualifierIds or {}) :: { any } do
			if type(raw) == "number" then
				table.insert(ids, raw)
			end
		end
		rebuildSeats()
	end)

	Net.onClientEvent("DecisionRosterChange", function(payload: any)
		local id = payload.racerId
		local index = table.find(ids, id)
		if index == nil then
			return
		end
		if payload.reason == "Withdrawn" then
			if type(payload.replacedById) == "number" then
				ids[index] = payload.replacedById
			else
				table.remove(ids, index)
			end
		elseif payload.reason == "Forfeited" then
			leftIds[id] = true
		end
		rebuildSeats()
	end)

	Net.onClientEvent("DecisionPhaseChanged", function(payload: any)
		phase(payload.phase)
		endsAt(payload.endsAt)
		if payload.phase ~= "Intro" then
			hideLoading()
		end
	end)

	Net.onClientEvent("DecisionReadyState", function(payload: any)
		local set: { [number]: boolean } = {}
		if type(payload) == "table" and type(payload.readyIds) == "table" then
			for _, id in payload.readyIds do
				if type(id) == "number" then
					set[id] = true
				end
			end
		end
		readyIds(set)
	end)

	Net.onClientEvent("DecisionLockedIn", function(payload: any)
		local id = payload.playerId
		if type(id) ~= "number" then
			return
		end
		local nextLocked = table.clone(locked())
		nextLocked[id] = true
		locked(nextLocked)
		if id == selfId then
			acked(true)
		end
	end)

	Net.onClientEvent("DecisionReveal", function(payload: any)
		local parsed = DecisionLogic.parseReveal(payload)
		if parsed ~= nil then
			reveal(parsed)
		end
	end)

	Net.onClientEvent("DecisionPersonalResult", function(payload: any)
		personal(DecisionLogic.parsePersonal(payload))
	end)
end

function DecisionStudioController:start()
	task.spawn(watchChat)
	watchKeyboard()
end

return DecisionStudioController
