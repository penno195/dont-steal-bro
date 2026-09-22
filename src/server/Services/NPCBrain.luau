--!strict
-- The two behaviours P3-6 adds on top of P3-5's NPC fill: using
-- power-ups during the race, and negotiating in the Decision Studio.
-- The decisions themselves are arithmetic and live in
-- NPCBrainLogic.luau (unit-tested); this file supplies real positions,
-- inventories and phase timings, and routes every decision through the
-- validated server path.
--
-- ===== NEVER A SHORTCUT =================================================
--
-- P3-6's own requirement is that NPCs "obey exactly the same cooldowns,
-- ranges and immunity rules as players - route every use through the
-- existing validated server path, never a shortcut." Concretely, this
-- file has no ability to do otherwise:
--
--   * It cannot apply an effect. It calls
--     PowerUpService.useForRacer(id, slot), the same function a human's
--     PowerUpUseIntent reaches after NetGuard authenticates it - the
--     same slot check, the same server-held cooldown timestamp, the
--     same range/cone resolution, the same hard-control immunity rules
--     inside StatusEffects. See PowerUpService.useFor's own comment.
--   * It cannot record a choice. It calls
--     DecisionService.submitChoiceFor(id, choice), which is the same
--     `lockIn` a human's DecisionChooseIntent reaches, with the same
--     four checks (right phase, is a qualifier, valid value, not
--     already locked).
--   * It cannot even see whether a use would succeed. It reads
--     PowerUpService.isOnCooldownFor - the service's own read-only
--     answer from its own state - rather than tracking cooldowns
--     itself, so the brain can never believe something the validator
--     would disagree with.
--
-- A bot therefore fails exactly where a player fails: out of range,
-- on cooldown, into an immunity window. It just doesn't complain.
--
-- ===== WHY BUBBLE CHAT IS A BROADCAST, NOT A SERVER CALL ================
--
-- TextChatService:DisplayBubble(partOrCharacter, message) is a CLIENT
-- method - the server can decide a bubble should appear but cannot make
-- one appear. So the decision is made here, server-side and
-- authoritative, and broadcast as NPCChatBubble for
-- NPCBubbleController to render. The line content is chosen from
-- config on the server precisely so a client can never influence what a
-- bot appears to say.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local NPCPersonalities = require(ReplicatedStorage.Shared.Config.NPCPersonalities)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local Participants = require(ServerScriptService.Server.Participants)
local NPCLogic = require(ServerScriptService.Server.NPCLogic)
local NPCBrainLogic = require(ServerScriptService.Server.NPCBrainLogic)

local powerUpDefsById: { [string]: Validate.PowerUpDef } = {}
for _, entry in PowerUps do
	local def = entry.def :: Validate.PowerUpDef
	powerUpDefsById[def.id] = def
end

local personalities: { NPCBrainLogic.Personality } = {}
for _, entry in NPCPersonalities do
	table.insert(personalities, entry.def :: any)
end

type BrainRecord = {
	id: number,
	personality: NPCBrainLogic.Personality,
	nextRandom: () -> number,
	-- The hidden choice, rolled once when the Studio starts rather than
	-- at lock-in time. Rolling it early is what lets the bot's lines be
	-- independent of it in a way that is checkable: nothing between the
	-- roll and the lock-in can read a line and change the answer.
	choice: ("Steal" | "Share")?,
	saidLines: { [string]: boolean },
}

local brains: { [number]: BrainRecord } = {}
local decisionThread: thread? = nil
local studioThreads: { thread } = {}

local function clearStudioThreads()
	for _, thread in studioThreads do
		task.cancel(thread)
	end
	studioThreads = {}
end

-- ===== brains ===============================================================

-- One brain per live NPC, created lazily so a bot spawned late (or by a
-- Studio debug call) still gets one. Seeded from the bot's own id the
-- same way NPCService seeds its movement RNG, with a different offset
-- so the two streams don't march in step.
local function ensureBrain(npcId: number): BrainRecord?
	local existing = brains[npcId]
	if existing ~= nil then
		return existing
	end
	if #personalities == 0 then
		return nil
	end

	local nextRandom = NPCLogic.newRng(npcId * 104729 + 17)
	local record: BrainRecord = {
		id = npcId,
		personality = NPCBrainLogic.pickPersonality(personalities, nextRandom()),
		nextRandom = nextRandom,
		choice = nil,
		saidLines = {},
	}
	brains[npcId] = record
	return record
end

-- ===== race: power-up use ===================================================

local function characterPosition(racerId: number): Vector3?
	local participant = Participants.get(racerId)
	local character = if participant ~= nil then participant.character else nil
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	return root.Position
end

