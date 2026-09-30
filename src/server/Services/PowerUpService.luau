--!strict
-- Power-up pickups, inventory and use validation (P2-7). Owns the
-- field-pickup lifecycle (spawn/claim/respawn), a player's held
-- inventory, and the use-intent validation pipeline. The pure targeting/
-- cooldown/pool math lives in src/shared/PowerUpLogic.luau; this is the
-- thin Roblox-touching wrapper that supplies real Players/Characters/
-- CollectionService state and applies what that module decides.
--
-- SCOPE: this does NOT apply a power-up's actual gameplay effect (the
-- +35% speed, the freeze, the vision obscure) - that's P2-8's job
-- (Status Effects), "it owns every temporary modification to a
-- character." `PowerUpService.setEffectApplier(fn)` is the seam P2-8
-- wires into once it exists; until then, a use that passes every
-- validation check just logs "no effect resolver wired in yet."
--
-- P5-5: the hub practice area runs THIS service, not a copy, under
-- EffectContext's practice flag. See EffectContext.luau for why, and
-- for the complete list of what the flag changes.
--
-- ===== EVERY WAY A CLIENT COULD TRY TO CHEAT THIS, AND WHAT BLOCKS IT ====
--
-- 1. INFINITE USE. Blocked by `PowerUpLogic.isOnCooldown`, checked
--    against `state.lastUsedAt[powerUpId]` - a server-held timestamp the
--    client never sends and can't influence. A flood of PowerUpUseIntent
--    calls past the rate limiter still hits this on every single one.
--
-- 2. RETARGETING AFTER THE FACT. There is no "confirm" or "redirect" step
--    a client could delay or replay - `handleUseIntent` resolves the
--    target, validates it, and applies the effect entirely within one
--    synchronous call. A client can't send an intent now and a different
--    target later for the SAME use; every use is a fresh, fully
--    revalidated attempt with its own resolved target.
--
-- 3. USING SOMEONE ELSE'S POWER-UP. `handleUseIntent`'s `player` argument
--    comes from NetGuard's own authenticated RemoteEvent connection
--    (Ground Rule 1 - never from anything in the payload), and inventory
--    is looked up as `racerStates[racer.id]` where `racer` is resolved
--    from that same authenticated Player - never from a client-supplied
--    id. There is no field in PowerUpUseIntent's schema a payload could
--    use to claim a different identity at all. P3-6 added a second
--    caller (`useForRacer`, for NPCs) that takes an id, but it is a
--    SERVER-side function reachable only through the loader - no remote
--    routes to it, so a client still has no way to name its own caster.
--
-- 4. RANGE SPOOFING. PowerUpUseIntent's payload carries an OPTIONAL
--    target *hint* (`targetPlayerId`) and an optional aim direction,
--    and nothing else - no position, no distance, no "I'm in range"
--    claim. Range is computed entirely server-side in `resolveTarget`,
--    from `Character.HumanoidRootPart.Position` on both the caster and
--    the candidate target - real Instance state the client has no way
--    to misreport through this remote. The aim direction only chooses
--    WHICH way the lock-on cone points; since any direction is a legal
--    aim, the cone is a consistency check on the locked target, not a
--    security boundary. Range is the boundary, and the lock-on slack
--    (GameConfig.powerUpLockOnSlackStuds) is the most a client gains.
--
-- 5. CLAIMING A PICKUP SOMEONE ELSE ALREADY GOT. `tryClaimPickup` sets
--    `live.claimed = true` as its literal first line, before anything
--    that could yield - Luau's single-threaded event dispatch means a
--    second, near-simultaneous Touched event for the same pickup sees
--    `claimed == true` and bails immediately. There is no remote for
--    "I picked this up" at all - pickup is detected server-side via
--    Touched, never client-asserted (the task's own "server-confirmed"
--    requirement).
--
-- 6. USING AN EMPTY OR UNOWNED SLOT. `slotIndex` only ever indexes into
--    the caster's OWN server-held slots; an out-of-range or empty index
--    is rejected before anything else runs, and there is no way to
--    reference another player's inventory through this payload at all
--    (see #3).
--
-- 7. A FREE LOADOUT. Loadout items are placed only at the start of a
--    race, through StoreService.consumeLoadoutFor - the one function
--    that spends stock. No remote grants a slot.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local PowerUpLogic = require(ReplicatedStorage.Shared.PowerUpLogic)
local Participants = require(ServerScriptService.Server.Participants)
local EffectContext = require(ServerScriptService.Server.EffectContext)

local powerUpDefsById: { [string]: Validate.PowerUpDef } = {}
for _, entry in PowerUps do
	local def = entry.def :: Validate.PowerUpDef
	powerUpDefsById[def.id] = def
end

-- ===== spawn points =======================================================
--
-- No map-loading service exists yet (same gap TaskService.luau documents
-- in its own header comment) - spawn points come through an injection
-- point rather than this file reaching into ServerStorage.Maps itself.
-- `debugLoadSpawnPointsFromMap` is a Studio-only convenience that fills
-- it in today from a map's own CollectionService tags.

export type SpawnPointRecord = {
	part: BasePart,
	rarity: string, -- map-kit-spec.md's PowerUpSpawn.Rarity - "Common" | "Uncommon" | "Rare"
	allowedPowerUpIds: { string }?, -- nil/empty = any def matching `rarity` is eligible
}

type LivePickup = {
	part: BasePart,
	def: Validate.PowerUpDef,
	claimed: boolean,
}

type InventoryItem = {
	powerUpId: string,
	acquiredAt: number,
}

type RacerState = {
	-- Keyed by slot index, 1..powerUpInventorySlots, with holes: slots
	-- are fixed positions (PowerUpLogic.slotForPickup), so using slot 2
	-- never moves slot 3.
	inventory: { [number]: InventoryItem },
	lastUsedAt: { [string]: number },
}

local spawnPoints: { SpawnPointRecord } = {}
local livePickups: { [SpawnPointRecord]: LivePickup } = {}
-- P8-2: one part per spawn point for as long as that point exists,
-- shown on spawn and hidden on claim rather than created and destroyed.
-- Pooling by unparenting would save nothing here: a server-side part
-- leaving and re-entering Workspace replicates to every client as a full
-- destroy and create. A property change only sends the changed fields.
-- The practice area respawns pickups for the life of the hub server, so
-- this was unbounded churn there.
local pickupParts: { [SpawnPointRecord]: BasePart } = {}
local pendingRespawnThreads: { [SpawnPointRecord]: thread } = {}
local racerStates: { [number]: RacerState } = {}
local pickupsFolder: Folder? = nil
local mapRarityWeights: Validate.PowerUpRarityWeights? = nil

local function setSpawnPoints(points: { SpawnPointRecord })
	spawnPoints = points
end

local function debugLoadSpawnPointsFromMap(mapRoot: Instance)
	local points: { SpawnPointRecord } = {}

	for _, instance in CollectionService:GetTagged("PowerUpSpawn") do
		if not (instance:IsDescendantOf(mapRoot) and instance:IsA("BasePart")) then
			continue
		end

		local rarity = instance:GetAttribute("Rarity") :: string?
		if rarity == nil then
			warn(string.format("PowerUpService: %s is missing Rarity - skipped", instance:GetFullName()))
			continue
		end

		local allowedRaw = instance:GetAttribute("AllowedPowerUpIds") :: string?
		local allowed = if allowedRaw ~= nil and allowedRaw ~= "" then string.split(allowedRaw, ",") else nil

		table.insert(points, { part = instance, rarity = rarity, allowedPowerUpIds = allowed })
	end

	setSpawnPoints(points)
	print(string.format("PowerUpService: loaded %d spawn point(s) from %s", #points, mapRoot:GetFullName()))
end

-- Optional per-map override on GameConfig.powerUpRotationTimers - see
-- Validate.PowerUpRarityWeights' own doc comment for the two different
-- units (base seconds vs. multiplier) sharing this one shape.
local function setMapRarityWeights(weights: Validate.PowerUpRarityWeights?)
	mapRarityWeights = weights
end

-- ===== effect application (P2-8's seam) ===================================

-- Takes PARTICIPANTS, not Players (P3-5): a power-up's target may be an
-- NPC, and "NPCs are affected by player power-ups exactly like humans
-- are" is only true if the applier can't tell which it's been handed.
export type EffectApplier = (
	caster: Participants.Participant,
	target: Participants.Participant?,
	def: Validate.PowerUpDef
) -> (boolean, string)

local function defaultEffectApplier(
	_caster: Participants.Participant,
	_target: Participants.Participant?,
	_def: Validate.PowerUpDef
): (boolean, string)
	return true, "no effect resolver wired in yet (P2-8)"
end

local effectApplier: EffectApplier = defaultEffectApplier

local function setEffectApplier(fn: EffectApplier)
	effectApplier = fn
end

-- Overclock's seam, same shape as the applier's: StatusEffects supplies
-- a racer's resolved CooldownRate. 1.0 until it's wired in.
local cooldownRateSource: (racerId: number) -> number = function(_racerId: number): number
	return 1
end

local function setCooldownRateSource(fn: (racerId: number) -> number)
	cooldownRateSource = fn
end

local function cooldownSecondsFor(racerId: number, def: Validate.PowerUpDef): number
	return def.cooldownSeconds * cooldownRateSource(racerId)
end

-- ===== audit log ===========================================================

export type AuditEntry = {
	at: number,
	playerId: number,
	playerName: string,
	powerUpId: string?,
	targetPlayerId: number?,
	result: "Applied" | "Rejected",
	reason: string?,
}

local AUDIT_LOG_CAP = 2000
local auditLog: { AuditEntry } = {}

local function defaultAuditSink(entry: AuditEntry)
	print(
		string.format(
			"PowerUpService AUDIT: %s (%d) used %s%s -> %s%s",
			entry.playerName,
			entry.playerId,
			entry.powerUpId or "?",
			if entry.targetPlayerId ~= nil then string.format(" on %d", entry.targetPlayerId) else "",
			entry.result,
			if entry.reason ~= nil then string.format(" (%s)", entry.reason) else ""
		)
	)
end

local auditSink: (entry: AuditEntry) -> () = defaultAuditSink

local function setAuditSink(fn: (entry: AuditEntry) -> ())
	auditSink = fn
end

-- Takes a participant (P3-6), so a bot's use is audited in the same log
-- and the same shape a human's is - an audit trail that only records
-- half the field would be no use at all for balancing power-ups. The
-- payload's field NAMES are unchanged (`playerId`/`playerName`): the
-- log's readers predate NPCs, and a bot is just a negative id to them.
local function audit(
	racer: Participants.Participant,
	powerUpId: string?,
	targetPlayerId: number?,
	result: "Applied" | "Rejected",
	reason: string?
)
	-- P5-5: the audit feeds balancing, and hub practice isn't a round.
	if not EffectContext.recordsStats() then
		return
	end

	local entry: AuditEntry = {
		at = Workspace:GetServerTimeNow(),
		playerId = racer.id,
		playerName = racer.displayName,
		powerUpId = powerUpId,
		targetPlayerId = targetPlayerId,
		result = result,
		reason = reason,
	}
	table.insert(auditLog, entry)
	if #auditLog > AUDIT_LOG_CAP then
		table.remove(auditLog, 1)
	end
	auditSink(entry)
end

-- ===== helpers =============================================================

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function toVec3(v: Vector3): PowerUpLogic.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function characterRoot(character: Model?): BasePart?
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- P8-1: how far a character's root may be from a pickup's centre and
-- still count as touching it. The ball's 1.25 radius + ~3 studs from an
-- R15 root down to the feet + ~5 studs of run-speed-times-latency slack,
-- rounded up. Generous on purpose: a legit grab must never be refused,
-- and anything within 10 studs was going to reach the pickup anyway.
local PICKUP_REACH_STUDS = 10

-- THE PICKUP LOOK. The orb is the claimable part but is never drawn:
-- what players see is `Haze`, a slightly larger ForceField-material
-- shell in the item's role colour (PowerUpLogic.ROLE_RGB). ForceField
-- draws mostly at the rim, so it reads as a force field around the icon
-- rather than a tinted bubble hiding it (a ForceField ORB at 0.5
-- transparency was tried before and swallowed the icon; the rim-only
-- shell at full opacity doesn't). The item's own model -
-- ServerStorage.PowerUpModels[<id>], built by
-- scripts/build-powerup-models.luau - is cloned in as `Visual`, and
-- PickupController spins it and breathes the haze client-side (a
-- server-side animation would replicate every frame). Two lights: a
-- role-coloured glow at the centre that spills onto the floor, and a
-- near-white key light above so the icon's non-neon faces aren't
-- black in a dark map. The energy-shield look comes from two additive,
-- lighting-independent sprites layered over that rim: a soft `Glow`
-- halo and a fast-turning `Vortex` swirl, both the engine's own legacy
-- ForceField textures (shipped in every client's content folder, so no
-- upload and no moderation). No model for an id is fine: the haze alone
-- still reads as a pickup.
local ORB_SIZE = 3.2 -- the invisible touch/claim ball
local HAZE_DIAMETER = 4.6
local HAZE_TRANSPARENCY = 0
local HAZE_WHITENESS = 0.35 -- rim and sprites: role colour lifted toward white
local VISUAL_FIT_STUDS = 2.4 -- the model's longest side, inside the orb
local KEY_LIGHT_HEIGHT = 2.4 -- studs above the orb centre
local KEY_LIGHT_WHITENESS = 0.7 -- lerp from role colour toward white
local MOTE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local GLOW_TEXTURE = "rbxasset://textures/particles/forcefield_glow_main.dds"
local VORTEX_TEXTURE = "rbxasset://textures/particles/forcefield_vortex_main.dds"

-- One of the shield sprites: spawned at the orb centre, locked to it,
-- fading in and out while it spins so overlapping copies read as a
-- continuous shimmer rather than a blinking decal.
local function shieldSprite(
	parent: Instance,
	name: string,
	texture: string,
	size: number,
	peakOpacity: number,
	spin: number,
	rate: number
): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.LockedToPart = true
	emitter.Size = NumberSequence.new(size)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.4, 1 - peakOpacity),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(1.2, 1.6)
	emitter.Rate = rate
	emitter.Speed = NumberRange.new(0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-spin, spin)
	emitter.Enabled = false
	emitter.Parent = parent
	return emitter
end

local function roleColor(role: string): Color3
	local rgb = PowerUpLogic.ROLE_RGB[role]
	return if rgb then Color3.fromRGB(rgb[1], rgb[2], rgb[3]) else Color3.fromRGB(255, 255, 255)
end

local function clearVisual(part: BasePart)
	local visual = part:FindFirstChild("Visual")
	if visual ~= nil then
		visual:Destroy()
	end
end

local function attachVisual(part: BasePart, powerUpId: string)
	clearVisual(part)
	local folder = ServerStorage:FindFirstChild("PowerUpModels")
	local source = if folder ~= nil then folder:FindFirstChild(powerUpId) else nil
	if source == nil or not source:IsA("Model") then
		return
	end
	local visual = source:Clone()
	visual.Name = "Visual"
	for _, d in visual:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
		end
	end
	local extents = visual:GetExtentsSize()
	local longest = math.max(extents.X, extents.Y, extents.Z)
	if longest > 0 then
		visual:ScaleTo(visual:GetScale() * VISUAL_FIT_STUDS / longest)
	end
	visual:PivotTo(part.CFrame)
	visual.Parent = part
end

-- STUDIO ONLY playtest override: set Workspace attribute
-- DebugPowerUpTarget to a target kind ("Aimed", "Nearest", "Self",
-- "Area") and every spawn point drops only items of that kind,
-- whatever its rarity or allow-list. Ignored outside Studio; a client
-- can't set it on the server either way (attributes don't replicate up).
local function debugTargetFilter(): string?
	if not RunService:IsStudio() then
		return nil
	end
	local target = Workspace:GetAttribute("DebugPowerUpTarget")
	return if typeof(target) == "string" and target ~= "" then target else nil
end

local function eligiblePool(point: SpawnPointRecord): { Validate.PowerUpDef }
	local pool: { Validate.PowerUpDef } = {}
	local debugTarget = debugTargetFilter()
	for _, def in powerUpDefsById do
		if debugTarget ~= nil then
			if def.target == debugTarget and Loader.get("LiveConfig").isPowerUpEnabled(def.id) then
				table.insert(pool, def)
			end
			continue
		end
		if def.rarity ~= point.rarity then
			continue
		end
		if not Loader.get("LiveConfig").isPowerUpEnabled(def.id) then
			continue -- P8-5: switched off by live ops
		end
		if point.allowedPowerUpIds ~= nil and #point.allowedPowerUpIds > 0 then
			if table.find(point.allowedPowerUpIds, def.id) == nil then
				continue
			end
		end
		table.insert(pool, def)
	end
	return pool
end

local function respawnSecondsFor(rarity: string): number
	local base = (GameConfig.powerUpRotationTimers :: any)[rarity] :: number
	local multiplier = if mapRarityWeights ~= nil then (mapRarityWeights :: any)[rarity] :: number else 1
	return base * multiplier
end

-- ===== spawning + claiming =================================================

local spawnAt: (point: SpawnPointRecord) -> ()

-- Hidden rather than destroyed (see pickupParts). CanTouch and CanQuery
-- go off with the visuals, so a hidden pickup can't be claimed or hit by
-- a raycast.
local function hideLivePickup(point: SpawnPointRecord)
	livePickups[point] = nil
	local part: BasePart? = pickupParts[point]
	if part ~= nil then
		part.CanTouch = false
		part.CanQuery = false
		local haze = part:FindFirstChild("Haze")
		if haze ~= nil and haze:IsA("BasePart") then
			haze.Transparency = 1
		end
		for _, d in part:GetDescendants() do
			if d:IsA("Light") then
				d.Enabled = false
			elseif d:IsA("ParticleEmitter") then
				d.Enabled = false
				d:Clear()
			end
		end
		clearVisual(part)
	end
end

local tryClaimPickup: (point: SpawnPointRecord, live: LivePickup, hitPart: BasePart) -> ()

local function pickupPartFor(point: SpawnPointRecord): BasePart
	local existing: BasePart? = pickupParts[point]
	if existing ~= nil then
		return existing
	end
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(ORB_SIZE, ORB_SIZE, ORB_SIZE)
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Transparency = 1
	part.CFrame = point.part.CFrame + Vector3.new(0, 2.5, 0)

	local haze = Instance.new("Part")
	haze.Name = "Haze"
	haze.Shape = Enum.PartType.Ball
	haze.Size = Vector3.new(HAZE_DIAMETER, HAZE_DIAMETER, HAZE_DIAMETER)
	haze.Material = Enum.Material.ForceField
	haze.Transparency = 1
	haze.Anchored = true
	haze.CanCollide = false
	haze.CanTouch = false
	haze.CanQuery = false
	haze.CastShadow = false
	haze.CFrame = part.CFrame
	haze:SetAttribute("BaseDiameter", HAZE_DIAMETER) -- PickupController breathes around this
	haze.Parent = part

	local glow = Instance.new("PointLight")
	glow.Name = "Glow"
	glow.Range = 10
	glow.Brightness = 1.5
	glow.Shadows = false
	glow.Enabled = false
	glow.Parent = part

	local keyAttachment = Instance.new("Attachment")
	keyAttachment.Name = "KeyLight"
	keyAttachment.Position = Vector3.new(0, KEY_LIGHT_HEIGHT, 0)
	keyAttachment.Parent = part
	local key = Instance.new("PointLight")
	key.Range = 5
	key.Brightness = 3
	key.Shadows = false
	key.Enabled = false
	key.Parent = keyAttachment

	local motes = Instance.new("ParticleEmitter")
	motes.Name = "Motes"
	motes.Texture = MOTE_TEXTURE
	motes.LightEmission = 1
	motes.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	motes.Transparency = NumberSequence.new(0.2)
	motes.Lifetime = NumberRange.new(1, 1.6)
	motes.Rate = 8
	motes.Speed = NumberRange.new(0.3, 0.6)
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.Shape = Enum.ParticleEmitterShape.Sphere
	motes.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	motes.Enabled = false
	motes.Parent = part

	-- An attachment emits from a point, so the sprites sit dead centre.
	local core = Instance.new("Attachment")
	core.Name = "Core"
	core.Parent = part
	-- Sizes tuned by eye in playtest: the glow texture is a soft centre
	-- blob so it matches the shell at ~HAZE_DIAMETER, but the vortex's
	-- swirl reaches the sprite edge, so it needs a much smaller size to
	-- sit just outside the rim instead of drawing a second ring.
	shieldSprite(core, "Glow", GLOW_TEXTURE, HAZE_DIAMETER - 0.2, 0.6, 20, 3)
	shieldSprite(core, "Vortex", VORTEX_TEXTURE, 3.6, 0.85, 120, 5)

	part.Parent = pickupsFolder
	-- Connected once for the part's life. It reads the live record at
	-- touch time, so a touch while hidden finds nothing to claim.
	part.Touched:Connect(function(hit: BasePart)
		local live = livePickups[point]
		if live ~= nil then
			tryClaimPickup(point, live, hit)
		end
	end)
	pickupParts[point] = part
	return part
end

local function cancelPendingRespawn(point: SpawnPointRecord)
	local thread = pendingRespawnThreads[point]
	if thread ~= nil then
		task.cancel(thread)
		pendingRespawnThreads[point] = nil
	end
end

local function scheduleRespawn(point: SpawnPointRecord)
	cancelPendingRespawn(point)
	local seconds = respawnSecondsFor(point.rarity)
	pendingRespawnThreads[point] = task.delay(seconds, function()
		pendingRespawnThreads[point] = nil
		spawnAt(point)
	end)
end

-- Only a human has an inventory HUD to update. An NPC's inventory is
-- server state nobody needs told about, so this returns early for one
-- rather than inventing a broadcast no client would consume.
local function broadcastInventory(racer: Participants.Participant)
	local player = racer.player
	if player == nil then
		return
	end

	local state = racerStates[racer.id]
	local items = {}
	if state ~= nil then
		for slotIndex = 1, GameConfig.powerUpInventorySlots do
			local item = state.inventory[slotIndex]
			if item ~= nil then
				table.insert(items, { slotIndex = slotIndex, powerUpId = item.powerUpId })
			end
		end
	end
	Net.fireClient(
		"PowerUpInventoryChanged",
		player,
		{ slotCount = GameConfig.powerUpInventorySlots, inventory = items }
	)
end

local function stateFor(racerId: number): RacerState
	local state = racerStates[racerId]
	if state == nil then
		state = { inventory = {}, lastUsedAt = {} }
		racerStates[racerId] = state
	end
	return state :: RacerState
end

-- "Pickup is server-confirmed" (the task's own requirement) - detected
-- via Touched, never a client remote. `live.claimed = true` is set
-- synchronously as the first line below, before anything that could
-- yield - see this file's header comment, exploit #5, for why that
-- ordering is what makes a near-simultaneous double-claim impossible.
tryClaimPickup = function(point: SpawnPointRecord, live: LivePickup, hitPart: BasePart)
	if live.claimed then
		return
	end

	local character = hitPart.Parent
	if character == nil or not character:IsA("Model") then
		return
	end

	-- P3-6: resolved through the participant roster rather than
	-- Players:GetPlayerFromCharacter, which can only ever answer for a
	-- human - an NPC walking over a pickup would otherwise step straight
	-- over it, and "NPCs pick up power-ups on their route"
	-- (architecture.md §4) would quietly never happen.
	local racer = Participants.fromCharacter(character)
	if racer == nil then
		return
	end
	-- P5-5: in practice, anyone the practice gate admits.
	if not EffectContext.mayAct(racer.id) then
		return
	end
	-- P8-1: the touch itself is client-reported for a player's own
	-- character, so re-measure it server-side before believing it.
	local root = characterRoot(racer.character)
	if
		root == nil
		or not PowerUpLogic.isWithinPickupReach(toVec3(root.Position), toVec3(live.part.Position), PICKUP_REACH_STUDS)
	then
		return
	end

	live.claimed = true

	local state = stateFor(racer.id)
	local acquiredAt: { [number]: number } = {}
	for slotIndex, item in state.inventory do
		acquiredAt[slotIndex] = item.acquiredAt
	end
	local slotIndex =
		PowerUpLogic.slotForPickup(acquiredAt, GameConfig.powerUpInventorySlots, GameConfig.powerUpFullInventoryPolicy)

	if slotIndex == nil then
		live.claimed = false -- refused - the world pickup stays available for someone else
		return
	end

	-- Under Swap this overwrites (evicts) the oldest held item.
	state.inventory[slotIndex] = { powerUpId = live.def.id, acquiredAt = now() }
	broadcastInventory(racer)

	hideLivePickup(point)
	scheduleRespawn(point)
end

spawnAt = function(point: SpawnPointRecord)
	hideLivePickup(point) -- defensive idempotency guard; shouldn't normally find one live

	local pool = eligiblePool(point)
	if #pool == 0 then
		warn(string.format("PowerUpService: no eligible power-up defs for a %s spawn point - skipped", point.rarity))
		return
	end

	local def = PowerUpLogic.selectUniform(pool, math.random())

	local part = pickupPartFor(point)
	part.Name = string.format("PowerUpPickup_%s", def.id)
	local color = roleColor(def.role)
	part.Color = color
	local shieldColor = color:Lerp(Color3.new(1, 1, 1), HAZE_WHITENESS)
	local haze = part:FindFirstChild("Haze")
	if haze ~= nil and haze:IsA("BasePart") then
		haze.Color = shieldColor
		haze.Transparency = HAZE_TRANSPARENCY
	end
	local core = part:FindFirstChild("Core")
	if core ~= nil then
		for _, sprite in core:GetChildren() do
			if sprite:IsA("ParticleEmitter") then
				sprite.Color = ColorSequence.new(shieldColor)
				sprite.Enabled = true
				sprite:Emit(6) -- start full rather than fading in from empty
			end
		end
	end
	local glow = part:FindFirstChild("Glow")
	if glow ~= nil and glow:IsA("PointLight") then
		glow.Color = color
		glow.Enabled = true
	end
	local keyAttachment = part:FindFirstChild("KeyLight")
	local key = if keyAttachment ~= nil then keyAttachment:FindFirstChildOfClass("PointLight") else nil
	if key ~= nil then
		key.Color = color:Lerp(Color3.new(1, 1, 1), KEY_LIGHT_WHITENESS)
		key.Enabled = true
	end
	local motes = part:FindFirstChild("Motes")
	if motes ~= nil and motes:IsA("ParticleEmitter") then
		motes.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.3))
		motes.Enabled = true
	end
	part.CanTouch = true
	part.CanQuery = true
	attachVisual(part, def.id)

	livePickups[point] = { part = part, def = def, claimed = false }
end

-- ===== use-intent validation pipeline ======================================

-- P3-5: scans the participant roster rather than Players:GetPlayers(),
-- so an NPC standing in front of the caster is as targetable as a human
-- standing in the same spot - the targeting math in PowerUpLogic never
-- learns which it picked. An explicit target id from a client is still
-- looked up in the registry (not via Players:GetPlayerByUserId), which
-- also means a client CAN aim at a bot on purpose, deliberately: a
-- power-up that can't be aimed at half the field would be a strange
-- thing to hand a player.
--
-- LOCK-ON (powerups.md "Inventory and aiming"): an Aimed item's cone
-- points along the client's aim direction when it sent one (hold-to-aim
-- or a drag from the slot), else along the character's facing (a quick
-- fire). The client highlights the target it locked on to and sends its
-- id; that target is honoured if it's still in range and cone, with
-- GameConfig's lock-on slack for the round trip, and REFUSED otherwise
-- rather than swapped for someone the player never saw highlighted. A
-- refused use keeps the item (see useFor).
local function resolveTarget(
	caster: Participants.Participant,
	def: Validate.PowerUpDef,
	explicitTargetId: number?,
	aim: PowerUpLogic.Vec3?
): Participants.Participant?
	local casterRoot = characterRoot(caster.character)
	if casterRoot == nil then
		return nil
	end
	local casterPosition = toVec3(casterRoot.Position)
	local casterForward = aim or toVec3(casterRoot.CFrame.LookVector)

	if def.target == "Aimed" and explicitTargetId ~= nil then
		local explicitTarget = Participants.get(explicitTargetId)
		if explicitTarget == nil or explicitTarget.id == caster.id or not EffectContext.mayAct(explicitTarget.id) then
			return nil
		end
		local targetRoot = characterRoot(explicitTarget.character)
		if targetRoot == nil then
			return nil
		end
		local inRange = PowerUpLogic.isWithinRangeAndCone(
			casterPosition,
			casterForward,
			toVec3(targetRoot.Position),
			GameConfig.powerUpUseRangeStuds + GameConfig.powerUpLockOnSlackStuds,
			math.min(GameConfig.powerUpTargetConeDegrees + GameConfig.powerUpLockOnSlackDegrees, 360)
		)
		if inRange then
			return explicitTarget
		end
		return nil
	end

	-- No usable explicit target (or a Nearest-target item, which always
	-- auto-targets regardless of any client hint) - smart targeting.
	local candidates: { PowerUpLogic.TargetCandidate } = {}
	local byId: { [number]: Participants.Participant } = {}
	for _, other in Participants.all() do
		if other.id == caster.id or not EffectContext.mayAct(other.id) then
			continue
		end
		local otherRoot = characterRoot(other.character)
		if otherRoot == nil then
			continue
		end
		table.insert(candidates, { id = other.id, position = toVec3(otherRoot.Position) })
		byId[other.id] = other
	end

	local chosenId: number?
	if def.target == "Nearest" then
		chosenId = PowerUpLogic.nearestInRange(casterPosition, candidates, GameConfig.powerUpUseRangeStuds)
	else
		chosenId = PowerUpLogic.nearestInCone(
			casterPosition,
			casterForward,
			candidates,
			GameConfig.powerUpUseRangeStuds,
			GameConfig.powerUpTargetConeDegrees
		)
	end

	if chosenId == nil then
		return nil
	end
	return byId[chosenId]
