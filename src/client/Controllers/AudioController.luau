--!strict
-- Every sound the game makes (P8-3). The rules - which cue, how loud,
-- who ducks whom, what gets dropped when the budget is full - live in
-- AudioLogic; this file owns the Sound instances and the event wiring.
-- docs/audio-and-feel.md is the brief.
--
-- ROUTING. Every Sound goes through the "Music" or "SFX" SoundGroup, the
-- two SettingsController sets from the player's sliders. Per-cue volume
-- and ducking are written on the Sound itself, so they multiply with the
-- slider rather than fight it.
--
-- POOLING. One-shots come from a per-cue pool (POOL_PER_CUE Sounds each),
-- created on first use and reused after. A cue whose pool is all playing
-- restarts its oldest Sound rather than growing. On top of that the
-- AudioLogic voice budget caps how many SFX sound at once across ALL cues.
--
-- BEDS. Hub, race and Studio music are three looped Sounds that crossfade
-- (AudioLogic.BED_FADE) as the round state changes; the race tension stem
-- rides on top of the race bed. A bed at zero fade is stopped, not just
-- silent, so it costs nothing.
--
-- CLEANUP. Loading, Cleanup and WaitingForPlayers end the round for audio:
-- every one-shot stops, every duck clears, per-round memory resets, and a
-- round token invalidates any reveal cue still scheduled with task.delay.
--
-- Presentation only: nothing here reaches the server (Ground Rule 1).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Clock = require(ReplicatedStorage.Shared.Clock)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Maps = require(ReplicatedStorage.Shared.Config.Maps)
local Net = require(ReplicatedStorage.Shared.Net)
local AudioLogic = require(script.Parent.Parent.UI.AudioLogic)
local DecisionLogic = require(script.Parent.Parent.UI.DecisionLogic)

local CUES = AudioLogic.CUES
local POOL_PER_CUE = 3
-- A reveal cue whose moment passed more than this long ago is skipped: a
-- late packet joins the reveal part-way (DecisionLogic.revealStep), and
-- replaying the cards it missed in a burst would be noise.
local LATE_TOLERANCE = 0.25

local selfId = Players.LocalPlayer.UserId

local poolFolder: Folder = nil :: any
local pools: { [string]: { Sound } } = {}

type Voice = { sound: Sound, priority: number, startedAt: number }
local voices: { Voice } = {}
local lastPlayed: { [string]: number } = {}
local ducks: { AudioLogic.ActiveDuck } = {}

type Track = { cueId: string, sound: Sound?, assetId: string, fade: number, target: number }
local function track(cueId: string): Track
	return { cueId = cueId, sound = nil, assetId = CUES[cueId].assetId, fade = 0, target = 0 }
end
local beds: { Hub: Track, Race: Track, Studio: Track } = {
	Hub = track("HubAmbience"),
	Race = track("RaceBed"),
	Studio = track("StudioBed"),
}
local bedList: { { key: AudioLogic.Bed, track: Track } } = {
	{ key = "Hub", track = beds.Hub },
	{ key = "Race", track = beds.Race },
	{ key = "Studio", track = beds.Studio },
}
local tension = track("RaceTension")

-- Per-round memory. resetRound() clears all of it.
local roundToken = 0
local roundState: string? = nil
local roundEndsAt: number? = nil
local selfQualified = false
local lastTick: number? = nil
local debuffKeys: { [string]: boolean } = {}
local inventoryCount = 0
local personalWon: boolean? = nil
local queueStatus: string? = nil

local function soundGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing ~= nil and existing:IsA("SoundGroup") then
		return existing
	end
	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Parent = SoundService
	return group
end

-- VOICES -------------------------------------------------------------

local function release(sound: Sound)
	for i, v in voices do
		if v.sound == sound then
			table.remove(voices, i)
			break
		end
	end
	-- A spatial Sound was borrowed onto a part; bring it home.
	if sound.Parent ~= poolFolder then
		sound.Parent = poolFolder
	end
end

local function newSound(cueId: string, def: AudioLogic.CueDef, assetId: string): Sound
	local sound = Instance.new("Sound")
	sound.Name = cueId
	sound.SoundId = assetId
	sound.Volume = def.volume
	sound.Looped = def.looped
	sound.SoundGroup = soundGroup(def.category)
	sound.Parent = poolFolder
	sound.Ended:Connect(function()
		release(sound)
	end)
	sound.Stopped:Connect(function()
		release(sound)
	end)
	return sound
end

local function acquire(cueId: string, def: AudioLogic.CueDef): Sound
	local pool = pools[cueId]
	if pool == nil then
		pool = {}
		pools[cueId] = pool
	end
	for _, sound in pool do
		if not sound.IsPlaying then
			return sound
		end
	end
	if #pool < POOL_PER_CUE then
		local sound = newSound(cueId, def, def.assetId)
		table.insert(pool, sound)
		return sound
	end
	-- Every copy is busy: restart the oldest (pool order is creation
	-- order, and the one that started first is the nearest to done).
	local oldest = pool[1]
	table.remove(pool, 1)
	table.insert(pool, oldest)
	oldest:Stop()
	return oldest
