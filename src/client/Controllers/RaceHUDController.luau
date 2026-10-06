--!strict
-- Feeds the race HUD (P6-3, UI/Screens/RaceHUD.luau) and mounts it for
-- the Race round state. In the hub it mounts the power-up slots alone,
-- for the practice area (mountPractice). The HUD never touches a remote: every server
-- payload lands here, is turned into display-ready rows, and is written
-- into one Vide source. The sources live for the whole session, so data
-- that arrives just before the HUD mounts (TaskService sends the route
-- as the race begins, with no promised order against RoundState) is
-- already there when it does.
--
-- Everything received here is display-only. Firing sends an intent -
-- the selected slot, the target this client locked on to, and the aim
-- direction - and the server re-checks all of it (PowerUpService) and
-- decides what, if anything, happens.
--
-- LOCK-ON (powerups.md "Inventory and aiming"). While an Aimed or
-- Nearest item is selected, a per-frame loop runs the SAME
-- PowerUpLogic targeting the server runs, and highlights the result:
-- faintly for what a quick fire would hit (the character's facing),
-- strongly while aiming (the first-person camera on hold-left-click /
-- L2, or the drag from the slot on touch). What's highlighted is what's sent, so
-- what you see is what you hit, or a refusal that keeps the item.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local vide = require(ReplicatedStorage.Packages.Vide)

local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local ParticipantIds = require(ReplicatedStorage.Shared.ParticipantIds)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local PowerUpLogic = require(ReplicatedStorage.Shared.PowerUpLogic)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local Tasks = require(ReplicatedStorage.Shared.Config.Tasks)
local ComponentLogic = require(script.Parent.Parent.UI.Components.ComponentLogic)
local Toast = require(script.Parent.Parent.UI.Components.Toast)
local HudLogic = require(script.Parent.Parent.UI.HudLogic)
local RaceHUD = require(script.Parent.Parent.UI.Screens.RaceHUD)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIScaleController = require(script.Parent.UIScaleController)

local source = vide.source

-- Nearest-station search: ≤ tasksPerPlayer distance checks, 5 times a
-- second. The arrow itself turns every frame with the camera, but only
-- writes when it has moved a whole ARROW_STEP.
local SEARCH_INTERVAL = 0.2
local ARROW_STEP = 5
-- If the server never answers a use (a dropped remote), unstick the
-- button rather than leaving it spinning for the rest of the race.
local USE_TIMEOUT = 2
-- How long a refusal's note stays above the slots. An explanation
-- stays as long as a toast of the same text would.
local REFUSAL_SECONDS = 1.5

-- Short, player-facing versions of PowerUpService's refusal reasons
-- that a player can act on, shown at the slots (RaceHUD.SlotNote).
-- Anything else is an internal refusal the player couldn't do anything
-- about, so it shows nothing.
local REFUSALS: { [string]: string } = {
	["no valid target"] = "No target",
	["on cooldown"] = "Cooling down",
}

local taskNames: { [string]: string } = {}
for _, entry in Tasks do
	taskNames[entry.def.id] = entry.def.displayName
end
local powerUpDefs: { [string]: Validate.PowerUpDef } = {}
for _, entry in PowerUps do
	powerUpDefs[entry.def.id] = entry.def
end
-- CallingCard id -> image, for the hit toast. Enabled cards only, so a
-- disabled or unknown id just shows the plain toast.
local callingCardImage: { [string]: number } = {}
for _, entry in Cosmetics do
	local def = entry.def
	if def.category == "CallingCard" and def.enabled then
		callingCardImage[def.id] = def.cardImageAssetId :: number
	end
end
-- Power-up ids whose description has been shown this session. The
-- first pickup of each type explains it once, above the slots; after
-- that it's just the slot icon, so a long race doesn't nag.
local explained: { [string]: boolean } = {}

local function roleColor(role: string): Color3?
	local rgb = PowerUpLogic.ROLE_RGB[role]
	return if rgb then Color3.fromRGB(rgb[1], rgb[2], rgb[3]) else nil
end

type Route = { stationId: string, taskId: string, completed: boolean }

local SLOT_COUNT = GameConfig.powerUpInventorySlots
local selfId = Players.LocalPlayer.UserId

local function emptySlots(): { RaceHUD.Slot }
	local list = {}
	for index = 1, SLOT_COUNT do
		list[index] = table.freeze({ index = index })
	end
	return list
end

local endsAt = source(nil :: number?)
local tasks = source({} :: { RaceHUD.TaskRow })
local progress = source({} :: { HudLogic.ProgressEntry })
local slots = source(emptySlots())
local selected = source(1)
local aiming = source(false)
local pending = source(false)
local note = source(nil :: RaceHUD.SlotNote?)
local noteId = 0
-- The slot the use in flight was fired from, for the refusal shake.
local firedSlot = 1

-- Puts a note above the slots for `seconds`, replacing any already up.
local function showNote(text: string, slot: number, kind: "info" | "warning", seconds: number)
	noteId += 1
	local id = noteId
	note({ text = text, slot = slot, id = id, kind = kind })
	task.delay(seconds, function()
		local current = note()
		if current ~= nil and current.id == id then
			note(nil)
		end
	end)
end
local effects = source({} :: { HudLogic.Effect })
local objective = source(nil :: RaceHUD.Objective?)

-- stationIds still to do, from the latest TaskAssignmentState.
local outstanding: { string } = {}
local stationParts: { [string]: BasePart } = {}

-- LOCK-ON STATE --------------------------------------------------------

-- nil when not aiming. "Camera" is hold-to-aim (the camera's flattened
-- look); "Drag" is a touch drag from the slot (dragX/dragY, pixels).
local aimMode: RaceHUD.AimMode? = nil
local dragX, dragY = 0, 0
-- The latest lock, as sent on fire: who, and along which aim direction
-- (nil for a quick fire - the server then uses the character's facing,
-- exactly as updateLock did).
local lockedId: number? = nil
local lockedAim: PowerUpLogic.Vec3? = nil

-- True while the hub's practice tray is up (mountPractice).
local practicing = false

local highlight: Highlight? = nil
local shownModel: Model? = nil
local shownStrong = false

local function toVec3(v: Vector3): PowerUpLogic.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function rootOf(model: Model?): BasePart?
	local root = if model then model:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

-- A racer's rig: a player's Character, or for an NPC (negative id) the
-- rig NPCService named after it under Workspace.NPCs - the same route
-- NametagController takes.
-- Hub training dummies (PracticeService), by participant id.
local function practiceDummies(): { [number]: Model }
	local found: { [number]: Model } = {}
	for _, instance in CollectionService:GetTagged("PracticeDummy") do
		local id = instance:GetAttribute("ParticipantId")
		if instance:IsA("Model") and type(id) == "number" then
			found[id] = instance
		end
	end
	return found
end

local function characterFor(racerId: number): Model?
	if ParticipantIds.isNPC(racerId) then
		local dummy: Model? = practiceDummies()[racerId]
		if dummy ~= nil then
			return dummy
		end
		local folder = Workspace:FindFirstChild("NPCs")
		local name = (Loader.get("NPCBubbleController") :: any).getNPCName(racerId) :: string?
		local rig = if folder ~= nil and name ~= nil then folder:FindFirstChild(name) else nil
		return if rig ~= nil and rig:IsA("Model") then rig else nil
	end
	local player = Players:GetPlayerByUserId(racerId)
	return if player ~= nil then player.Character else nil
end

local function selectedDef(): Validate.PowerUpDef?
	local id = slots()[selected()].id
	return if id ~= nil then powerUpDefs[id] else nil
end

local function aimDirection(): PowerUpLogic.Vec3?
	local camera = Workspace.CurrentCamera
	if aimMode == nil or camera == nil then
		return nil
	end
	local look = camera.CFrame.LookVector
	if aimMode == "Camera" then
		return PowerUpLogic.aimForward(look.X, look.Z)
	end
	local x, z = HudLogic.dragToGround(dragX, dragY, look.X, look.Z)
	return PowerUpLogic.aimForward(x, z)
end

-- Writes the highlight only when what it shows changed.
local function showLock(model: Model?, strong: boolean)
	if model == shownModel and strong == shownStrong then
		return
	end
	shownModel, shownStrong = model, strong
	if model == nil then
		if highlight ~= nil then
			highlight.Adornee = nil
			highlight.Parent = nil
		end
		return
	end
	local h = highlight
	if h == nil then
		local created = Instance.new("Highlight")
		created.Name = "PowerUpLockOn"
		created.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		created.FillColor = Theme.color.warning
		created.OutlineColor = Theme.color.warning
		highlight = created
		h = created
	end
	local shown = h :: Highlight
	shown.FillTransparency = if strong then 0.55 else 0.85
	shown.OutlineTransparency = if strong then 0 else 0.45
	shown.Adornee = model
	shown.Parent = model
end

-- AIM VISUAL. While aiming an Aimed item: a laser along the floor from
-- the character's feet, and a crosshair where it ends. Unlocked, the
-- laser runs the full use range in ink white, so the reach is visible.
-- Locked, it runs to the target and the crosshair sits on their body,
-- turning green and tightening - the shape changes too, so the lock
-- doesn't rest on colour alone.
--
-- The laser lies on the floor because a waist-high line, seen from the
-- usual camera behind the character, foreshortens to a sliver hidden
-- behind them. The crosshair is screen-space, one band above the HUD,
-- because its unlocked spot is near the horizon - exactly where the top
-- bar sits, which covered a world-space billboard. The laser is a
-- local-only part, never collided with or raycast.
local LASER_WIDTH = 0.5
local LASER_THICKNESS = 0.08
local FLOOR_LIFT = 0.1 -- above the feet, so the laser doesn't z-fight the floor
-- First person: the laser's near end, in studs from the camera.
local HAND_RIGHT = 0.8
local HAND_DOWN = 0.9
local ROD_WIDTH = 0.12
local RETICLE_PIXELS = 56
local RETICLE_LOCKED_PIXELS = 34

local laser: Part? = nil
local reticleGui: ScreenGui? = nil
local reticle: Frame? = nil
local reticleRing: Frame? = nil
local reticleDot: Frame? = nil
local reticleStroke: UIStroke? = nil

local function circle(parent: Instance, size: UDim2): Frame
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = size
	frame.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame
	frame.Parent = parent
	return frame
end

local function buildAimVisual()
	local beam = Instance.new("Part")
	beam.Name = "PowerUpAimLaser"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Transparency = 0.3

	local gui = Instance.new("ScreenGui")
	gui.Name = "PowerUpCrosshair"
	gui.DisplayOrder = Theme.displayOrder.hud + 1
	gui.IgnoreGuiInset = true -- WorldToViewportPoint is in full-viewport pixels
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(RETICLE_PIXELS, RETICLE_PIXELS)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	local ring = circle(holder, UDim2.fromOffset(RETICLE_PIXELS, RETICLE_PIXELS))
	ring.BackgroundTransparency = 1
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Parent = ring

	local dot = circle(holder, UDim2.fromOffset(10, 10))
	-- A dark edge, so the white unlocked state reads on a bright floor.
	local dotEdge = Instance.new("UIStroke")
	dotEdge.Color = Theme.color.scrim
	dotEdge.Transparency = 0.4
	dotEdge.Thickness = 2
	dotEdge.Parent = dot

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	laser, reticleGui, reticle, reticleRing, reticleDot, reticleStroke = beam, gui, holder, ring, dot, stroke
end

local function hideAimVisual()
	if laser ~= nil then
		laser.Parent = nil
	end
	if reticleGui ~= nil then
		reticleGui.Enabled = false
	end
end

-- from/to are the laser's ends (on the floor, or hand-to-crosshair in
-- first person, where it's a thin rod: a floor-flat band would be seen
-- edge-on); mark is where the crosshair goes.
local function showAimVisual(from: Vector3, to: Vector3, mark: Vector3, locked: boolean, rod: boolean)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	if laser == nil then
		buildAimVisual()
	end
	local beam, gui, holder = laser :: Part, reticleGui :: ScreenGui, reticle :: Frame
	local ring, dot, stroke = reticleRing :: Frame, reticleDot :: Frame, reticleStroke :: UIStroke
	local color = if locked then Theme.color.success else Theme.color.ink

	local length = (to - from).Magnitude
	beam.Color = color
	local width = if rod then ROD_WIDTH else LASER_WIDTH
	beam.Size = Vector3.new(width, if rod then ROD_WIDTH else LASER_THICKNESS, math.max(length, 0.01))
	beam.CFrame = if length > 0.01 then CFrame.lookAt((from + to) / 2, to) else CFrame.new(from)
	beam.Parent = camera

	local screen, onScreen = camera:WorldToViewportPoint(mark)
	gui.Enabled = onScreen
	holder.Position = UDim2.fromOffset(screen.X, screen.Y)
	local ringPixels = if locked then RETICLE_LOCKED_PIXELS else RETICLE_PIXELS
	ring.Size = UDim2.fromOffset(ringPixels, ringPixels)
	stroke.Color = color
	dot.BackgroundColor3 = color
	dot.BackgroundTransparency = if locked then 0 else 0.3