-- The two situational readings the utility score needs, both taken from
-- TaskService's own public view rather than anything this file tracks
-- itself - so a bot's picture of the race is exactly the race.
local function buildSituation(npcId: number, def: Validate.PowerUpDef): NPCBrainLogic.Situation?
	local TaskService = Loader.get("TaskService") :: any

	local ownProgress = TaskService.getProgressFor(npcId)
	if ownProgress == nil then
		return nil -- not racing right now; nothing to reason about
	end

	local ownPosition = characterPosition(npcId)
	if ownPosition == nil then
		return nil
	end

	local ownCompleted = ownProgress.tasksCompleted :: number
	local leaderCompleted = ownCompleted
	local nearestAhead: number? = nil

	for _, racerId in TaskService.getRacerIds() :: { number } do
		if racerId == npcId then
			continue
		end
		local progress = TaskService.getProgressFor(racerId)
		if progress == nil then
			continue
		end

		local completed = progress.tasksCompleted :: number
		if completed > leaderCompleted then
			leaderCompleted = completed
		end

		if completed > ownCompleted then
			local position = characterPosition(racerId)
			if position ~= nil then
				local distance = (position - ownPosition).Magnitude
				if nearestAhead == nil or distance < (nearestAhead :: number) then
					nearestAhead = distance
				end
			end
		end
	end

	local travelDistance: number? = nil
	local remaining = TaskService.getRemainingStations(npcId) :: { { stationId: string, taskId: string } }
	if #remaining > 0 then
		local part = TaskService.getStationPart(remaining[1].stationId) :: BasePart?
		if part ~= nil then
			travelDistance = (part.Position - ownPosition).Magnitude
		end
	end

	local PowerUpService = Loader.get("PowerUpService") :: any

	return {
		kind = def.kind,
		onCooldown = PowerUpService.isOnCooldownFor(npcId, def.id),
		progressDeficit = math.max(leaderCompleted - ownCompleted, 0),
		distanceToNextStationStuds = travelDistance,
		nearestAheadDistanceStuds = nearestAhead,
		useRangeStuds = GameConfig.powerUpUseRangeStuds,
	}
end

local function considerPowerUp(npcId: number)
	local PowerUpService = Loader.get("PowerUpService") :: any
	local inventory = PowerUpService.getInventoryFor(npcId) :: { string }?
	if inventory == nil or #inventory == 0 then
		return
	end

	local weights = GameConfig.npcBrain.utility
	local bestSlot: number? = nil
	local bestScore = 0

	-- Scores every slot even though the default inventory is one deep:
	-- powerUpInventorySlots is config, and a two-slot round shouldn't
	-- silently only ever use slot 1.
	for slotIndex, powerUpId in inventory do
		local def = powerUpDefsById[powerUpId]
		if def == nil then
			continue
		end

		local situation = buildSituation(npcId, def)
		if situation == nil then
			return
		end

		local score = NPCBrainLogic.scoreAction(situation, weights)
		if score > bestScore then
			bestScore = score
			bestSlot = slotIndex
		end
	end

	if bestSlot == nil or not NPCBrainLogic.shouldUse(bestScore, weights) then
		return
	end

	-- No explicit target id: the server's own smart targeting picks one,
	-- exactly as it does for a player who fires without a target hint.
	-- Handing it a target the brain chose would be the shortcut this
	-- file exists not to take.
	PowerUpService.useForRacer(npcId, bestSlot, nil)
end

local function startDeciding()
	if decisionThread ~= nil then
		return
	end

	local interval = 1 / GameConfig.npcBrain.decisionHz
	decisionThread = task.spawn(function()
		while true do
			task.wait(interval)
			local NPCService = Loader.get("NPCService") :: any
			for _, npcId in NPCService.getNPCIds() :: { number } do
				local errMessage: string? = nil
				local ok = xpcall(considerPowerUp, function(err)
					errMessage = tostring(err)
				end, npcId)
				if not ok then
					warn(string.format("NPCBrain: decision failed for %d - %s", npcId, tostring(errMessage)))
				end
			end
		end
	end)
end

local function stopDeciding()
	local thread = decisionThread
	if thread ~= nil then
		task.cancel(thread)
		decisionThread = nil
	end
end

-- ===== Decision Studio ======================================================

local function say(record: BrainRecord, line: string)
	record.saidLines[line] = true
	Net.fireAllClients("NPCChatBubble", { npcId = record.id, message = line })
end