end

-- Plays a one-shot cue. `at` places a spatial cue on a part; a 2D cue
-- ignores it. Silent (and harmless) for a cue whose asset is still a
-- placeholder, so the game runs fine before any sound exists.
local function play(cueId: string, at: BasePart?)
	local def = CUES[cueId]
	if def == nil or def.looped or AudioLogic.isPlaceholder(def.assetId) then
		return
	end
	local now = Clock.now()
	if not AudioLogic.offCooldown(lastPlayed[cueId], def, now) then
		return
	end
	-- Cast: a Voice here carries its Sound too, which AudioLogic's
	-- Instance-free Voice can't name.
	local verdict, stealIndex =
		AudioLogic.admit((voices :: any) :: { AudioLogic.Voice }, def.priority, AudioLogic.MAX_SFX_VOICES)
	if verdict == "drop" then
		return
	elseif verdict == "steal" and stealIndex ~= nil then
		voices[stealIndex].sound:Stop() -- Stopped -> release() removes it
	end
	lastPlayed[cueId] = now

	local sound = acquire(cueId, def)
	if def.spatial and at ~= nil then
		sound.Parent = at
	end
	sound.TimePosition = 0
	sound:Play()
	table.insert(voices, { sound = sound, priority = def.priority, startedAt = now })
	if def.duck ~= nil then
		table.insert(ducks, { duck = def.duck, startedAt = now })
	end
end

-- BEDS ---------------------------------------------------------------

-- The running map's MapDef.musicTrackId. A map's clone keeps its model's
-- Name (its MapDef id), and every station sits somewhere under it - the
-- same lookup StationMarkerController uses.
local function currentMapMusic(): string?
	for _, station in CollectionService:GetTagged("TaskStation") do
		local root: Instance = station
		while root.Parent ~= nil and root.Parent ~= Workspace do
			root = root.Parent
		end
		if root.Parent ~= Workspace then
			continue
		end
		for _, entry in Maps do
			if entry.def.id == root.Name then
				return entry.def.musicTrackId
			end
		end
	end
	return nil
end

local function setBed(bed: AudioLogic.Bed)
	if bed == "Race" then
		local assetId = AudioLogic.resolveRaceBed(currentMapMusic())
		local race = beds.Race
		-- Swap only while silent, so a map change never cuts a playing bed.
		if assetId ~= race.assetId and race.fade == 0 then
			race.assetId = assetId
			if race.sound ~= nil then
				race.sound.SoundId = assetId
			end
		end
	end
	for _, entry in bedList do
		entry.track.target = if entry.key == bed then 1 else 0
	end
end

local function stepTrack(t: Track, dt: number, duck: number, extra: number)
	local step = dt / AudioLogic.BED_FADE
	t.fade = if t.fade < t.target then math.min(t.target, t.fade + step) else math.max(t.target, t.fade - step)
	if t.fade <= 0 then
		if t.sound ~= nil and t.sound.IsPlaying then
			t.sound:Stop()
		end
		return
	end
	if AudioLogic.isPlaceholder(t.assetId) then
		return
	end
	local def = CUES[t.cueId]
	local sound = t.sound
	if sound == nil then
		sound = newSound(t.cueId, def, t.assetId)
		t.sound = sound
	end
	assert(sound ~= nil, "bed Sound was just created")
	local volume = def.volume * t.fade * duck * extra
	if math.abs(sound.Volume - volume) > 0.001 then
		sound.Volume = volume
	end
	if not sound.IsPlaying then
		sound:Play()
	end
end

local function onHeartbeat(dt: number)
	local now = Clock.now()
	ducks = AudioLogic.pruneDucks(ducks, now)
	local duck = AudioLogic.duckLevel(ducks, now)

	-- Race intensity. It stops for a player who has qualified: they're
	-- done, and the countdown pressure belongs to the ones still racing.
	local racing = roundState == "Race" and roundEndsAt ~= nil and not selfQualified
	local speed = 1
	if racing then
		local left = (roundEndsAt :: number) - now
		local intensity = AudioLogic.raceIntensity(left)
		tension.target = intensity.tension
		speed = intensity.playbackSpeed
		local tick = AudioLogic.tickDue(left, lastTick)
		if tick ~= nil then
			lastTick = tick
			play("TimerTick")
		end
	else
		tension.target = 0
	end

	for _, entry in bedList do
		stepTrack(entry.track, dt, duck, 1)
	end
	-- The stem's fade IS the intensity, so it ramps at the fade rate and
	-- a sudden jump in time left can't slam it in.
	stepTrack(tension, dt, duck, 1)
	local raceSound = beds.Race.sound
	if raceSound ~= nil and math.abs(raceSound.PlaybackSpeed - speed) > 0.001 then
		raceSound.PlaybackSpeed = speed
	end
	if tension.sound ~= nil then
		tension.sound.PlaybackSpeed = speed
	end
end

-- ROUND LIFECYCLE ----------------------------------------------------