end

-- Where a rig's feet are: the root's bottom less the hip height.
local function feetOf(root: BasePart): Vector3
	local humanoid = if root.Parent ~= nil then root.Parent:FindFirstChildOfClass("Humanoid") else nil
	local drop = root.Size.Y / 2 + (if humanoid ~= nil then humanoid.HipHeight else 2)
	return root.Position - Vector3.new(0, drop - FLOOR_LIFT, 0)
end

-- Runs the server's own targeting (PowerUpService.resolveTarget) on
-- this client's view of the field.
local function updateLock()
	local def = selectedDef()
	local root = rootOf(Players.LocalPlayer.Character)
	if def == nil or root == nil or (def.target ~= "Aimed" and def.target ~= "Nearest") then
		lockedId, lockedAim = nil, nil
		showLock(nil, false)
		hideAimVisual()
		return
	end

	local candidates: { PowerUpLogic.TargetCandidate } = {}
	local models: { [number]: Model } = {}
	-- In a race the field is the racers; in hub practice, everyone here.
	-- Either way the server re-checks (practice: EffectContext.mayAct).
	local ids: { number } = {}
	if practicing then
		for _, player in Players:GetPlayers() do
			table.insert(ids, player.UserId)
		end
		for id in practiceDummies() do
			table.insert(ids, id)
		end
	else
		for _, entry in progress() do
			table.insert(ids, entry.playerId)
		end
	end
	for _, id in ids do
		if id == selfId then
			continue
		end
		local model = characterFor(id)
		local otherRoot = rootOf(model)
		if model ~= nil and otherRoot ~= nil then
			table.insert(candidates, { id = id, position = toVec3(otherRoot.Position) })
			models[id] = model
		end
	end

	local position = toVec3(root.Position)
	local chosen: number?
	local aim: PowerUpLogic.Vec3? = nil
	if def.target == "Nearest" then
		chosen = PowerUpLogic.nearestInRange(position, candidates, GameConfig.powerUpUseRangeStuds)
	else
		aim = aimDirection()
		chosen = PowerUpLogic.nearestInCone(
			position,
			aim or toVec3(root.CFrame.LookVector),
			candidates,
			GameConfig.powerUpUseRangeStuds,
			GameConfig.powerUpTargetConeDegrees
		)
	end

	lockedId = if def.target == "Aimed" then chosen else nil
	lockedAim = aim
	showLock(if chosen ~= nil then models[chosen] else nil, aimMode ~= nil)

	local camera = Workspace.CurrentCamera
	if def.target == "Aimed" and aim ~= nil and aimMode == "Camera" and camera ~= nil then
		-- First person: the crosshair is where you look (the screen
		-- centre), or on the locked target, and the laser runs to it from
		-- hand height, low and right of the view. Targeting stays flat;
		-- looking up or down only moves what's drawn.
		local view = camera.CFrame
		local hand = view.Position + view.RightVector * HAND_RIGHT - view.UpVector * HAND_DOWN
		local lockedRoot = if chosen ~= nil then rootOf(models[chosen]) else nil
		local mark = if lockedRoot ~= nil
			then lockedRoot.Position
			else view.Position + view.LookVector * GameConfig.powerUpUseRangeStuds
		showAimVisual(hand, mark, mark, lockedRoot ~= nil, true)
	elseif def.target == "Aimed" and aim ~= nil then
		local lockedRoot = if chosen ~= nil then rootOf(models[chosen]) else nil
		local feet = feetOf(root)
		if lockedRoot ~= nil then
			showAimVisual(feet, feetOf(lockedRoot), lockedRoot.Position, true, false)
		else
			-- aim is already unit length (PowerUpLogic.aimForward).
			local reach = feet + Vector3.new(aim.x, 0, aim.z) * GameConfig.powerUpUseRangeStuds
			showAimVisual(feet, reach, reach, false, false)
		end
	else
		hideAimVisual()
	end
