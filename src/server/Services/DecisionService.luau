--!strict
-- Decision Studio phase machine and secrecy (P3-2). Owns the inner
-- phase sequence (Intro -> Negotiate -> Choose -> Reveal -> Resolve)
-- that runs INSIDE RoundService's own "DecisionStudio" round state -
-- RoundService's own header comment already says as much ("DecisionStudio
-- ends when a future DecisionService's own inner phase machine
-- resolves"). This file is that inner machine.
--
-- ===== SECRECY AUDIT: WHAT A FULL CLIENT MEMORY DUMP CAN AND CANNOT SEE =====
--
-- The absolute requirement: no client may learn another player's choice
-- before the reveal. Here is exactly what does and doesn't cross the
-- client/server boundary at each phase, audited against an exploiter who
-- has FULL read access to their own client's memory (every LocalScript
-- variable, every replicated Instance, every RemoteEvent payload ever
-- received) - the realistic maximum an exploit could ever see, short of
-- literally reading the SERVER's own memory, which Roblox's client/
-- server model makes structurally impossible regardless of exploit
-- sophistication. `choices`/`locked` below are plain Lua tables local to
-- THIS ModuleScript, running on the server - there is no Instance, no
-- Attribute, no ValueObject, no NumberValue anywhere in this file that
-- ever carries a choice. A client cannot dump what was never sent to it.
--
--   Intro / Negotiate: the client has received DecisionParticipants (the
--   3 qualifier ids) and DecisionPhaseChanged (phase name + deadline).
--   No choice exists server-side yet at all (`choices` is empty) - there
--   is nothing to leak because nothing has been decided.
--
--   Choose: a client can fire DecisionChooseIntent (their OWN choice,
--   which they trivially already know - not a leak). The only thing the
--   SERVER ever sends back during this phase is DecisionLockedIn -
--   {playerId} ONLY, never {playerId, choice}. A memory dump of a
--   client's own received-remote history shows, at most, "these
--   playerIds have locked in" - not what any of them, including other
--   players, actually chose. This is the one place a careless
--   implementation could leak: broadcasting a `choice` field "just for
--   debugging" on this event would defeat the whole requirement. It
--   doesn't happen anywhere in this file.
--
--   Reveal: DecisionReveal fires with every choice and the computed
--   outcome. This is the FIRST and ONLY point any choice data ever
--   reaches a client, and it's deliberate - the reveal IS the point of
--   the mechanic. Everything before this phase is the boundary that
--   actually matters.
--
--   Resolve: nothing new is broadcast; RoundService transitions onward.
--
-- KNOWN GAP, NOTED HONESTLY: if a qualifier is ALREADY disconnected by
-- the time beginDecisionStudio runs (they left between the race ending
-- and the Studio starting), this file does not promote the 4th-place
-- alternate to fill their seat - that's P3-7's job ("Alternates,
-- disconnects and forfeits"). Their seat simply defaults to Share at
-- resolution, same as anyone who never locks in.
--
-- ===== RESOLUTION ORDER (exact, per the task's own numbered list) ========
-- 1. Deadline hits or all three have locked - resolveAndReveal below is
--    the one function both paths call.
-- 2. Anyone who never submitted takes GameConfig.decisionStudioDefaultChoice
--    (design-decisions.md Q4: locked to "Share").
-- 3. Outcomes.resolve (P3-1) - the pure outcome module, never re-derived here.
-- 4. Profile writes happen in computeOutcomeAndWriteProfiles, called
--    BEFORE enterReveal ever broadcasts anything - quitting during the
--    reveal animation cannot dodge a loss, because the loss (or win) is
--    already committed to ProfileStore before the client even learns
--    what happened.
-- 5. enterReveal broadcasts DecisionReveal with a shared `revealAt`
--    timestamp, the same absolute-deadline pattern RoundService/Clock.
--    luau already use, so all three clients animate from the same
--    instant regardless of each one's own replication latency.
-- 6. enterResolve requests RoundService's own transition to "Results".

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Outcomes = require(ReplicatedStorage.Shared.Config.Outcomes)
local ProfileLogic = require(ServerScriptService.Server.ProfileLogic)
local Signal = require(ReplicatedStorage.Packages.Signal)

export type Phase = "Intro" | "Negotiate" | "Choose" | "Reveal" | "Resolve"
export type OutcomeBranch = "SoleSteal" | "LoneShare" | "AllShare" | "AllSteal"

-- PLACEHOLDER: no real developer UserIds configured yet - same stance
-- RoundService.luau's own identical placeholder takes.
local DEBUG_USER_IDS: { number } = {}

-- Lets another service (P3-3's StudioChat, P3-4+) react to a phase
-- starting/ending without polling getPhase() - same Signal-per-state
-- pattern RoundService.luau already established, and created eagerly at
-- module load for the identical reason: a subscriber's own init() has
-- to be free to subscribe regardless of Loader's topological order.
-- `any`, not a generic Signal<T...> type - the same luau-lsp gap
-- RoundService.luau's own header comment documents for this exact
-- package.
local enterSignals: { [Phase]: any } = {
	Intro = Signal.new(),
	Negotiate = Signal.new(),
	Choose = Signal.new(),
	Reveal = Signal.new(),
	Resolve = Signal.new(),
}
local exitSignals: { [Phase]: any } = {
	Intro = Signal.new(),
	Negotiate = Signal.new(),
	Choose = Signal.new(),
	Reveal = Signal.new(),
	Resolve = Signal.new(),
}

-- Small lead time between broadcasting DecisionReveal and the instant
-- `revealAt` names, so a client's own (possibly LONGER) reveal
-- animation has already received the event before it's supposed to
-- start - comfortably inside GameConfig.studioTimers.revealDelaySeconds'
-- own 1s window, which is a server-side buffer before transitioning
-- onward, not a cap on how long a client's own animation is allowed to
-- run.
local REVEAL_ANIMATION_LEAD_SECONDS = 0.2

local currentPhase: Phase? = nil
local qualifierIds: { number } = {}

-- THE secrecy-critical state - see this file's own header audit. Never
-- touches an Instance anywhere.
local choices: { [number]: Outcomes.Choice } = {}
local locked: { [number]: boolean } = {}

local pendingPhaseTimerThread: thread? = nil

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function isQualifier(userId: number): boolean
	return table.find(qualifierIds, userId) ~= nil
end

local function allLocked(): boolean
	for _, id in qualifierIds do
		if not locked[id] then
			return false
		end
	end
	return true
end

local function cancelPendingPhaseTimer()
	if pendingPhaseTimerThread ~= nil then
		task.cancel(pendingPhaseTimerThread)
		pendingPhaseTimerThread = nil
	end
end

-- The one place `currentPhase` ever changes - so it's also the one
-- place that can correctly fire "the previous phase just ended" before
-- "the new phase just began." A subscriber never sees these fire out of
-- order or for the wrong phase.
local function broadcastPhase(phase: Phase, endsAt: number?)
	if currentPhase ~= nil then
		exitSignals[currentPhase]:Fire()
	end
	currentPhase = phase
	Net.fireAllClients("DecisionPhaseChanged", { phase = phase, endsAt = endsAt })
	enterSignals[phase]:Fire(endsAt)
end

local function isDebugAuthorized(player: Player?): boolean
	if RunService:IsStudio() then
		return true
	end
	if player == nil then
		return false
	end
	return table.find(DEBUG_USER_IDS, player.UserId) ~= nil
end

-- Maps an Outcomes.luau branch name to ProfileLogic's OutcomeTag
-- (design-decisions.md Q1's "streak tier x outcome tier" reward lookup
-- key) - nil for a branch with no winners (AllSteal/TwoSteal), since
-- nothing ever looks up a tag for a loser.
local function outcomeTagFor(branch: string): ProfileLogic.OutcomeTag?
	if branch == "SoleSteal" or branch == "OneStealOneShare" then
		return "SoleStealer"
	elseif branch == "LoneShare" then
		return "LoneSharer"
	elseif branch == "AllShare" or branch == "TwoShare" or branch == "SoloFinalist" then
		return "AllShare"
	end
	return nil
end

-- Step 3 + 4: resolves via the pure outcome module, then writes every
-- STILL-CONNECTED qualifier's real result to their profile. A qualifier
-- who's already disconnected by this point is silently skipped here -
-- not because their result doesn't matter, but because it was ALREADY
-- applied, correctly, by their own pending-round-outcome resolver
-- (registered in beginDecisionStudio) the instant they left - see this
-- file's header comment on design-decisions.md Q4.
--
-- SCOPE: only bumps the stats this function can know COMPLETELY and
-- correctly for the 3 qualifiers it sees - "qualifications", "steals"/
-- "shares", "wins"/"losses". "roundsPlayed" spans all 6 players in a
-- round, not just the 3 who reached the Studio, and belongs to whatever
-- eventually owns the full-roster round lifecycle - not implemented
-- here.
local function computeOutcomeAndWriteProfiles(): Outcomes.OutcomeResult
	local DataService = Loader.get("DataService") :: any

	local finalists: { Outcomes.FinalistInput } = {}
	local tierNumberByPlayerId: { [number]: number } = {}

	for _, id in qualifierIds do
		local player = Players:GetPlayerByUserId(id)
		local streak = if player ~= nil then DataService.getStreak(player) else 0
		local tier = ProfileLogic.resolveBountyTier(GameConfig.bountyTiers, streak)
		tierNumberByPlayerId[id] = tier.tier

		table.insert(finalists, {
			playerId = id,
			choice = choices[id],
			soleStealerVU = tier.soleStealerVU,
			loneSharerVU = tier.loneSharerVU,
			allShareVU = tier.allShareVU,
		})
	end

	local outcome = Outcomes.resolve(finalists)

	for _, finalist in finalists do
		local player = Players:GetPlayerByUserId(finalist.playerId)
		if player == nil then
			continue
		end

		-- Only `won` matters here, not the winner's own bountyVU number -
		-- PendingBounty (ProfileLogic.luau) stores streakTier + an
		-- OutcomeTag, not a raw VU figure; the VU-to-item lookup itself
		-- is design-decisions.md Q1's still-unbuilt RewardTables module.
		local won = false
		for _, winner in outcome.winners do
			if winner.playerId == finalist.playerId then
				won = true
			end
		end

		if won then
			DataService.incrementStreak(player)
			DataService.recordRoundStat(player, "wins")

			local outcomeTag = outcomeTagFor(outcome.branch)
			if outcomeTag ~= nil then
				DataService.setPendingBounty(player, {
					streakTier = tierNumberByPlayerId[finalist.playerId],
					outcomeTag = outcomeTag,
					grantedAt = os.time(),
				})
			else
				warn(
					string.format(
						"DecisionService: %s won but branch %q has no OutcomeTag mapping - no bounty granted",
						player.Name,
						outcome.branch
					)
				)
			end
		else
			DataService.resetStreak(player)
			DataService.recordRoundStat(player, "losses")
		end

		DataService.recordRoundStat(player, if finalist.choice == "Steal" then "steals" else "shares")
		DataService.recordRoundStat(player, "qualifications")

		-- Their real result is now written - the Q4 forfeit fallback
		-- must never fire for someone who made it through normally.
		DataService.setPendingRoundOutcomeResolver(player, nil)
	end

	print(
		string.format(
			"DecisionService: resolved %s - %d winner(s), %d loser(s)",
			outcome.branch,
			#outcome.winners,
			#outcome.loserIds
		)
	)

	return outcome
end

-- ===== phase sequence =======================================================
-- Explicit, not a generic transition table (unlike RoundStates.luau) -
-- this sequence is strictly linear with exactly one path through it, so
-- a reusable legality table would be pure abstraction with nothing to
-- abstract over. Each function's own side effect (the resolve-and-write
-- step at Choose's end, the round transition at Resolve's start) is
-- different enough that writing them out directly is clearer than
-- forcing them through one generic "advance" function.

local enterIntro: () -> ()
local enterNegotiate: () -> ()
local enterChoose: () -> ()
local enterReveal: (outcome: Outcomes.OutcomeResult) -> ()
local enterResolve: () -> ()

-- Step 6.
enterResolve = function()
	broadcastPhase("Resolve", nil)
	local RoundService = Loader.get("RoundService") :: any
	RoundService.requestTransition("Results")
end

-- Step 5.
enterReveal = function(outcome: Outcomes.OutcomeResult)
	local duration = GameConfig.studioTimers.revealDelaySeconds
	broadcastPhase("Reveal", now() + duration)

	Net.fireAllClients("DecisionReveal", {
		choices = choices,
		outcome = outcome,
		revealAt = now() + REVEAL_ANIMATION_LEAD_SECONDS,
	})

	pendingPhaseTimerThread = task.delay(duration, function()
		pendingPhaseTimerThread = nil
		enterResolve()
	end)
end

-- Steps 1-4, the one function both the Choose timer AND an early
-- all-locked completion call.
local function resolveAndReveal()
	cancelPendingPhaseTimer()

	for _, id in qualifierIds do
		if not locked[id] then
			choices[id] = GameConfig.decisionStudioDefaultChoice
			locked[id] = true
		end
	end

	local outcome = computeOutcomeAndWriteProfiles()
	enterReveal(outcome)
end

enterChoose = function()
	local duration = GameConfig.studioTimers.chooseSeconds
	broadcastPhase("Choose", now() + duration)

	pendingPhaseTimerThread = task.delay(duration, function()
		pendingPhaseTimerThread = nil
		resolveAndReveal()
	end)
end

enterNegotiate = function()
	local duration = GameConfig.studioTimers.negotiateSeconds
	broadcastPhase("Negotiate", now() + duration)

	pendingPhaseTimerThread = task.delay(duration, function()
		pendingPhaseTimerThread = nil
		enterChoose()
	end)
end

enterIntro = function()
	local duration = GameConfig.studioTimers.introSeconds
	broadcastPhase("Intro", now() + duration)

	pendingPhaseTimerThread = task.delay(duration, function()
		pendingPhaseTimerThread = nil
		enterNegotiate()
	end)
end

-- ===== submission + disconnect handling ====================================

-- "Anything else is dropped silently and logged" (the task's own
-- requirement, verbatim) - `warn` here, nothing back to the sender ever,
-- for any rejection reason. Telling a hostile client WHY its attempt
-- failed (e.g. "already locked") is itself a small information leak this
-- function avoids by construction.
-- The one function that can ever record a choice, for any finalist
-- there is (P3-6 - an NPC qualifies through the normal path,
-- design-decisions.md Q5, so it needs to be able to lock in too).
-- `who` is only ever used to name the rejection in a log line; every
-- actual rule below is checked against the id.
--
-- Returns whether the lock was accepted, so an NPC caller can tell a
-- dropped submission from an accepted one - a human's client is
-- deliberately told nothing either way (see below).
local function lockIn(racerId: number, choice: any, who: string): boolean
	if currentPhase ~= "Choose" then
		warn(string.format("DecisionService: dropped ChooseIntent from %s - wrong phase", who))
		return false
	end
	if not isQualifier(racerId) then
		warn(string.format("DecisionService: dropped ChooseIntent from %s - not a qualifier", who))
		return false
	end
	if choice ~= "Steal" and choice ~= "Share" then
		warn(string.format("DecisionService: dropped ChooseIntent from %s - invalid choice value", who))
		return false
	end
	if locked[racerId] then
		warn(string.format("DecisionService: dropped ChooseIntent from %s - already locked (locks are final)", who))
		return false
	end

	choices[racerId] = choice :: Outcomes.Choice
	locked[racerId] = true

	-- Still only {playerId} - the secrecy audit at the top of this file
	-- holds identically for a bot's lock-in. A client learning WHICH of
	-- the finalists is an NPC is fine (they can see the rig); learning
	-- what it picked before the reveal is not, and this payload has
	-- never carried it.
	Net.fireAllClients("DecisionLockedIn", { playerId = racerId })

	if allLocked() then
		resolveAndReveal()
	end

	return true
end

local function handleChooseIntent(player: Player, choice: any)
	-- Rate limit: already enforced by NetGuard before this handler ever
	-- runs (Net.Remotes.DecisionChooseIntent's own rateLimit) - nothing
	-- to re-check here.
	lockIn(player.UserId, choice, player.Name)
end

-- design-decisions.md Q4's substitution half: locks a leaving qualifier
-- in as the default choice immediately, rather than waiting out a full
-- phase timer for someone who is definitely not coming back. The other
-- half of Q4 (the leaver personally always losing, regardless of the
-- computed outcome) is handled separately, by the pending-round-outcome
-- resolver registered in beginDecisionStudio - that one has to run at
-- THEIR session's own end, which may happen well before this function
-- ever does.
local function handleQualifierLeaving(userId: number)
	if not isQualifier(userId) or locked[userId] then
		return
	end

	choices[userId] = GameConfig.decisionStudioDefaultChoice
	locked[userId] = true

	if currentPhase == "Choose" and allLocked() then
		resolveAndReveal()
	end
end

-- ===== debug =================================================================

-- "Include the debug hooks to force any of the four branches" (the
-- task's own requirement) - forces all 3 qualifiers' choices to a
-- pattern matching `branch`, then resolves immediately, skipping the
-- rest of the Choose window entirely.
local function debugForceOutcome(branch: OutcomeBranch)
	if currentPhase == nil then
		warn("DecisionService: debugForceOutcome - no Decision Studio is currently active")
		return
	end
	if #qualifierIds ~= 3 then
		warn(
			string.format(
				"DecisionService: debugForceOutcome needs exactly 3 qualifiers to force a 3-player branch, got %d",
				#qualifierIds
			)
		)
		return
	end

	local pattern: { Outcomes.Choice }
	if branch == "SoleSteal" then
		pattern = { "Steal", "Share", "Share" }
	elseif branch == "LoneShare" then
		pattern = { "Steal", "Steal", "Share" }
	elseif branch == "AllShare" then
		pattern = { "Share", "Share", "Share" }
	else -- "AllSteal"
		pattern = { "Steal", "Steal", "Steal" }
	end

	for index, id in qualifierIds do
		choices[id] = pattern[index]
		locked[id] = true
	end

	resolveAndReveal()
end

-- ===== round lifecycle ======================================================

local function beginDecisionStudio()
	local TaskService = Loader.get("TaskService") :: any
	local qualificationResult = TaskService.getLastQualificationResult()

	qualifierIds = {}
	if qualificationResult ~= nil then
		for _, id in qualificationResult.qualifiers do
			table.insert(qualifierIds, id)
		end
	end
	choices = {}
	locked = {}
	currentPhase = nil

	if #qualifierIds == 0 then
		warn("DecisionService: no qualifiers to run the Decision Studio with - skipping straight to Results")
		local RoundService = Loader.get("RoundService") :: any
		RoundService.requestTransition("Results")
		return
	end

	local DataService = Loader.get("DataService") :: any
	for _, id in qualifierIds do
		local player = Players:GetPlayerByUserId(id)
		if player == nil then
			continue
		end

		-- design-decisions.md Q4: a qualifier who disconnects mid-Studio
		-- always personally takes the loss, independent of whatever the
		-- 3-way table eventually says. Registered for every qualifier
		-- NOW, so a disconnect at any point before their real result is
		-- written can't leave their streak in an undefined state -
		-- ProfileLogic.applyLeaveSequence guarantees this runs before
		-- their ProfileStore session actually ends.
		DataService.setPendingRoundOutcomeResolver(player, function()
			DataService.resetStreak(player)
			DataService.recordRoundStat(player, "losses")
		end)
	end

	Net.fireAllClients("DecisionParticipants", { qualifierIds = qualifierIds })
	enterIntro()
end

local DecisionService: Loader.Service = {
	name = "DecisionService",
	dependencies = { "NetGuard", "ConfigValidator", "RoundService", "TaskService", "DataService" },

	debugForceOutcome = debugForceOutcome,

	getPhase = function(): Phase?
		return currentPhase
	end,

	getQualifierIds = function(): { number }
		return table.clone(qualifierIds)
	end,

	-- P3-6's seam: an NPC locks in through the same function a human's
	-- remote does, with the same four checks. Server-side only - no
	-- remote routes here, so a client can't submit on a bot's behalf.
	submitChoiceFor = function(racerId: number, choice: string, who: string): boolean
		return lockIn(racerId, choice, who)
	end,

	onPhaseEnter = function(phase: Phase, callback: (endsAt: number?) -> ())
		return enterSignals[phase]:Connect(callback)
	end,

	onPhaseExit = function(phase: Phase, callback: () -> ())
		return exitSignals[phase]:Connect(callback)
	end,
}

function DecisionService:init()
	local RoundService = Loader.get("RoundService") :: any
	local NetGuard = Loader.get("NetGuard") :: any

	RoundService.onEnter("DecisionStudio", function()
		beginDecisionStudio()
	end)

	RoundService.onPlayerLeaving(function(player: Player, state: string)
		if state == "DecisionStudio" then
			handleQualifierLeaving(player.UserId)
		end
	end)

	NetGuard.on("DecisionChooseIntent", function(player: Player, payload: any)
		handleChooseIntent(player, payload.choice)
	end)

	NetGuard.on("DecisionDebugForceOutcome", function(player: Player, payload: any)
		if not isDebugAuthorized(player) then
			warn(
				string.format(
					"DecisionService: unauthorized DecisionDebugForceOutcome attempt by %s (%d)",
					player.Name,
					player.UserId
				)
			)
			return
		end
		debugForceOutcome(payload.branch)
	end)
end

return DecisionService
