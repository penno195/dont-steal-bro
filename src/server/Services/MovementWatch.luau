--!strict
-- Server-side movement sanity checker (P2-9). Compares each character's
-- observed horizontal speed against the maximum StatusEffects' own
-- resolver says they should be capable of right now, and keeps a
-- rolling per-player violation score rather than judging any single
-- sample in isolation.
--
-- LOG ONLY, DELIBERATELY (the task's own requirement, verbatim: "no
-- kicks, no rubber-banding"). `MovementSanity.levelFor` can return "Act"
-- and `GameConfig.movementViolationActThreshold` is a real, validated
-- config field, but nothing anywhere in this file DOES anything
-- differently when a sample reaches that level versus "Flag" - both are
-- reported through the exact same `reportSink` call. The threshold and
-- the level exist now so enforcement is a later, deliberate decision
-- (flip a behavior on for "Act") rather than a rewrite of this file's
-- structure - see docs/movement-watch-notes.md for how to actually make
-- that call.
--
-- WHY THIS COMPARES AGAINST StatusEffects.getResolvedStats(player), NOT
-- A FIXED CONSTANT: "the maximum the status effect resolver says they
-- should be capable of" (the task's own requirement, verbatim) - a
-- player mid-Freeze is allowed exactly 0 studs/s, a player under Sprint
-- Boost is allowed more than baseline, and both of those are already
-- correctly reflected in the resolver's own live output. Comparing
-- against a single hard-coded "max speed" would either false-flag every
-- buffed player or miss real cheating during a debuff.
--
-- LEGITIMATE CAUSES OF APPARENT SPEED, AND HOW EACH IS HANDLED:
--   - Falling: two separate mechanisms, not one. MovementSanity.
--     horizontalSpeed only ever measures X/Z movement, never Y, so a
--     straight-down drop contributes nothing regardless of how fast it
--     was. Separately, `sample` skips the check entirely while
--     Humanoid:GetState() == Freefall, because WalkSpeed only caps
--     GROUND locomotion - a normal jump arc (or a Push/Trip launch, or
--     anything else that leaves the ground) can legitimately carry
--     horizontal momentum faster than WalkSpeed while airborne, and
--     that's real physics, not a speed hack.
--   - The respawn frame: `track.lastPosition` is cleared on every
--     CharacterAdded, so the first sample after a spawn/respawn always
--     just re-baselines rather than measuring "movement" from the
--     previous character's last known position.
--   - Teleports the game itself performs: `suppressNextSample(player)`
--     is a public seam any service can call right before moving a
--     player server-side, so that interval re-baselines instead of
--     reading as a teleport-speed violation. As a second layer, a
--     sample taken outside the "Race" round state re-baselines
--     unconditionally too, on the assumption that most server-initiated
--     teleports (Loading, Qualified -> Decision Studio, etc) happen
--     between round states, not mid-Race - a future system doing a
--     mid-Race teleport still needs to call suppressNextSample itself.
--   - Lag spikes: no single sample can push the ROLLING score past a
--     threshold on its own (see MovementSanity.applySample's own
--     comment) - a one-off replication hiccup decays back out.
--   - Conveyors/launchers: no such map mechanic exists in this repo yet
--     (map-kit-spec.md defines no tag for one) - `setExternalVelocityAllowance`
--     is the seam for whenever one does, defaulting to a no-op.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MovementSanity = require(ReplicatedStorage.Shared.MovementSanity)

export type SanityEvent = {
	at: number,
	playerId: number,
	playerName: string,
	observedSpeed: number,
	allowedSpeed: number,
	excessRatio: number,
	score: number,
	level: MovementSanity.ViolationLevel,
}

export type RoundSummaryEntry = {
	playerName: string,
	sampleCount: number,
	violationCount: number,
	maxExcessRatio: number,
	finalScore: number,
	events: { SanityEvent },
}

type PlayerTrack = {
	lastPosition: Vector3?,
	lastSampleAt: number,
	suppressNextSample: boolean,
	scoreState: MovementSanity.ScoreState,
	events: { SanityEvent },
	sampleCount: number,
	violationCount: number,
	maxExcessRatio: number,
}

local tracks: { [Player]: PlayerTrack } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
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

local function toVec3(v: Vector3): MovementSanity.Vec3
	return { x = v.X, y = v.Y, z = v.Z }
end

local function ensureTrack(player: Player): PlayerTrack
	local track = tracks[player]
	if track == nil then
		track = {
			lastPosition = nil,
			lastSampleAt = 0,
			suppressNextSample = false,
			scoreState = { score = 0, lastSampleAt = 0 },
			events = {},
			sampleCount = 0,
			violationCount = 0,
			maxExcessRatio = 0,
		}
		tracks[player] = track
	end
	return track
end

local function defaultReportSink(event: SanityEvent)
	print(
		string.format(
			"MovementWatch [%s]: %s (%d) observed %.2f studs/s vs allowed %.2f (excess %.0f%%), rolling score %.2f",
			event.level,
			event.playerName,
			event.playerId,
			event.observedSpeed,
			event.allowedSpeed,
			event.excessRatio * 100,
			event.score
		)
	)
end

local reportSink: (event: SanityEvent) -> () = defaultReportSink

local function setReportSink(fn: (event: SanityEvent) -> ())
	reportSink = fn
end

-- The seam for a future conveyor/launcher mechanic - see this file's
-- header comment. Returns EXTRA allowed studs/second for `player` right
-- now, added on top of the resolver's own number before comparing.
local function defaultExternalVelocityAllowance(_player: Player): number
	return 0
end

local externalVelocityAllowance: (player: Player) -> number = defaultExternalVelocityAllowance

local function setExternalVelocityAllowance(fn: (player: Player) -> number)
	externalVelocityAllowance = fn
end

local function suppressNextSample(player: Player)
	ensureTrack(player).suppressNextSample = true
end

local function sample(player: Player, nowValue: number, inRace: boolean)
	local track = ensureTrack(player)
	local root = characterRoot(player.Character)

	if root == nil then
		track.lastPosition = nil
		return
	end

	if track.suppressNextSample or not inRace or track.lastPosition == nil then
		track.suppressNextSample = false
		track.lastPosition = root.Position
		track.lastSampleAt = nowValue
		return
	end

	local elapsed = nowValue - track.lastSampleAt
	if elapsed <= 0 then
		return
	end

	local character = player.Character :: Model
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local isFalling = humanoid ~= nil and humanoid:GetState() == Enum.HumanoidStateType.Freefall

	local observedSpeed =
		MovementSanity.horizontalSpeed(toVec3(track.lastPosition :: Vector3), toVec3(root.Position), elapsed)

	if not isFalling then
		local StatusEffects = Loader.get("StatusEffects") :: any
		local resolvedStats = StatusEffects.getResolvedStats(player)
		local baseWalkSpeed = StatusEffects.baseWalkSpeed :: number
		local allowedSpeed = if resolvedStats.ControlLock then 0 else baseWalkSpeed * resolvedStats.MoveSpeed
		allowedSpeed += externalVelocityAllowance(player)

		local excessRatio = MovementSanity.excessRatio(observedSpeed, allowedSpeed, GameConfig.movementSpeedTolerance)
		track.scoreState = MovementSanity.applySample(
			track.scoreState,
			excessRatio,
			nowValue,
			GameConfig.movementViolationDecayPerSecond
		)
		track.sampleCount += 1

		if excessRatio > 0 then
			track.violationCount += 1
			track.maxExcessRatio = math.max(track.maxExcessRatio, excessRatio)
		end

		-- Explicit declared type, not inferred - the same string-literal-
		-- union-precision gap StatusEffectResolver.resolve's own `stat`
		-- local hits (see its comment there); a declared local type
		-- clears it here too.
		local level: MovementSanity.ViolationLevel = MovementSanity.levelFor(
			track.scoreState.score,
			GameConfig.movementViolationLogThreshold,
			GameConfig.movementViolationFlagThreshold,
			GameConfig.movementViolationActThreshold
		)

		if level ~= "Clean" then
			local event: SanityEvent = {
				at = nowValue,
				playerId = player.UserId,
				playerName = player.Name,
				observedSpeed = observedSpeed,
				allowedSpeed = allowedSpeed,
				excessRatio = excessRatio,
				score = track.scoreState.score,
				level = level,
			}
			table.insert(track.events, event)
			reportSink(event)
		end
	end

	track.lastPosition = root.Position
	track.lastSampleAt = nowValue
end

local function runSamplingLoop()
	while true do
		task.wait(GameConfig.movementSampleIntervalSeconds)

		local RoundService = Loader.get("RoundService") :: any
		local inRace = RoundService.getState() == "Race"
		local nowValue = now()

		for _, player in Players:GetPlayers() do
			sample(player, nowValue, inRace)
		end
	end
end

local function getRoundSummary(): { [number]: RoundSummaryEntry }
	local summary: { [number]: RoundSummaryEntry } = {}
	for player, track in tracks do
		summary[player.UserId] = {
			playerName = player.Name,
			sampleCount = track.sampleCount,
			violationCount = track.violationCount,
			maxExcessRatio = track.maxExcessRatio,
			finalScore = track.scoreState.score,
			events = track.events,
		}
	end
	return summary
end

-- "A summary report per round: violations per player with the raw
-- numbers behind them" (the task's own requirement, verbatim) - printed
-- automatically once the round leaves Race, not just available on
-- request.
local function printRoundSummary()
	print("=== MovementWatch round summary ===")
	local summary = getRoundSummary()
	local anyViolations = false

	for _, entry in summary do
		if entry.violationCount > 0 then
			anyViolations = true
			print(
				string.format(
					"  %s: %d/%d sample(s) over the tolerance cap, peak excess %.0f%%, final rolling score %.2f",
					entry.playerName,
					entry.violationCount,
					entry.sampleCount,
					entry.maxExcessRatio * 100,
					entry.finalScore
				)
			)
		end
	end

	if not anyViolations then
		print("  no violations this round")
	end
end

local MovementWatch: Loader.Service = {
	name = "MovementWatch",
	dependencies = { "NetGuard", "ConfigValidator", "RoundService", "StatusEffects" },

	suppressNextSample = suppressNextSample,
	setReportSink = setReportSink,
	setExternalVelocityAllowance = setExternalVelocityAllowance,
	getRoundSummary = getRoundSummary,
}

function MovementWatch:init()
	local RoundService = Loader.get("RoundService") :: any

	RoundService.onEnter("Race", function()
		-- A fresh round starts with a clean slate - no score/history
		-- carried over from a previous Studio test race (same "debug
		-- replay" concern TaskHandlerService.luau and PowerUpService.luau
		-- both document).
		tracks = {}
	end)

	RoundService.onExit("Race", function()
		printRoundSummary()
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		tracks[player] = nil
	end)
end

function MovementWatch:start()
	task.spawn(runSamplingLoop)
end

return MovementWatch