-- Schedules everything this bot will say and do for the whole Negotiate
-- window up front, rather than re-deciding each tick. The window has a
-- known length and a known shape, and a bot that can't change its mind
-- about WHEN to speak is one that can't accidentally speak twice at
-- once.
local function beginNegotiate(endsAt: number?)
	if endsAt == nil then
		return
	end

	local DecisionService = Loader.get("DecisionService") :: any
	local config = GameConfig.npcBrain

	-- Measured against Workspace:GetServerTimeNow(), because that is the
	-- clock `endsAt` came from - DecisionService's own `now()`. Reading
	-- it from the deadline rather than from studioTimers.negotiateSeconds
	-- means a debug-shortened phase still schedules lines inside the
	-- window it actually has, instead of talking over the next phase.
	local windowSeconds = math.max(endsAt - Workspace:GetServerTimeNow(), 0)
	if windowSeconds <= 0 then
		return
	end

	for _, racerId in DecisionService.getQualifierIds() :: { number } do
		if not Participants.isNPCId(racerId) then
			continue
		end

		local record = ensureBrain(racerId)
		if record == nil then
			continue
		end

		-- The hidden choice, rolled now and never revisited. It is
		-- deliberately independent of every line below: "canned
		-- bubble-chat lines that may or may not match what it actually
		-- does" (P3-6's own wording) is only true if nothing downstream
		-- reads one to pick the other.
		record.choice = NPCBrainLogic.rollChoice(record.personality, record.nextRandom())
		record.saidLines = {}

		local schedule = NPCBrainLogic.lineScheduleSeconds(
			windowSeconds,
			config.negotiationLineCount,
			config.minSecondsBetweenLines,
			record.nextRandom
		)

		for _, offset in schedule do
			local progress = if windowSeconds > 0 then offset / windowSeconds else 0
			table.insert(
				studioThreads,
				task.delay(offset, function()
					local line =
						NPCBrainLogic.selectLine(record.personality, progress, record.nextRandom(), record.saidLines)
					if line ~= nil then
						say(record, line)
					end
				end)
			)
		end
	end
end

local function beginChoose()
	local DecisionService = Loader.get("DecisionService") :: any
	local config = GameConfig.npcBrain
	local windowSeconds = GameConfig.studioTimers.chooseSeconds

	for _, racerId in DecisionService.getQualifierIds() :: { number } do
		if not Participants.isNPCId(racerId) then
			continue
		end

		local record = brains[racerId]
		if record == nil or record.choice == nil then
			continue
		end

		-- The last-second wobble: a line during Choose, before
		-- committing. It says nothing about the choice - it's drawn
		-- from the wobbles pool regardless of what was rolled - so it
		-- can't be read as a tell.
		if record.nextRandom() < config.chooseWobbleChance then
			local line = NPCBrainLogic.selectLine(record.personality, 1, record.nextRandom(), record.saidLines)
			if line ~= nil then
				table.insert(
					studioThreads,
					task.delay(windowSeconds * config.lockInEarliestFraction * 0.5, function()
						say(record, line)
					end)
				)
			end
		end

		local offset = NPCBrainLogic.lockInOffsetSeconds(
			windowSeconds,
			record.nextRandom(),
			config.lockInEarliestFraction,
			config.lockInLatestFraction
		)

		table.insert(
			studioThreads,
			task.delay(offset, function()
				local choice = record.choice
				if choice == nil then
					return
				end
				DecisionService.submitChoiceFor(record.id, choice, record.personality.displayName .. " NPC")
			end)
		)
	end
end

-- ===== service ==============================================================

local NPCBrain: Loader.Service = {
	name = "NPCBrain",
	dependencies = {
		"ConfigValidator",
		"RoundService",
		"TaskService",
		"PowerUpService",
		"DecisionService",
		"NPCService",
		"ParticipantService",
	},

	-- Studio/debug read-only view. The personality is HIDDEN from
	-- players by design (architecture.md §4's "hidden personality
	-- weights"), so this is deliberately server-side only and never
	-- broadcast - a client that knew a finalist was Loyal would have
	-- most of the game solved.
	debugGetPersonality = function(npcId: number): string?
		local record = brains[npcId]
		return if record ~= nil then record.personality.id else nil
	end,
}

function NPCBrain:init()
	local RoundService = Loader.get("RoundService") :: any
	local DecisionService = Loader.get("DecisionService") :: any

	RoundService.onEnter("Race", function()
		brains = {}
		startDeciding()
	end)

	RoundService.onExit("Race", function()
		stopDeciding()
	end)

	RoundService.onExit("DecisionStudio", function()
		clearStudioThreads()
	end)

	DecisionService.onPhaseEnter("Negotiate", function(endsAt: number?)
		beginNegotiate(endsAt)
	end)

	DecisionService.onPhaseEnter("Choose", function()
		beginChoose()
	end)
end

return NPCBrain