local function resetRound()
	roundToken += 1
	-- Copy first: Stop() fires Stopped, and release() edits `voices`.
	for _, v in table.clone(voices) do
		v.sound:Stop()
	end
	table.clear(voices)
	table.clear(ducks)
	selfQualified = false
	lastTick = nil
	debuffKeys = {}
	inventoryCount = 0
	personalWon = nil
end

local function onRoundState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	local state: string = payload.state
	roundEndsAt = if type(payload.endsAt) == "number" then payload.endsAt else nil
	if state == roundState then
		return
	end
	if state == "Loading" or state == "Cleanup" or state == "WaitingForPlayers" then
		resetRound()
	end
	roundState = state
	setBed(AudioLogic.bedFor(state))
end

local function onReveal(payload: any)
	local reveal = DecisionLogic.parseReveal(payload)
	if reveal == nil then
		return
	end
	local seats = 0
	for _ in reveal.choices do
		seats += 1
	end
	local token = roundToken
	local schedule, resultAt = AudioLogic.revealSchedule(seats, DecisionLogic.TIMING)
	table.insert(ducks, {
		duck = AudioLogic.revealDuck(DecisionLogic.revealLength(seats)),
		startedAt = reveal.revealAt,
	})

	local function at(offset: number, fn: () -> ())
		local delay = reveal.revealAt + offset - Clock.now()
		if delay < -LATE_TOLERANCE then
			return
		end
		task.delay(math.max(0, delay), function()
			if token == roundToken then
				fn()
			end
		end)
	end
	for _, entry in schedule do
		at(entry.at, function()
			play(entry.cue)
		end)
	end
	-- Read at resultAt, not now: DecisionPersonalResult may land after
	-- the reveal packet.
	at(resultAt, function()
		local cue = AudioLogic.resolutionCue(selfId, reveal.winnerIds, reveal.loserIds, personalWon)
		if cue ~= nil then
			play(cue)
		end
	end)
end

-- CONTROLLER ---------------------------------------------------------

local AudioController: Loader.Controller = {
	name = "AudioController",
	dependencies = { "SettingsController" },
}

-- Public: plays a one-shot cue by AudioLogic.CUES key. For a moment this
-- controller doesn't already hear about from the network.
function AudioController.play(cueId: string, at: BasePart?)
	play(cueId, at)
end

function AudioController:init()
	poolFolder = Instance.new("Folder")
	poolFolder.Name = "AudioPool"
	poolFolder.Parent = SoundService
	soundGroup("Music")
	soundGroup("SFX")

	Net.onClientEvent("RoundState", onRoundState)

	Net.onClientEvent("QueueState", function(payload: any)
		local status = if type(payload) == "table" then payload.status else nil
		if status == "MatchFound" and queueStatus ~= "MatchFound" then
			play("QueueReady")
		end
		queueStatus = status
	end)

	Net.onClientEvent("TaskChallenge", function()
		play("TaskStart")
	end)
	Net.onClientEvent("TaskResult", function(payload: any)
		if type(payload) == "table" then
			play(if payload.success == true then "TaskSuccess" else "TaskFail")
		end
	end)

	Net.onClientEvent("TaskQualificationResult", function(payload: any)
		if type(payload) ~= "table" or type(payload.ranked) ~= "table" or type(payload.qualifiers) ~= "table" then
			return
		end
		local rankedIds = {}
		for _, entry in payload.ranked do
			if type(entry) == "table" and type(entry.playerId) == "number" then
				table.insert(rankedIds, entry.playerId)
			end
		end
		local cue = AudioLogic.qualificationCue(selfId, rankedIds, payload.qualifiers)
		selfQualified = cue == "Qualified"
		if cue ~= nil then
			play(cue)
		end
	end)

	Net.onClientEvent("PowerUpInventoryChanged", function(payload: any)
		local inventory = if type(payload) == "table" then payload.inventory else nil
		local count = if type(inventory) == "table" then #inventory else 0
		if count > inventoryCount then
			play("PowerUpPickup")
		end
		inventoryCount = count
	end)
	Net.onClientEvent("PowerUpUseResult", function(payload: any)
		if type(payload) == "table" and payload.success == true then
			play("PowerUpUsedByYou")
		end
	end)
	Net.onClientEvent("StatusEffectsChanged", function(payload: any)
		local effects = if type(payload) == "table" and type(payload.effects) == "table" then payload.effects else {}
		local keys, hit = AudioLogic.newDebuffs(debuffKeys, effects)
		debuffKeys = keys
		if hit then
			play("PowerUpHitYou")
		end
	end)

	Net.onClientEvent("DecisionLockedIn", function(payload: any)
		if type(payload) == "table" and type(payload.playerId) == "number" then
			play(if payload.playerId == selfId then "LockIn" else "OtherLockIn")
		end
	end)
	Net.onClientEvent("DecisionReveal", onReveal)
	Net.onClientEvent("DecisionPersonalResult", function(payload: any)
		local personal = DecisionLogic.parsePersonal(payload)
		if personal ~= nil then
			personalWon = personal.won
		end
	end)
end

function AudioController:start()
	-- No RoundState yet means the hub (it never runs a round).
	setBed(AudioLogic.bedFor(roundState))
	RunService.Heartbeat:Connect(onHeartbeat)
end

return AudioController
