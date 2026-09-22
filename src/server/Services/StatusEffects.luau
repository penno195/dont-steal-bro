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
-- six power-ups StatusEffectDefs.luau covers (see that file's own header
-- comment for which four still aren't character-stat effects, and why).
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

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local RoundStates = require(ReplicatedStorage.Shared.RoundStates)
local StatusEffectResolver = require(ReplicatedStorage.Shared.StatusEffectResolver)
local StatusEffectDefs = require(ServerScriptService.Server.Services.StatusEffectDefs)
local Participants = require(ServerScriptService.Server.Participants)

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

	humanoid.WalkSpeed = if stats.ControlLock then 0 else BASE_WALK_SPEED * stats.MoveSpeed
	humanoid.JumpPower = if stats.ControlLock then 0 else BASE_JUMP_POWER * stats.JumpPower
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
				{ id = effect.def.id, category = effect.def.category, expiresAt = effect.expiresAt }
			)
		end
		Net.fireClient("StatusEffectsChanged", player, { effects = ownPayload })
	end

	-- The broadcast half fires for everyone, bots included - a frozen
	-- NPC has to LOOK frozen to the humans racing it, or a power-up
	-- spent on one reads as a power-up that did nothing.
	local seenCategories: { [string]: boolean } = {}
	local categories = {}
	for _, effect in state.activeEffects do
		if not seenCategories[effect.def.category] then
			seenCategories[effect.def.category] = true
			table.insert(categories, effect.def.category)
		end
	end
	Net.fireAllClients("StatusEffectsVisual", { playerId = racerId, categories = categories })
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

-- ===== applying an effect ===================================================

local function applyEffect(targetId: number, def: StatusEffectResolver.EffectDef, casterId: number?): (boolean, string)
	pruneExpired(targetId)
	local state = ensureState(targetId)

	local effectiveDef = def
	local effectiveDuration = def.durationSeconds

	if def.category == "HardControl" then
		local decision =
			StatusEffectResolver.decideHardControlApplication(state.hardControlHistory, now(), def.durationSeconds)
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
			effectiveDuration = fallbackDef.durationSeconds
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

	return true,
		if effectiveDef.id ~= def.id
			then string.format("applied as %s (downgraded from %s)", effectiveDef.id, def.id)
			else "applied"
end

-- Second Wind isn't a stat modifier (see StatusEffectDefs.luau's own
-- header comment) - it strips every currently-active DEBUFF from the
-- caster's own list and recomputes. Always targets the caster - it's a
-- Self buff, never something aimed at anyone else.
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
	recomputeAndApply(casterId)

	return true, string.format("cleansed %d active debuff(s)", cleansedCount)
end

-- The seam P2-7's PowerUpService calls into - matches PowerUpService.
-- EffectApplier's own declared signature exactly. A power-up id with no
-- entry in StatusEffectDefs.luau (task-insight, phase-step, overclock,
-- task-scramble) still succeeds - consuming the cooldown and logging a
-- clear reason - rather than silently rejecting a use that looks correct
-- from the player's side.
local function applyEffectFor(
	caster: Participants.Participant,
	target: Participants.Participant?,
	powerUpDef: Validate.PowerUpDef
): (boolean, string)
	if powerUpDef.id == "second-wind" then
		return applySecondWind(caster.id)
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
	return applyEffect(actualTarget.id, effectDef, caster.id)
end

-- ===== service =============================================================

local StatusEffects: Loader.Service = {
	name = "StatusEffects",
	dependencies = { "NetGuard", "ConfigValidator", "RoundService", "PowerUpService", "ParticipantService" },

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
			clearEveryRacer()
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
end

return StatusEffects