end

-- ACTIONS --------------------------------------------------------------

local function selectSlot(index: number)
	if index >= 1 and index <= SLOT_COUNT then
		selected(index)
	end
end

local useToken = 0
local function fire()
	if selectedDef() == nil or pending() then
		return
	end
	updateLock() -- the lock as of this instant, not the last frame
	local payload: { [string]: any } = { slotIndex = selected(), targetPlayerId = lockedId }
	local aim = lockedAim
	if aim ~= nil then
		payload.aimX = math.clamp(aim.x, -1, 1)
		payload.aimZ = math.clamp(aim.z, -1, 1)
	end
	pending(true)
	firedSlot = selected()
	useToken += 1
	local token = useToken
	Net.fireServer("PowerUpUseIntent", payload)
	task.delay(USE_TIMEOUT, function()
		if useToken == token then
			pending(false)
		end
	end)
end

-- FIRST PERSON WHILE AIMING. Camera aim (hold left-click / L2) pulls
-- the camera into first person, so the aim is simply where you look:
-- the mouse (locked to the centre) or right stick turns the view and
-- the character with it, and movement keeps working. Done by pinning
-- the player's zoom limits rather than CameraMode, which leaves the
-- zoom at first person when switched back. On release the old zoom is
-- restored by briefly raising the minimum to it (the camera clamps its
-- zoom up to the minimum), then the minimum itself.
local FIRST_PERSON_ZOOM = 0.5
local ZOOM_RESTORE_DELAY = 0.1
type SavedZoom = { min: number, max: number, zoom: number }
local savedZoom: SavedZoom? = nil
local zoomToken = 0

