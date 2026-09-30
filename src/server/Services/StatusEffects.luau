--!strict
-- The status effect system (P2-8). Owns every temporary modification to
-- a character - speed, jump, control lock, vision, task speed - "a stat
-- is never written directly by anything but the resolver" (the task's
-- own requirement, verbatim): `recomputeAndApply` below is the ONLY
-- place `Humanoid.WalkSpeed`/`JumpPower` are ever set, and it always
-- derives them fresh from `StatusEffectResolver.resolve` over a
-- player's current active-effect list, never from anything incremental.
--
-- This is also the seam P2-7's PowerUpService deferred to -
-- `applyEffectFor` below is wired in as PowerUpService's own
-- `EffectApplier` at the bottom of this file's init(), which is what
-- turns "no effect resolver wired in yet" into a real effect for the
-- eight power-ups StatusEffectDefs.luau covers (see that file's own
-- header comment for the two task items it leaves out, and why).
--
-- The pure resolver, stacking rules, and the central hard-control
-- anti-frustration gate live in src/shared/StatusEffectResolver.luau;
-- this is the thin Roblox-touching wrapper that supplies real
-- characters/Humanoids/timers and applies what that module decides.
--
-- P3-5 re-keyed this from Player to PARTICIPANT ID (see Participants.
-- luau's own header for why). It is what makes "NPCs are affected by
-- player power-ups exactly like humans are" true by construction rather
-- than by a parallel bot-effect path: an NPC's rig has a Humanoid like
-- any other, so every line below applies to it unchanged. The only
-- thing a bot lacks is a client to replicate to, which is the single
-- `if participant.player ~= nil` in `replicate` - and no rule,
-- stacking decision or immunity window branches on it.
--
-- P5-5: the hub practice area runs this same service under
-- EffectContext's practice flag (shorter durations, a lower cap, a
-- zone gate). See EffectContext.luau for why it isn't a copy.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local PowerUpLogic = require(ReplicatedStorage.Shared.PowerUpLogic)
local RoundStates = require(ReplicatedStorage.Shared.RoundStates)
local StatusEffectResolver = require(ReplicatedStorage.Shared.StatusEffectResolver)
local StatusEffectDefs = require(ServerScriptService.Server.Services.StatusEffectDefs)
local Participants = require(ServerScriptService.Server.Participants)
local EffectContext = require(ServerScriptService.Server.EffectContext)

-- Roblox defaults - PLACEHOLDER, same stance every unverified number in
-- this repo takes (see GameConfig.luau): no locked baseline movement
-- values exist in docs/ yet, so this is what a stock Humanoid ships
-- with, not a tuned design decision.
local BASE_WALK_SPEED = 16
local BASE_JUMP_POWER = 50

type RacerState = {
	activeEffects: { StatusEffectResolver.ActiveEffect },
	hardControlHistory: StatusEffectResolver.HardControlHistory,
}

local racerStates: { [number]: RacerState } = {}
local instanceCounter = 0

-- The start gate: every racer stands still on their spawn from Loading
-- until Race begins, while the client counts down 3-2-1 over Intro's
-- last seconds. Not an effect - nothing can cleanse or shorten it.
local HELD_STATES: { [string]: boolean } = { Loading = true, Intro = true }
local startGateHeld = false

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function nextInstanceId(): string
	instanceCounter += 1
	return string.format("effect-%d", instanceCounter)
end

local function ensureState(racerId: number): RacerState
	local state = racerStates[racerId]
	if state == nil then
		state = {
			activeEffects = {},
			hardControlHistory = { lastEndedAt = nil, recentApplications = {}, totalDisabledSeconds = 0 },
		}
		racerStates[racerId] = state
	end
	return state
end

