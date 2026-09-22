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
--    is looked up as `playerStates[player]` - keyed by that same real
--    Player, never by a client-supplied id. There is no field in
--    PowerUpUseIntent's schema a payload could use to claim a different
--    identity at all.
--
-- 4. RANGE SPOOFING. PowerUpUseIntent's payload carries an OPTIONAL
--    target *hint* (`targetPlayerId`) and nothing else - no position, no
--    distance, no "I'm in range" claim. Range/cone are computed entirely
--    server-side in `resolveTarget`, from `Character.HumanoidRootPart.
--    Position` on both the caster and the candidate target - real
--    Instance state the client has no way to misreport through this
--    remote.
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
--    the caster's OWN server-held inventory array; an out-of-range or
--    empty index is rejected before anything else runs, and there is no
--    way to reference another player's inventory through this payload
--    at all (see #3).

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local PowerUpLogic = require(ReplicatedStorage.Shared.PowerUpLogic)
local Participants = require(ServerScriptService.Server.Participants)

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

type PlayerState = {
	inventory: { InventoryItem },
	lastUsedAt: { [string]: number },
}

local spawnPoints: { SpawnPointRecord } = {}
local livePickups: { [SpawnPointRecord]: LivePickup } = {}
local pendingRespawnThreads: { [SpawnPointRecord]: thread } = {}
local playerStates: { [Player]: PlayerState } = {}
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

local function audit(
	player: Player,
	powerUpId: string?,
	targetPlayerId: number?,
	result: "Applied" | "Rejected",
	reason: string?
)
	local entry: AuditEntry = {
		at = Workspace:GetServerTimeNow(),
		playerId = player.UserId,
		playerName = player.Name,
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

local RARITY_COLOR: { [string]: Color3 } = {
	Common = Color3.fromRGB(180, 180, 180),
	Uncommon = Color3.fromRGB(80, 170, 90),
	Rare = Color3.fromRGB(90, 120, 220),
}

local function eligiblePool(point: SpawnPointRecord): { Validate.PowerUpDef }
	local pool: { Validate.PowerUpDef } = {}
	for _, def in powerUpDefsById do
		if def.rarity ~= point.rarity then
			continue
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

local function destroyLivePickup(point: SpawnPointRecord)
	local live = livePickups[point]
	if live ~= nil then
		live.part:Destroy()
		livePickups[point] = nil
	end
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

local function broadcastInventory(player: Player)
	local state = playerStates[player]
	local items = {}
	if state ~= nil then
		for _, item in state.inventory do
			table.insert(items, { powerUpId = item.powerUpId })
		end
	end
	Net.fireClient("PowerUpInventoryChanged", player, { inventory = items })
end

-- "Pickup is server-confirmed" (the task's own requirement) - detected
-- via Touched, never a client remote. `live.claimed = true` is set
-- synchronously as the first line below, before anything that could
-- yield - see this file's header comment, exploit #5, for why that
-- ordering is what makes a near-simultaneous double-claim impossible.
local function tryClaimPickup(point: SpawnPointRecord, live: LivePickup, hitPart: BasePart)
	if live.claimed then
		return
	end

	local character = hitPart.Parent
	if character == nil or not character:IsA("Model") then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if player == nil then
		return
	end

	live.claimed = true

	local state = playerStates[player]
	if state == nil then
		state = { inventory = {}, lastUsedAt = {} }
		playerStates[player] = state
	end

	local allowed, shouldSwap = PowerUpLogic.canPickUp(
		#state.inventory,
		GameConfig.powerUpInventorySlots,
		GameConfig.powerUpFullInventoryPolicy
	)

	if not allowed then
		live.claimed = false -- refused - the world pickup stays available for someone else
		return
	end

	if shouldSwap and #state.inventory > 0 then
		table.remove(state.inventory, 1) -- oldest held item evicted
	end

	table.insert(state.inventory, { powerUpId = live.def.id, acquiredAt = now() })
	broadcastInventory(player)

	destroyLivePickup(point)
	scheduleRespawn(point)
end

spawnAt = function(point: SpawnPointRecord)
	destroyLivePickup(point) -- defensive idempotency guard; shouldn't normally find one live

	local pool = eligiblePool(point)
	if #pool == 0 then
		warn(string.format("PowerUpService: no eligible power-up defs for a %s spawn point - skipped", point.rarity))
		return
	end

	local def = PowerUpLogic.selectUniform(pool, math.random())

	local part = Instance.new("Part")
	part.Name = string.format("PowerUpPickup_%s", def.id)
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(2.5, 2.5, 2.5)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = true
	part.CanQuery = true
	part.Material = Enum.Material.Neon
	part.Color = RARITY_COLOR[point.rarity] or Color3.fromRGB(255, 255, 255)
	part.CFrame = point.part.CFrame + Vector3.new(0, 2, 0)
	part.Parent = pickupsFolder

	local live: LivePickup = { part = part, def = def, claimed = false }
	livePickups[point] = live

	part.Touched:Connect(function(hit: BasePart)
		tryClaimPickup(point, live, hit)
	end)
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
local function resolveTarget(
	caster: Participants.Participant,
	def: Validate.PowerUpDef,
	explicitTargetId: number?
): Participants.Participant?
	local casterRoot = characterRoot(caster.character)
	if casterRoot == nil then
		return nil
	end
	local casterPosition = toVec3(casterRoot.Position)
	local casterForward = toVec3(casterRoot.CFrame.LookVector)

	if def.target == "Aimed" and explicitTargetId ~= nil then
		local explicitTarget = Participants.get(explicitTargetId)
		if explicitTarget == nil or explicitTarget.id == caster.id then
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
			GameConfig.powerUpUseRangeStuds,
			GameConfig.powerUpTargetConeDegrees
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
		if other.id == caster.id then
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

local function sendResult(
	player: Player,
	success: boolean,
	powerUpId: string?,
	targetPlayerId: number?,
	reason: string?
)
	Net.fireClient("PowerUpUseResult", player, {
		success = success,
		powerUpId = powerUpId,
		targetPlayerId = targetPlayerId,
		reason = reason,
	})
end

local function handleUseIntent(player: Player, slotIndex: number?, targetPlayerId: number?)
	local resolvedSlotIndex = slotIndex or 1
	local state = playerStates[player]

	if state == nil then
		audit(player, nil, nil, "Rejected", "no inventory")
		sendResult(player, false, nil, nil, "no inventory")
		return
	end

	local item = state.inventory[resolvedSlotIndex]
	if item == nil then
		audit(player, nil, nil, "Rejected", "empty slot")
		sendResult(player, false, nil, nil, "empty slot")
		return
	end

	local def = powerUpDefsById[item.powerUpId]
	if def == nil then
		-- Defensive only - can't happen for an id this service itself put
		-- in the inventory, since it's always drawn from powerUpDefsById.
		audit(player, item.powerUpId, nil, "Rejected", "unknown power-up id")
		sendResult(player, false, item.powerUpId, nil, "unknown power-up id")
		return
	end

	if PowerUpLogic.isOnCooldown(state.lastUsedAt[def.id], def.cooldownSeconds, now()) then
		audit(player, def.id, nil, "Rejected", "on cooldown")
		sendResult(player, false, def.id, nil, "on cooldown")
		return
	end

	-- The caster is always a human here (this is a client remote's own
	-- handler), but it still crosses over to a participant before
	-- reaching the targeting and effect code, so those never see a
	-- Player at all. P3-6's NPC power-up use enters at that same seam.
	local casterParticipant = Participants.fromPlayer(player)
	if casterParticipant == nil then
		audit(player, def.id, nil, "Rejected", "caster is not on the participant roster")
		sendResult(player, false, def.id, nil, "not in this round")
		return
	end

	local resolvedTarget: Participants.Participant? = nil
	if def.target == "Self" then
		resolvedTarget = casterParticipant
	elseif def.target == "Area" then
		resolvedTarget = nil -- a zone at the caster's own position, not a racer target
	else
		resolvedTarget = resolveTarget(casterParticipant, def, targetPlayerId)
		if resolvedTarget == nil then
			audit(player, def.id, nil, "Rejected", "no valid target")
			sendResult(player, false, def.id, nil, "no valid target")
			return
		end
	end

	local resolvedTargetId = if resolvedTarget ~= nil then resolvedTarget.id else nil
	local applied, description = effectApplier(casterParticipant, resolvedTarget, def)

	if not applied then
		audit(player, def.id, resolvedTargetId, "Rejected", description)
		sendResult(player, false, def.id, resolvedTargetId, description)
		return
	end

	state.lastUsedAt[def.id] = now()
	audit(player, def.id, resolvedTargetId, "Applied", description)
	sendResult(player, true, def.id, resolvedTargetId, description)
end

-- ===== round lifecycle ======================================================

local function beginRace()
	-- Idempotent reset - a real server only ever runs one round
	-- (architecture.md), but Studio's debug interface can replay Race
	-- repeatedly on the same server (see TaskHandlerService.luau's
	-- identical concern), which would otherwise leave orphaned pickups
	-- and dangling respawn timers from a previous test race.
	for point in pendingRespawnThreads do
		cancelPendingRespawn(point)
	end
	for point in livePickups do
		destroyLivePickup(point)
	end
	playerStates = {}

	if pickupsFolder == nil then
		local folder = Instance.new("Folder")
		folder.Name = "PowerUpPickups"
		folder.Parent = Workspace
		pickupsFolder = folder
	end

	if #spawnPoints == 0 then
		warn("PowerUpService: no spawn points set (no map loaded) - skipping power-up spawns for this race")
		return
	end

	for _, point in spawnPoints do
		spawnAt(point)
	end
end

local PowerUpService: Loader.Service = {
	name = "PowerUpService",
	dependencies = { "NetGuard", "ConfigValidator", "RoundService", "ParticipantService" },

	setSpawnPoints = setSpawnPoints,
	debugLoadSpawnPointsFromMap = debugLoadSpawnPointsFromMap,
	setMapRarityWeights = setMapRarityWeights,
	setEffectApplier = setEffectApplier,
	setAuditSink = setAuditSink,
	getAuditLog = function(): { AuditEntry }
		return auditLog
	end,

	getInventory = function(player: Player): { string }?
		local state = playerStates[player]
		if state == nil then
			return nil
		end
		local ids = {}
		for _, item in state.inventory do
			table.insert(ids, item.powerUpId)
		end
		return ids
	end,
}

function PowerUpService:init()
	local NetGuard = Loader.get("NetGuard") :: any

	NetGuard.on("PowerUpUseIntent", function(player: Player, payload: any)
		handleUseIntent(player, payload.slotIndex, payload.targetPlayerId)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		playerStates[player] = nil
	end)

	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Race", function()
		beginRace()
	end)
end

return PowerUpService