local function enterFirstPerson()
	local player, camera = Players.LocalPlayer, Workspace.CurrentCamera
	if savedZoom ~= nil or camera == nil then
		return
	end
	savedZoom = {
		min = player.CameraMinZoomDistance,
		max = player.CameraMaxZoomDistance,
		zoom = (camera.CFrame.Position - camera.Focus.Position).Magnitude,
	}
	zoomToken += 1
	player.CameraMinZoomDistance = FIRST_PERSON_ZOOM
	player.CameraMaxZoomDistance = FIRST_PERSON_ZOOM
end

local function leaveFirstPerson()
	local saved = savedZoom
	if saved == nil then
		return
	end
	savedZoom = nil
	local player = Players.LocalPlayer
	player.CameraMaxZoomDistance = saved.max
	player.CameraMinZoomDistance = math.clamp(saved.zoom, saved.min, saved.max)
	zoomToken += 1
	local token = zoomToken
	task.delay(ZOOM_RESTORE_DELAY, function()
		-- Not if aiming began again in the meantime.
		if zoomToken == token then
			player.CameraMinZoomDistance = saved.min
		end
	end)
end

-- AIM WHERE YOU CLICKED. In third person the mouse is free, so the
-- thing you click on is rarely at the screen centre - and first person
-- keeps the camera's old heading, which flicked the view away from it.
-- Instead, turn the camera to look from the character's eyes at the
-- point under the cursor. The default camera builds each frame from
-- Camera.CFrame's look vector, so setting it once holds; the zoom pin
-- then pulls in to first person along that heading, and the clicked
-- spot ends up under the crosshair.
local CLICK_AIM_REACH = 500