end

-- Same shape as broadcastInventory: the confirmation exists to update a
-- UI, and a bot has no UI. Its use is still audited either way, which
-- is where an NPC's outcome is actually observable from.
local function sendResult(
	racer: Participants.Participant,
	success: boolean,
	powerUpId: string?,
	targetPlayerId: number?,
	reason: string?
)
	local player = racer.player
	if player == nil then
		return
	end

	Net.fireClient("PowerUpUseResult", player, {
		success = success,
		powerUpId = powerUpId,
		targetPlayerId = targetPlayerId,
		reason = reason,
	})
end

-- THE one validated use path, for every caster there is (P3-6).
--
-- "Route every use through the existing validated server path, never a
-- shortcut" is P3-6's own requirement for NPC power-up use, and the way
-- to actually guarantee it is to have exactly one function that can
-- consume an inventory slot - this one. A bot enters it through
-- `useForRacer` below and a human through `handleUseIntent`, and from
-- this line down the two are literally the same code: the same slot
-- check, the same cooldown check against the same server-held
-- timestamp, the same range/cone resolution, the same effect applier,
-- the same audit entry. There is no bot-only branch and no way to add
-- one without editing this function, which is the point.
--
-- Notably this means an NPC is subject to P2-8's hard-control immunity
-- and diminishing-returns rules on its TARGETS exactly as a player is
-- (they live inside effectApplier), and gets nothing back for a
-- rejected use except a log line - same as a player whose attempt
-- missed.
local function useFor(
	racer: Participants.Participant,
	slotIndex: number?,
	targetRacerId: number?,
	aim: PowerUpLogic.Vec3?
)
	local resolvedSlotIndex = slotIndex or 1
	local state = racerStates[racer.id]

	-- P5-5: always true in a round. In practice this stops someone a
	-- match has claimed from using a practice item.
	if not EffectContext.mayAct(racer.id) then
		audit(racer, nil, nil, "Rejected", "not practising")
		sendResult(racer, false, nil, nil, "not practising")
		return
	end

	if state == nil then
		audit(racer, nil, nil, "Rejected", "no inventory")
		sendResult(racer, false, nil, nil, "no inventory")
		return
	end

	local item = if resolvedSlotIndex <= GameConfig.powerUpInventorySlots
		then state.inventory[resolvedSlotIndex]
		else nil
	if item == nil then
		audit(racer, nil, nil, "Rejected", "empty slot")
		sendResult(racer, false, nil, nil, "empty slot")
		return
	end

	local def = powerUpDefsById[item.powerUpId]
	if def == nil then
		-- Defensive only - can't happen for an id this service itself put
		-- in the inventory, since it's always drawn from powerUpDefsById.
		audit(racer, item.powerUpId, nil, "Rejected", "unknown power-up id")
		sendResult(racer, false, item.powerUpId, nil, "unknown power-up id")
		return
	end

	-- P8-5: switched off by live ops after it was picked up. Refused, not
	-- consumed - the item stays in the slot in case it comes back on.
	if not Loader.get("LiveConfig").isPowerUpEnabled(def.id) then
		audit(racer, def.id, nil, "Rejected", "disabled by live ops")
		sendResult(racer, false, def.id, nil, "temporarily disabled")
		return
	end

	if PowerUpLogic.isOnCooldown(state.lastUsedAt[def.id], cooldownSecondsFor(racer.id, def), now()) then
		audit(racer, def.id, nil, "Rejected", "on cooldown")
		sendResult(racer, false, def.id, nil, "on cooldown")
		return
	end

	local resolvedTarget: Participants.Participant? = nil
	if def.target == "Self" then
		resolvedTarget = racer
	elseif def.target == "Area" then
		resolvedTarget = nil -- a zone at the caster's own position, not a racer target
	else
		resolvedTarget = resolveTarget(racer, def, targetRacerId, aim)
		if resolvedTarget == nil then
			audit(racer, def.id, nil, "Rejected", "no valid target")
			sendResult(racer, false, def.id, nil, "no valid target")
			return
		end
	end

	-- THE ITEM IS CONSUMED HERE, before the effect is applied and
	-- regardless of whether it lands.
	--
	-- P2-7 never removed a used item from the inventory at all, which
	-- was a bug rather than a design choice: powerups.md describes a
	-- field pickup as "consumed on pickup, usable immediately, no
	-- persistent ownership," and with a 1-slot inventory and the Refuse
	-- full-inventory policy, an item that never leaves the slot means a
	-- player picks up exactly one power-up per round, re-uses it every
	-- cooldown forever, and can never pick up another. Found while
	-- building P3-6, whose whole utility AI is premised on using an item
	-- costing you the item.
	--
	-- Consuming BEFORE the applier, and on a blocked application too, is
	-- the one part of this powerups.md only settles for a single case -
	-- rule 5 (Task Scramble immunity): "the caster's power-up is
	-- consumed with no effect." Rules 1-3 (hard-control immunity,
	-- diminishing returns, the rolling cap) are silent on it. Treating
	-- them the same way is the consistent reading: a use that found a
	-- legal target has been committed, and the victim's anti-frustration
	-- protection is meant to cost the attacker something. Revisit here
	-- if playtesting says firing into an immunity window feels unfair
	-- rather than punishing.
	state.inventory[resolvedSlotIndex] = nil -- a hole, not a shift: slots are fixed positions
	state.lastUsedAt[def.id] = now()
	broadcastInventory(racer)

	local resolvedTargetId = if resolvedTarget ~= nil then resolvedTarget.id else nil
	local applied, description = effectApplier(racer, resolvedTarget, def)

	if not applied then
		audit(racer, def.id, resolvedTargetId, "Rejected", description)
		sendResult(racer, false, def.id, resolvedTargetId, description)
		return
	end

	audit(racer, def.id, resolvedTargetId, "Applied", description)
	sendResult(racer, true, def.id, resolvedTargetId, description)

	local victim = if resolvedTarget ~= nil and resolvedTarget.id ~= racer.id then resolvedTarget.player else nil
	if victim ~= nil then
		Net.fireClient("PowerUpHitYou", victim, { powerUpId = def.id, casterName = racer.displayName })
	end
