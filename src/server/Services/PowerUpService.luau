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
	inventory: { InventoryItem },
	lastUsedAt: { [string]: number },
}

local spawnPoints: { SpawnPointRecord } = {}
local livePickups: { [SpawnPointRecord]: LivePickup } = {}
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

	-- P3-6: resolved through the participant roster rather than
	-- Players:GetPlayerFromCharacter, which can only ever answer for a
	-- human - an NPC walking over a pickup would otherwise step straight
	-- over it, and "NPCs pick up power-ups on their route"
	-- (architecture.md §4) would quietly never happen.
	local racer = Participants.fromCharacter(character)
	if racer == nil then
		return
	end
	-- P5-5: in practice, only someone inside the practice area.
	if not EffectContext.mayAct(racer.id) then
		return
	end

	live.claimed = true

	local state = racerStates[racer.id]
	if state == nil then
		state = { inventory = {}, lastUsedAt = {} }
		racerStates[racer.id] = state
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
	broadcastInventory(racer)

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
local function useFor(racer: Participants.Participant, slotIndex: number?, targetRacerId: number?)
	local resolvedSlotIndex = slotIndex or 1
	local state = racerStates[racer.id]

	-- P5-5: always true in a round. In practice this is what stops an
	-- item carried out of the practice area, or fired from the queue
	-- pad's no-effect zone.
	if not EffectContext.mayAct(racer.id) then
		audit(racer, nil, nil, "Rejected", "outside the practice area")
		sendResult(racer, false, nil, nil, "outside the practice area")
		return
	end

	if state == nil then
		audit(racer, nil, nil, "Rejected", "no inventory")
		sendResult(racer, false, nil, nil, "no inventory")
		return
	end

	local item = state.inventory[resolvedSlotIndex]
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

	if PowerUpLogic.isOnCooldown(state.lastUsedAt[def.id], def.cooldownSeconds, now()) then
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
		resolvedTarget = resolveTarget(racer, def, targetRacerId)
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
	table.remove(state.inventory, resolvedSlotIndex)
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
end

-- The client remote's entry point: authenticate the Player into a
-- participant, then hand over to the one path above.
local function handleUseIntent(player: Player, slotIndex: number?, targetPlayerId: number?)
	local racer = Participants.fromPlayer(player)
	if racer == nil then
		warn(string.format("PowerUpService: %s used a power-up while not on the roster", player.Name))
		return
	end
	useFor(racer, slotIndex, targetPlayerId)
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
		destroyLivePickup(point)
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

local function beginRace()
	EffectContext.assertRound("PowerUpService.beginRace")
	startPickups()
end

-- P5-5: empties one participant's held items, e.g. on leaving the
-- practice area, so nothing is carried out and used elsewhere.
local function clearInventoryFor(racerId: number)
	local state = racerStates[racerId]
	if state == nil or #state.inventory == 0 then
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
	dependencies = { "NetGuard", "ConfigValidator", "RoundService", "ParticipantService" },

	setSpawnPoints = setSpawnPoints,
	debugLoadSpawnPointsFromMap = debugLoadSpawnPointsFromMap,
	setMapRarityWeights = setMapRarityWeights,
	setEffectApplier = setEffectApplier,
	setAuditSink = setAuditSink,
	getAuditLog = function(): { AuditEntry }
		return auditLog
	end,

	-- P3-6's entry point into the one validated use path - see useFor.
	useForRacer = useForRacer,

	-- P5-5: PracticeService runs the same pickup lifecycle in the hub.
	startPickups = startPickups,
	clearInventoryFor = clearInventoryFor,

	getInventoryFor = function(racerId: number): { string }?
		local state = racerStates[racerId]
		if state == nil then
			return nil
		end
		local ids = {}
		for _, item in state.inventory do
			table.insert(ids, item.powerUpId)
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
		return PowerUpLogic.isOnCooldown(state.lastUsedAt[powerUpId], def.cooldownSeconds, now())
	end,

	getInventory = function(player: Player): { string }?
		local state = racerStates[player.UserId]
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
		racerStates[player.UserId] = nil
	end)

	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Race", function()
		beginRace()
	end)
end

return PowerUpService