local function faceScreenPoint(screenPoint: Vector2)
	local camera = Workspace.CurrentCamera
	local character = Players.LocalPlayer.Character
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	if camera == nil or head == nil or not head:IsA("BasePart") then
		return
	end
	local ray = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character :: Model }
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * CLICK_AIM_REACH, params)
	local point = if hit ~= nil then hit.Position else ray.Origin + ray.Direction * CLICK_AIM_REACH
	local direction = point - head.Position
	if direction.Magnitude < 0.1 then
		return
	end
	local from = camera.CFrame.Position
	camera.CFrame = CFrame.lookAt(from, from + direction.Unit)
end

local function startAim(mode: RaceHUD.AimMode, screenPoint: Vector2?)
	aimMode = mode
	dragX, dragY = 0, 0
	aiming(true)
	-- L2 with nothing aimable selected stays an ordinary trigger (the
	-- HUD only starts a left-click aim for an aimable item).
	local def = selectedDef()
	if mode == "Camera" and def ~= nil and def.target == "Aimed" then
		if screenPoint ~= nil then
			faceScreenPoint(screenPoint)
		end
		enterFirstPerson()
	end
end

local function dragAim(dx: number, dy: number)
	dragX, dragY = dx, dy
end

-- fireIfLocked: letting go of hold-to-aim fires, but only at a locked
-- target - an unlocked release is a cancel, not a wasted item.
local function endAim(fireIfLocked: boolean?)
	if fireIfLocked and aimMode ~= nil and not pending() then
		updateLock()
		if lockedId ~= nil then
			fire()
		end
	end
	aimMode = nil
	aiming(false)
	leaveFirstPerson()