-- Filters `state.activeEffects` down to what's still active at `now`,
-- and records `lastEndedAt` for any HardControl-category effect that
-- JUST expired since the last time this ran - the only place that
-- timestamp is ever updated, so the immunity window (powerups.md rule 1)
-- always starts counting from a real expiry, not from whenever
-- something else happened to notice.
local function pruneExpired(racerId: number)
	local state = ensureState(racerId)
	local nowValue = now()
	local stillActive = StatusEffectResolver.activeAt(state.activeEffects, nowValue)

	if #stillActive < #state.activeEffects then
		local stillActiveIds: { [string]: boolean } = {}
		for _, effect in stillActive do
			stillActiveIds[effect.instanceId] = true
		end

		for _, effect in state.activeEffects do
			if not stillActiveIds[effect.instanceId] and effect.def.category == "HardControl" then
				state.hardControlHistory =
					StatusEffectResolver.recordHardControlEnded(state.hardControlHistory, effect.expiresAt)
			end
		end
	end

	state.activeEffects = stillActive
end

-- Reads the character off the participant registry rather than off a
-- Player, which is the whole of what makes an NPC affectable: a bot's
-- rig has a Humanoid exactly like a human's, and this function can no
-- longer tell the difference.
local function applyResolvedStats(racerId: number, stats: StatusEffectResolver.ResolvedStats)
	local participant = Participants.get(racerId)
	local character = if participant ~= nil then participant.character else nil
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		return
	end

	-- Bots idle until Race on their own, and keep a per-profile speed
	-- this function doesn't know, so the gate only holds humans.
	local locked = stats.ControlLock or (startGateHeld and participant ~= nil and participant.player ~= nil)
	humanoid.WalkSpeed = if locked then 0 else BASE_WALK_SPEED * stats.MoveSpeed
	humanoid.JumpPower = if locked then 0 else BASE_JUMP_POWER * stats.JumpPower
end

local function replicate(racerId: number, state: RacerState)
	local participant = Participants.get(racerId)

	-- The targeted half only exists for a human: an NPC has no client to
	-- send its own HUD detail to. This `if` is the ONLY place in the
	-- status effect system that distinguishes a bot from a player.
	local player = if participant ~= nil then participant.player else nil
	if player ~= nil then
		local ownPayload = {}
		for _, effect in state.activeEffects do
			table.insert(
				ownPayload,
				-- `kind` (P6-3): the HUD's screen-edge warning is for
				-- debuffs only, and a Movement category alone can't
				-- tell a Slow Field from your own Sprint Boost.
				{
					id = effect.def.id,
					category = effect.def.category,
					kind = effect.def.kind,
					expiresAt = effect.expiresAt,
				}
			)
		end
		Net.fireClient("StatusEffectsChanged", player, { effects = ownPayload })
	end

	-- The broadcast half fires for everyone, bots included - a frozen
	-- NPC has to LOOK frozen to the humans racing it, or a power-up
	-- spent on one reads as a power-up that did nothing.
	local seenCategories: { [string]: boolean } = {}
	local categories = {}
	-- Movement alone can't tell a Slow Field from a Sprint Boost, and
	-- EffectLabelController labels only the slow. Still no durations.
	local slowed = false
	for _, effect in state.activeEffects do
		if not seenCategories[effect.def.category] then
			seenCategories[effect.def.category] = true
			table.insert(categories, effect.def.category)
		end
		if effect.def.category == "Movement" and effect.def.kind == "Debuff" then
			slowed = true
		end
	end
	Net.fireAllClients("StatusEffectsVisual", { playerId = racerId, categories = categories, slowed = slowed })
end

-- The one place `recomputeAndApply` is ever skipped is a racer with no
-- Character (already handled inside applyResolvedStats as a no-op) -
-- resolve/replicate still run regardless, so the HUD/visual feed stays
-- correct even for a currently-dead-or-loading racer.
local function recomputeAndApply(racerId: number)
	local state = ensureState(racerId)
	local stats = StatusEffectResolver.resolve(state.activeEffects)
	applyResolvedStats(racerId, stats)
	replicate(racerId, state)
end

-- "Effects are cleared correctly on death, respawn, round end, and state
-- transitions, with no orphaned modifiers" (the task's own requirement,
-- verbatim) - the one function that does that clearing, called from
-- every one of those triggers below.
local function clearAllEffects(racerId: number)
	local state = ensureState(racerId)
	state.activeEffects = {}
	recomputeAndApply(racerId)
end