end

-- The client remote's entry point: authenticate the Player into a
-- participant, then hand over to the one path above.
local function handleUseIntent(player: Player, slotIndex: number?, targetPlayerId: number?, aim: PowerUpLogic.Vec3?)
	local racer = Participants.fromPlayer(player)
	if racer == nil then
		warn(string.format("PowerUpService: %s used a power-up while not on the roster", player.Name))
		return
	end
	useFor(racer, slotIndex, targetPlayerId, aim)
end

-- The HUD's drag-to-bin. Only ever empties one of the SENDER'S own
-- slots (header exploit #3/#6): no cooldown, no effect, no audit-worthy
-- outcome - the slot is simply free for the next pickup.
local function handleDiscardIntent(player: Player, slotIndex: number)
	local racer = Participants.fromPlayer(player)
	local state = if racer ~= nil then racerStates[racer.id] else nil
	if racer == nil or state == nil or slotIndex > GameConfig.powerUpInventorySlots then
		return
	end
	if state.inventory[slotIndex] == nil then
		return
	end
	state.inventory[slotIndex] = nil -- a hole, like a use
	broadcastInventory(racer)
end

-- P3-6's entry point. Takes an ID, not a participant, so NPCBrain can't
-- hand in a fabricated roster entry - the lookup happens here, against
-- the same registry every other caller uses.
local function useForRacer(racerId: number, slotIndex: number?, targetRacerId: number?)
	local racer = Participants.get(racerId)
	if racer == nil then
		return
	end
	useFor(racer, slotIndex, targetRacerId)
end

-- ===== round lifecycle ======================================================

-- Clears every pickup, timer and inventory, then spawns at every spawn
-- point. A round runs it on Race; PracticeService runs it once at boot.
local function startPickups()
	-- Idempotent reset - a real server only ever runs one round
	-- (architecture.md), but Studio's debug interface can replay Race
	-- repeatedly on the same server (see TaskHandlerService.luau's
	-- identical concern), which would otherwise leave orphaned pickups
	-- and dangling respawn timers from a previous test race.
	for point in pendingRespawnThreads do
		cancelPendingRespawn(point)
	end
	for point in livePickups do
		hideLivePickup(point)
	end
	-- A part whose spawn point was replaced (a new map, or the practice
	-- area) would otherwise sit forever at the old position.
	local current: { [SpawnPointRecord]: boolean } = {}
	for _, point in spawnPoints do
		current[point] = true
	end
	for point, part in pickupParts do
		if not current[point] then
			part:Destroy()
			pickupParts[point] = nil
		end
	end
	racerStates = {}

	if pickupsFolder == nil then
		local folder = Instance.new("Folder")
		folder.Name = "PowerUpPickups"
		folder.Parent = Workspace
		pickupsFolder = folder
	end

	if #spawnPoints == 0 then
		warn("PowerUpService: no spawn points set (no map or practice area) - skipping power-up spawns")
		return
	end

	for _, point in spawnPoints do
		spawnAt(point)
	end
end

-- The pre-game loadout starts in the slots, in the order the player
-- picked it (powerups.md "Inventory and aiming"), which settles
-- store-receipts.md §5's open seam. Humans only: an NPC has no profile
-- and so no loadout. Runs after startPickups' reset, so a Studio replay
-- of Race spends the (by then empty) loadout again rather than stacking
-- items from the previous run.
local function grantLoadouts()
	local StoreService = Loader.get("StoreService") :: any
	for _, racer in Participants.all() do
		local player = racer.player
		if player == nil then
			continue
		end
		local granted = StoreService.consumeLoadoutFor(player) :: { string }
		if #granted == 0 then
			continue
		end
		local state = stateFor(racer.id)
		local at = now()
		for slotIndex, powerUpId in granted do
			-- Validate pins powerUpInventorySlots >= store.loadoutSlots, so
			-- this never drops an item whose stock was just spent.
			state.inventory[slotIndex] = { powerUpId = powerUpId, acquiredAt = at }
		end
		broadcastInventory(racer)
	end
end

local function beginRace()
	EffectContext.assertRound("PowerUpService.beginRace")
	startPickups()
	grantLoadouts()
end

-- P5-5: empties one participant's held items, e.g. when a match
-- claims them, so nothing is carried out of practice.
local function clearInventoryFor(racerId: number)
	local state = racerStates[racerId]
	if state == nil or next(state.inventory) == nil then
		return
	end
	state.inventory = {}
	local racer = Participants.get(racerId)
	if racer ~= nil then
		broadcastInventory(racer)
	end
end

local PowerUpService: Loader.Service = {
	name = "PowerUpService",
	dependencies = {
		"NetGuard",
		"ConfigValidator",
		"RoundService",
		"ParticipantService",
		"LiveConfig",
		"StoreService",
	},

	setSpawnPoints = setSpawnPoints,
	debugLoadSpawnPointsFromMap = debugLoadSpawnPointsFromMap,
	setMapRarityWeights = setMapRarityWeights,
	setEffectApplier = setEffectApplier,
	setCooldownRateSource = setCooldownRateSource,
	setAuditSink = setAuditSink,
	getAuditLog = function(): { AuditEntry }
		return auditLog
	end,

	-- P3-6's entry point into the one validated use path - see useFor.
	useForRacer = useForRacer,

	-- P5-5: PracticeService runs the same pickup lifecycle in the hub.
	startPickups = startPickups,
	clearInventoryFor = clearInventoryFor,

	-- slot index -> power-up id, with holes where a slot is empty.
	getInventoryFor = function(racerId: number): { [number]: string }?
		local state = racerStates[racerId]
		if state == nil then
			return nil
		end
		local ids = {}
		for slotIndex, item in state.inventory do
			ids[slotIndex] = item.powerUpId
		end
		return ids
	end,

	-- Read-only, so NPCBrain can score "is this usable right now" without
	-- firing a use to find out (which would burn the item - see useFor).
	-- It asks the same PowerUpLogic.isOnCooldown against the same
	-- server-held timestamp the use path checks, so the brain can never
	-- believe something the validator would disagree with.
	isOnCooldownFor = function(racerId: number, powerUpId: string): boolean
		local state = racerStates[racerId]
		local def = powerUpDefsById[powerUpId]
		if state == nil or def == nil then
			return false
		end
		return PowerUpLogic.isOnCooldown(state.lastUsedAt[powerUpId], cooldownSecondsFor(racerId, def), now())
	end,

	-- Same shape as getInventoryFor.
	getInventory = function(player: Player): { [number]: string }?
		local state = racerStates[player.UserId]
		if state == nil then
			return nil
		end
		local ids = {}
		for slotIndex, item in state.inventory do
			ids[slotIndex] = item.powerUpId
		end
		return ids
	end,
}

function PowerUpService:init()
	local NetGuard = Loader.get("NetGuard") :: any

	NetGuard.on("PowerUpUseIntent", function(player: Player, payload: any)
		handleUseIntent(
			player,
			payload.slotIndex,
			payload.targetPlayerId,
			PowerUpLogic.aimForward(payload.aimX, payload.aimZ)
		)
	end)
	NetGuard.on("PowerUpDiscardIntent", function(player: Player, payload: any)
		handleDiscardIntent(player, payload.slotIndex)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		racerStates[player.UserId] = nil
	end)

	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Race", function()
		beginRace()
	end)
end

return PowerUpService