end

-- The server empties the slot and answers with the new inventory; the
-- HUD changes only when that arrives.
local function discard(index: number)
	if index >= 1 and index <= SLOT_COUNT and slots()[index].id ~= nil then
		Net.fireServer("PowerUpDiscardIntent", { slotIndex = index })
	end
end

local store: RaceHUD.Store = {
	selfId = selfId,
	qualifierCount = GameConfig.qualifierCount,
	raceSeconds = GameConfig.raceDurationSeconds,
	endsAt = endsAt,
	tasks = tasks,
	progress = progress,
	slots = slots,
	selected = selected,
	aiming = aiming,
	pending = pending,
	note = note,
	effects = effects,
	objective = objective,
	select = selectSlot,
	fire = fire,
	startAim = startAim,
	dragAim = dragAim,
	endAim = endAim,
	discard = discard,
}

local function trackStation(instance: Instance)
	local stationId = instance:GetAttribute("StationId")
	if instance:IsA("BasePart") and typeof(stationId) == "string" then
		stationParts[stationId] = instance
	end
end

local function onRoute(payload: any)
	local rows: { RaceHUD.TaskRow } = {}
	outstanding = {}
	for _, entry: Route in payload.assignments do
		table.insert(
			rows,
			table.freeze({
				title = taskNames[entry.taskId] or entry.taskId,
				completed = entry.completed,
			})
		)
		if not entry.completed then
			table.insert(outstanding, entry.stationId)
		end
	end
	tasks(rows)
end