local function clearEveryRacer()
	for racerId in racerStates do
		clearAllEffects(racerId)
	end
end

-- Expiry is otherwise lazy (pruneExpired only runs when something asks),
-- so without this a Freeze's WalkSpeed = 0 outlives the effect until the
-- next death, respawn or state change. A stale timer (the effect was
-- refreshed, cleansed or cleared) is harmless: prune + recompute is
-- idempotent. The pad covers task.delay vs GetServerTimeNow drift.
local EXPIRY_PAD_SECONDS = 0.05

local function scheduleExpiry(racerId: number, durationSeconds: number)
	task.delay(durationSeconds + EXPIRY_PAD_SECONDS, function()
		-- Left mid-effect: don't resurrect state PlayerRemoving dropped.
		if racerStates[racerId] == nil then
			return
		end
		pruneExpired(racerId)
		recomputeAndApply(racerId)
	end)
end

-- ===== applying an effect ===================================================

-- `targeted`: the debuff was cast AT this racer (Freeze, Blind...) rather
-- than met in a zone - only targeted debuffs are stopped by Phase Step.
local function applyEffect(
	targetId: number,
	def: StatusEffectResolver.EffectDef,
	casterId: number?,
	targeted: boolean
): (boolean, string, string?)
	-- P5-5: the last line of defence for hub practice. PowerUpService
	-- already filters targets, but a zone slows whoever walks into it,
	-- and nothing may land on anyone the practice gate refuses. Always
	-- true in a round.
	if not EffectContext.mayAct(targetId) then
		return false, "target is not practising"
	end

	pruneExpired(targetId)
	local state = ensureState(targetId)

	-- Before the hard-control gate, like the practice cap below: a warded
	-- hit never happened, so it mustn't count toward diminishing returns.
	if def.kind == "Debuff" then
		local blockReason =
			StatusEffectResolver.debuffBlockReason(StatusEffectResolver.resolve(state.activeEffects), targeted)
		if blockReason ~= nil then
			return false, blockReason
		end
	end

	-- P5-5: the practice cap is checked before the hard-control gate,
	-- which records every application it sees - a capped-out attempt
	-- must not eat into the victim's diminishing-returns history.
	local refreshes = false
	for _, effect in state.activeEffects do
		if effect.def.id == def.id then
			refreshes = true
			break
		end
	end
	if not EffectContext.admits(#state.activeEffects, refreshes) then
		return false, "practice effect cap reached"
	end

	local effectiveDef = def
	-- Unchanged in a round. Shortened in practice, BEFORE the hard-control
	-- rules see it, so their disable-time bookkeeping matches what lands.
	local effectiveDuration = EffectContext.effectDuration(def.durationSeconds)

	if def.category == "HardControl" then
		local decision =
			StatusEffectResolver.decideHardControlApplication(state.hardControlHistory, now(), effectiveDuration)
		state.hardControlHistory = decision.updatedHistory

		if not decision.allowed then
			return false, "blocked by post-hard-control immunity window"
		end

		if decision.downgradedToSoft then
			local fallbackId = def.hardControlSoftFallbackId
			local fallbackDef = if fallbackId ~= nil then StatusEffectDefs[fallbackId] else nil
			if fallbackDef == nil then
				-- Shouldn't happen for any real HardControl def in
				-- StatusEffectDefs.luau (they all declare a fallback) -
				-- defensive only.
				return false, "rolling hard-control cap reached and no soft fallback is defined for this effect"
			end
			effectiveDef = fallbackDef
			effectiveDuration = EffectContext.effectDuration(fallbackDef.durationSeconds)
		else
			effectiveDuration = decision.effectiveDurationSeconds
		end
	end

	local newEffect: StatusEffectResolver.ActiveEffect = {
		instanceId = nextInstanceId(),
		def = effectiveDef,
		appliedAt = now(),
		expiresAt = now() + effectiveDuration,
		casterId = casterId,
	}

	state.activeEffects = StatusEffectResolver.applyStacking(state.activeEffects, newEffect)
	recomputeAndApply(targetId)
	scheduleExpiry(targetId, effectiveDuration)

	-- The third return is for the zone loop, which keeps hold of the
	-- instance it placed so it can stretch or cut it rather than stack
	-- a new one every tick.
	return true,
		if effectiveDef.id ~= def.id
			then string.format("applied as %s (downgraded from %s)", effectiveDef.id, def.id)
			else "applied",
		newEffect.instanceId
end

-- ===== area zones (Slow Field) =============================================
--
-- An Area item drops a zone at the caster's feet: a flat disc of
-- def.areaRadiusStuds that lasts the item's duration and slows everyone
-- standing in it but the caster. A loop checks who's inside every
-- ZONE_TICK. Each zone places ONE effect instance per victim, which runs
-- to the zone's end while they stay in and is cut to ZONE_EXIT_LINGER
-- when they step out, so standing in a zone never stacks it on itself -
-- only a second zone does (powerups.md rule 4's floor bounds that).
-- Replication happens on entry and exit only, not every tick.

local ZONE_TICK = 0.2
local ZONE_EXIT_LINGER = 0.3
local ZONE_COLOR = Color3.fromRGB(235, 70, 70)
local ZONE_THICKNESS = 0.3

type Zone = {
	casterId: number,
	def: StatusEffectResolver.EffectDef,
	floor: Vector3,
	radius: number,
	endsAt: number,
	part: BasePart,
	-- racer id -> the effect instance this zone placed on them.
	placed: { [number]: string },
}

local zones: { Zone } = {}
local zoneLoopRunning = false
local zoneFolder: Folder? = nil

local function rootOf(participant: Participants.Participant): BasePart?
	local character = participant.character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local function toVec3(v: Vector3): PowerUpLogic.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function findActive(racerId: number, instanceId: string): StatusEffectResolver.ActiveEffect?
	for _, effect in ensureState(racerId).activeEffects do
		if effect.instanceId == instanceId then
			return effect
		end
	end
	return nil
end

-- Moves one placed instance's end, then re-resolves (the HUD countdown
-- changes even when the stats don't).
local function setExpiry(racerId: number, effect: StatusEffectResolver.ActiveEffect, expiresAt: number)
	effect.expiresAt = expiresAt
	recomputeAndApply(racerId)
	scheduleExpiry(racerId, math.max(0, expiresAt - now()))
end

local function tickZone(zone: Zone, t: number)
	local floor = toVec3(zone.floor)
	for _, racer in Participants.all() do
		if racer.id == zone.casterId then
			continue -- the caster is immune to their own zone
		end
		local root = rootOf(racer)
		local inside = root ~= nil and PowerUpLogic.isInsideZone(floor, zone.radius, toVec3(root.Position))

		pruneExpired(racer.id)
		local instanceId = zone.placed[racer.id]
		local effect = if instanceId ~= nil then findActive(racer.id, instanceId) else nil

		if inside then
			if effect ~= nil then
				-- Back in before the exit linger ran out.
				if effect.expiresAt < zone.endsAt then
					setExpiry(racer.id, effect, zone.endsAt)
				end
			else
				local timed = table.clone(zone.def)
				timed.durationSeconds = zone.endsAt - t
				-- Refused (Second Wind's window, the practice gate) is
				-- simply retried next tick.
				local applied, _, placedId = applyEffect(racer.id, timed, zone.casterId, false)
				if applied and placedId ~= nil then
					zone.placed[racer.id] = placedId
				end
			end
		elseif effect ~= nil and effect.expiresAt > t + ZONE_EXIT_LINGER then
			setExpiry(racer.id, effect, t + ZONE_EXIT_LINGER)
		end
	end
end

local function runZones()
	if zoneLoopRunning then
		return
	end
	zoneLoopRunning = true
	task.spawn(function()
		while #zones > 0 do
			local t = now()
			for index = #zones, 1, -1 do
				local zone = zones[index]
				if t >= zone.endsAt then
					zone.part:Destroy()
					table.remove(zones, index)
				else
					tickZone(zone, t)
				end
			end
			task.wait(ZONE_TICK)
		end
		zoneLoopRunning = false
	end)
end

local function clearZones()
	for _, zone in zones do
		zone.part:Destroy()
	end
	table.clear(zones)
end

local function zonePart(floor: Vector3, radius: number): BasePart
	local folder = zoneFolder
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = "PowerUpZones"
		created.Parent = Workspace
		zoneFolder = created
		folder = created
	end
	-- A cylinder's axis is its X, so it's rolled onto its side to lie flat.
	local part = Instance.new("Part")
	part.Name = "SlowFieldZone"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(ZONE_THICKNESS, radius * 2, radius * 2)
	part.CFrame = CFrame.new(floor + Vector3.new(0, ZONE_THICKNESS / 2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = ZONE_COLOR
	part.Transparency = 0.2
	part.Parent = folder
	return part
end

local function dropZone(caster: Participants.Participant, powerUpDef: Validate.PowerUpDef): (boolean, string)
	local effectDef = StatusEffectDefs[powerUpDef.id]
	local radius = powerUpDef.areaRadiusStuds
	local root = rootOf(caster)
	if effectDef == nil or radius == nil then
		return false, string.format("%s has no zone effect defined", powerUpDef.id)
	end
	if root == nil then
		return false, "caster has no character to drop a zone at"
	end
	local humanoid = if root.Parent ~= nil then root.Parent:FindFirstChildOfClass("Humanoid") else nil
	local floor = root.Position
		- Vector3.new(0, root.Size.Y / 2 + (if humanoid ~= nil then humanoid.HipHeight else 2), 0)
	table.insert(zones, {
		casterId = caster.id,
		def = effectDef,
		floor = floor,
		radius = radius,
		endsAt = now() + EffectContext.effectDuration(powerUpDef.durationSeconds),
		part = zonePart(floor, radius),
		placed = {},
	})
	runZones()
	return true, "zone dropped"
end

-- Second Wind's cleanse isn't a stat modifier (see StatusEffectDefs.
-- luau's own header comment) - it strips every currently-active DEBUFF
-- from the caster's own list, then leaves its immunity-window ward.
-- Always targets the caster - it's a Self buff, never aimed at anyone.
local function applySecondWind(casterId: number): (boolean, string)
	pruneExpired(casterId)
	local state = ensureState(casterId)

	local cleansedCount = 0
	local kept: { StatusEffectResolver.ActiveEffect } = {}
	for _, effect in state.activeEffects do
		if effect.def.kind == "Debuff" then
			cleansedCount += 1
		else
			table.insert(kept, effect)
		end
	end

	state.activeEffects = kept
	-- applyEffect recomputes and replicates; the ward is a Buff, so the
	-- debuff gate it's about to arm can't refuse it.
	local _ = applyEffect(casterId, StatusEffectDefs["second-wind"], casterId, false)

	return true, string.format("cleansed %d active debuff(s)", cleansedCount)
end

-- The seam P2-7's PowerUpService calls into - matches PowerUpService.
-- EffectApplier's own declared signature exactly. The two task items
-- aren't character stats: TaskHandlerService owns the task session they
-- change, so they're handed over to it (after the same debuff gate a
-- targeted stat effect meets, for Scramble).
local function applyEffectFor(
	caster: Participants.Participant,
	target: Participants.Participant?,
	powerUpDef: Validate.PowerUpDef
): (boolean, string)
	if powerUpDef.id == "second-wind" then
		return applySecondWind(caster.id)
	end

	local TaskHandlerService = Loader.get("TaskHandlerService") :: any
	if powerUpDef.id == "task-insight" then
		if caster.player == nil then
			return false, "a bot has no task view to make easy"
		end
		return TaskHandlerService.grantInsight(caster.player, powerUpDef.durationSeconds)
	elseif powerUpDef.id == "task-scramble" then
		if target == nil or target.player == nil then
			return false, "target has no task view to scramble"
		end
		if not EffectContext.mayAct(target.id) then
			return false, "target is not practising"
		end
		pruneExpired(target.id)
		local blockReason = StatusEffectResolver.debuffBlockReason(
			StatusEffectResolver.resolve(ensureState(target.id).activeEffects),
			true
		)
		if blockReason ~= nil then
			return false, blockReason
		end
		return TaskHandlerService.scramble(target.player)
	end

	if powerUpDef.target == "Area" then
		return dropZone(caster, powerUpDef)
	end

	local effectDef = StatusEffectDefs[powerUpDef.id]
	if effectDef == nil then
		return true,
			string.format(
				"%s has no character-stat effect wired in yet - see StatusEffectDefs.luau's own scope note",
				powerUpDef.id
			)
	end

	local actualTarget = if target ~= nil then target else caster
	local applied, description = applyEffect(actualTarget.id, effectDef, caster.id, true)
	return applied, description
end

-- ===== service =============================================================

local StatusEffects: Loader.Service = {
	name = "StatusEffects",
	dependencies = {
		"NetGuard",
		"ConfigValidator",
		"RoundService",
		"PowerUpService",
		"ParticipantService",
		"TaskHandlerService",
	},

	-- Exposed so a consumer (P2-9's MovementWatch, comparing observed
	-- movement against "the maximum the status effect resolver says they
	-- should be capable of") can derive a real studs/second figure from
	-- getResolvedStats().MoveSpeed without duplicating this number as a
	-- second, potentially-drifting constant of its own.
	baseWalkSpeed = BASE_WALK_SPEED,
	baseJumpPower = BASE_JUMP_POWER,

	applyEffectFor = applyEffectFor,

	-- P3-5: NPCService calls this when a bot's rig is despawned or
	-- replaced, the same way a human's respawn clears theirs below.
	clearFor = clearAllEffects,

	getActiveEffectsFor = function(racerId: number): { StatusEffectResolver.ActiveEffect }
		pruneExpired(racerId)
		return ensureState(racerId).activeEffects
	end,

	getResolvedStatsFor = function(racerId: number): StatusEffectResolver.ResolvedStats
		pruneExpired(racerId)
		return StatusEffectResolver.resolve(ensureState(racerId).activeEffects)
	end,

	-- Player-shaped wrappers, kept so P2-9's MovementWatch (and any
	-- other human-side caller) is unchanged by the re-key.
	getActiveEffects = function(player: Player): { StatusEffectResolver.ActiveEffect }
		pruneExpired(player.UserId)
		return ensureState(player.UserId).activeEffects
	end,

	getResolvedStats = function(player: Player): StatusEffectResolver.ResolvedStats
		pruneExpired(player.UserId)
		return StatusEffectResolver.resolve(ensureState(player.UserId).activeEffects)
	end,
}

function StatusEffects:init()
	-- "cleared correctly on... round end, and state transitions" - every
	-- state's own onExit, not just Race's, so nothing survives into a
	-- phase it was never meant to touch (a Freeze landing right as Race
	-- ends shouldn't carry into Qualified).
	local RoundService = Loader.get("RoundService") :: any
	for _, state in RoundStates.ALL do
		RoundService.onExit(state, function()
			clearZones()
			clearEveryRacer()
		end)
		RoundService.onEnter(state, function()
			local held = HELD_STATES[state] == true
			if held ~= startGateHeld then
				startGateHeld = held
				for _, participant in Participants.humans() do
					recomputeAndApply(participant.id)
				end
			end
		end)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			-- Respawn: a fresh character starts clean, never inheriting a
			-- stale modifier meant for the character that just died.
			clearAllEffects(player.UserId)

			local humanoid = character:WaitForChild("Humanoid")
			if humanoid:IsA("Humanoid") then
				humanoid.Died:Connect(function()
					clearAllEffects(player.UserId)
				end)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		racerStates[player.UserId] = nil
	end)

	local PowerUpService = Loader.get("PowerUpService") :: any
	PowerUpService.setEffectApplier(applyEffectFor)
	-- Overclock: PowerUpService owns cooldowns but can't depend on this
	-- service (this one depends on it), so the rate comes in as a seam.
	PowerUpService.setCooldownRateSource(function(racerId: number): number
		pruneExpired(racerId)
		return StatusEffectResolver.resolve(ensureState(racerId).activeEffects).CooldownRate
	end)
end

return StatusEffects