local function onEffects(payload: any)
	local list: { HudLogic.Effect } = {}
	for _, entry in payload.effects do
		table.insert(
			list,
			table.freeze({
				id = entry.id,
				category = entry.category,
				kind = entry.kind,
				expiresAt = entry.expiresAt,
			})
		)
	end
	effects(list)
end

local function onInventory(payload: any)
	local byIndex: { [number]: string } = {}
	for _, entry in payload.inventory do
		byIndex[entry.slotIndex] = entry.powerUpId
	end
	local previous = slots()
	local list: { RaceHUD.Slot } = {}
	for index = 1, SLOT_COUNT do
		local id = byIndex[index]
		if previous[index].id == id then
			list[index] = previous[index] -- same frozen table, so Vide leaves the slot alone
		else
			local def = if id ~= nil then powerUpDefs[id] else nil
			if def ~= nil and not explained[def.id] then
				explained[def.id] = true
				local text = string.format("%s: %s", def.displayName, def.description)
				showNote(text, index, "info", ComponentLogic.toastSeconds(text))
			end
			list[index] = table.freeze({
				index = index,
				id = id,
				name = if def ~= nil then def.displayName else id,
				aimable = def ~= nil and def.target == "Aimed",
				roleColor = if def ~= nil then roleColor(def.role) else nil,
			})
		end
	end
	slots(list)

	-- The selected slot just emptied (used, or a new round): move to the
	-- lowest held one, so Q never fires at an empty slot while another
	-- is full.
	if list[selected()].id == nil then
		for index, slot in list do
			if slot.id ~= nil then
				selected(index)
				break
			end
		end
	end
end

-- Per frame while the HUD is up. Returns the stop function.
local function runLockOn(): () -> ()
	local connection = RunService.RenderStepped:Connect(updateLock)
	return function()
		connection:Disconnect()
		endAim()
		lockedId, lockedAim = nil, nil
		showLock(nil, false)
		hideAimVisual()
	end
end

local function onUseResult(payload: any)
	useToken += 1
	pending(false)
	local message = if payload.success then nil else REFUSALS[payload.reason]
	if message ~= nil then
		showNote(message, firedSlot, "warning", REFUSAL_SECONDS)
	end
end

-- A rival used a power-up on you. Named, so a sudden freeze reads as
-- a play someone made rather than lag. Every item says so, even one a
-- ward or a missing task stopped (`landed` false), so the victim always
-- knows who tried. The caster's CallingCard, if they wear one, rides
-- along on the same toast.
local function onHitYou(payload: any)
	local def = powerUpDefs[payload.powerUpId]
	if def == nil or type(payload.casterName) ~= "string" then
		return
	end
	local card = if type(payload.callingCardId) == "string" then callingCardImage[payload.callingCardId] else nil
	local text = string.format("%s used %s on you", payload.casterName, def.displayName)
	if payload.landed == false then
		Toast.show(text .. " - no effect", "warning", card)
	else
		Toast.show(text, "danger", card)
	end
end

-- The objective arrow, while mounted. Returns the stop function.
local function runObjective(): () -> ()
	local target: BasePart? = nil
	local sinceSearch = math.huge
	local lastBearing: number? = nil
	local lastDistance: number? = nil

	local connection = RunService.RenderStepped:Connect(function(dt: number)
		local character = Players.LocalPlayer.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local camera = Workspace.CurrentCamera
		if root == nil or not root:IsA("BasePart") or camera == nil then
			objective(nil)
			lastBearing = nil
			return
		end
		local position = root.Position

		sinceSearch += dt
		if sinceSearch >= SEARCH_INTERVAL then
			sinceSearch = 0
			local points: { HudLogic.Point } = {}
			for _, stationId in outstanding do
				local part: BasePart? = stationParts[stationId]
				if part ~= nil and part.Parent ~= nil then
					table.insert(points, { id = stationId, x = part.Position.X, z = part.Position.Z })
				end
			end
			local best = HudLogic.nearest(points, position.X, position.Z)
			target = if best then stationParts[best.id] else nil
		end

		local goal = target
		if goal == nil then
			objective(nil)
			lastBearing = nil
			return
		end

		local look = camera.CFrame.LookVector
		local offset = goal.Position - position
		local bearing =
			HudLogic.quantize(HudLogic.bearing(look.X, look.Z, offset.X, offset.Z) + ARROW_STEP / 2, ARROW_STEP)
		local distance = math.floor(Vector2.new(offset.X, offset.Z).Magnitude)
		if bearing ~= lastBearing or distance ~= lastDistance then
			lastBearing, lastDistance = bearing, distance
			objective(table.freeze({ bearing = bearing, distance = distance }))
		end
	end)

	return function()
		connection:Disconnect()
		objective(nil)
	end
end

local RaceHUDController: Loader.Controller = {
	name = "RaceHUDController",
	dependencies = { "UIScaleController", "NPCBubbleController" }, -- NPC rigs, for lock-on
}

local unmount: (() -> ())? = nil
local stopObjective: (() -> ())? = nil
local stopLockOn: (() -> ())? = nil
local unmountPractice: (() -> ())? = nil

-- The hub place; or, while its id is unset, a Studio playtest of a
-- place with a Workspace.Hub (so testing a race map shows no tray).
local function isHubServer(): boolean
	local hubPlaceId = GameConfig.matchmaking.hubPlaceId
	if hubPlaceId == 0 then
		return RunService:IsStudio() and Workspace:FindFirstChild("Hub") ~= nil
	end
	return game.PlaceId == hubPlaceId
end

-- HUB PRACTICE (P5-5). The race's own slots, lock-on and keys, alone
-- and always up in the hub, so practising is the real thing. Items
-- are picked up in the practice area but work anywhere in the hub
-- (PracticeService). Put away while a race HUD is up (a Studio
-- playtest can run a round in the hub place).
local function mountPractice()
	if unmountPractice ~= nil or unmount ~= nil or not isHubServer() then
		return
	end
	practicing = true
	local unmountTray = RaceHUD.mountPowerUps(UIScaleController, store)
	local stop = runLockOn()
	unmountPractice = function()
		stop()
		unmountTray()
		practicing = false
	end
end

local function unmountPracticeTray()
	if unmountPractice ~= nil then
		(unmountPractice :: () -> ())()
		unmountPractice = nil
	end
end

local function onRoundState(payload: any)
	endsAt(payload.endsAt)
	local racing = payload.state == "Race"
	if racing then
		unmountPracticeTray()
	end
	if racing and unmount == nil then
		unmount = RaceHUD.mount(UIScaleController, store)
		stopObjective = runObjective()
		stopLockOn = runLockOn()
	elseif not racing and unmount ~= nil then
		(unmount :: () -> ())()
		unmount = nil
		if stopObjective ~= nil then
			stopObjective()
			stopObjective = nil
		end
		if stopLockOn ~= nil then
			stopLockOn()
			stopLockOn = nil
		end
		-- A new race sends a new route and a new inventory; don't show
		-- this one's until then.
		tasks({})
		outstanding = {}
		progress({})
		slots(emptySlots())
		selected(1)
		pending(false)
		note(nil)
	end
	if not racing then
		mountPractice()
	end
end

function RaceHUDController:init()
	Net.onClientEvent("RoundState", onRoundState)
	Net.onClientEvent("TaskAssignmentState", onRoute)
	Net.onClientEvent("TaskProgress", function(payload: any)
		progress(payload.progress)
	end)
	Net.onClientEvent("StatusEffectsChanged", onEffects)
	Net.onClientEvent("PowerUpInventoryChanged", onInventory)
	Net.onClientEvent("PowerUpUseResult", onUseResult)
	Net.onClientEvent("PowerUpHitYou", onHitYou)
end

function RaceHUDController:start()
	for _, instance in CollectionService:GetTagged("TaskStation") do
		trackStation(instance)
	end
	CollectionService:GetInstanceAddedSignal("TaskStation"):Connect(trackStation)
	mountPractice()
end

return RaceHUDController
