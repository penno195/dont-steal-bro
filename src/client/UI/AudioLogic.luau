--!strict
-- The audio layer's pure half (P8-3): the cue table, the ducking
-- envelope, the voice budget, race-music intensity, and the reveal's
-- sound timeline. No Roblox API and no requires, so every rule here runs
-- headlessly under Lune. AudioController is the only thing that turns
-- these answers into Sound instances. docs/audio-and-feel.md has the
-- emotional brief each cue is written against.
--
-- ADDING A CUE is one row in CUES plus one call to AudioController.play
-- from whatever moment triggers it. Asset ids are PLACEHOLDERS
-- ("rbxassetid://0") until sound design lands; the controller skips a
-- placeholder silently, so the game is playable with no audio at all.

local AudioLogic = {}

export type Category = "Music" | "SFX"

-- How hard, and for how long, a cue pushes the music down. `level` is the
-- music multiplier at full duck (0.2 = music at 20%). Attack/release are
-- linear ramps in seconds; `hold` is the time spent at full duck between
-- them. A cue with no duck leaves the music alone.
export type DuckDef = { level: number, attack: number, hold: number, release: number }

export type CueDef = {
	assetId: string,
	category: Category,
	volume: number, -- 0..1, multiplied by the category's SoundGroup (the player's slider)
	looped: boolean,
	-- Spatial cues sit on a part in the world and fall off with distance;
	-- 2D cues play in the player's ears. Only things the player should
	-- LOCATE are spatial. Everything about the player's own state is 2D:
	-- on a phone speaker, a spatial cue behind the camera is simply lost.
	-- No cue is spatial yet - the obvious candidate, a rival's station
	-- finishing across the room, would need the station id in
	-- TaskProgress, which is counts-only on purpose (it would hand every
	-- client every rival's route). docs/audio-and-feel.md §2.
	spatial: boolean,
	-- Voice-budget rank. Higher survives. 100 = must never be dropped.
	priority: number,
	-- Minimum seconds between two plays of the same cue. Stops a burst of
	-- server events turning into a wall of identical sounds.
	cooldown: number,
	duck: DuckDef?,
}

export type Bed = "Hub" | "Race" | "Studio" | "None"

AudioLogic.PLACEHOLDER_ASSET = "rbxassetid://0"

-- How many one-shot SFX may sound at once. PLACEHOLDER until measured on
-- the reference Android device (perf-budget.md); the reasoning behind 8
-- is in docs/audio-and-feel.md §4. Music beds are budgeted separately
-- (at most three loops: a bed, the race tension layer, and a crossfade
-- tail) and never count against this.
AudioLogic.MAX_SFX_VOICES = 8

-- Seconds a music bed takes to fade in or out when the bed changes.
AudioLogic.BED_FADE = 1.5

local function cue(def: CueDef): CueDef
	return table.freeze(def)
end

local P = AudioLogic.PLACEHOLDER_ASSET

AudioLogic.CUES = table.freeze({
	-- Beds (Music, looped). RaceBed's asset is only the fallback: the map's
	-- own MapDef.musicTrackId wins when it's set (resolveRaceBed).
	HubAmbience = cue({
		assetId = P,
		category = "Music",
		volume = 0.5,
		looped = true,
		spatial = false,
		priority = 100,
		cooldown = 0,
	}),
	RaceBed = cue({
		assetId = P,
		category = "Music",
		volume = 0.55,
		looped = true,
		spatial = false,
		priority = 100,
		cooldown = 0,
	}),
	-- A percussion/pulse stem layered over any race bed; its volume is the
	-- intensity (raceIntensity). One stem for every map, so a new map
	-- never needs its own "tense" mix.
	RaceTension = cue({
		assetId = P,
		category = "Music",
		volume = 0.6,
		looped = true,
		spatial = false,
		priority = 100,
		cooldown = 0,
	}),
	StudioBed = cue({
		assetId = P,
		category = "Music",
		volume = 0.45,
		looped = true,
		spatial = false,
		priority = 100,
		cooldown = 0,
	}),

	-- Hub.
	QueueReady = cue({
		assetId = P,
		category = "SFX",
		volume = 0.8,
		looped = false,
		spatial = false,
		priority = 80,
		cooldown = 1,
		duck = { level = 0.5, attack = 0.05, hold = 0.6, release = 0.4 },
	}),

	-- Race.
	TimerTick = cue({
		assetId = P,
		category = "SFX",
		volume = 0.5,
		looped = false,
		spatial = false,
		priority = 60,
		cooldown = 0.5,
	}),
	TaskStart = cue({
		assetId = P,
		category = "SFX",
		volume = 0.6,
		looped = false,
		spatial = false,
		priority = 50,
		cooldown = 0.3,
	}),
	TaskSuccess = cue({
		assetId = P,
		category = "SFX",
		volume = 0.9,
		looped = false,
		spatial = false,
		priority = 85,
		cooldown = 0.3,
		duck = { level = 0.6, attack = 0.03, hold = 0.3, release = 0.5 },
	}),
	TaskFail = cue({
		assetId = P,
		category = "SFX",
		volume = 0.75,
		looped = false,
		spatial = false,
		priority = 70,
		cooldown = 0.3,
	}),
	PowerUpPickup = cue({
		assetId = P,
		category = "SFX",
		volume = 0.7,
		looped = false,
		spatial = false,
		priority = 60,
		cooldown = 0.2,
	}),
	-- BY you and ON you have to be told apart with eyes closed: one is a
	-- bright rising whoosh (you did it), the other a low, detuned hit
	-- (it was done to you). Different pitch register AND envelope, not
	-- just different samples. See docs/audio-and-feel.md §2.
	PowerUpUsedByYou = cue({
		assetId = P,
		category = "SFX",
		volume = 0.8,
		looped = false,
		spatial = false,
		priority = 75,
		cooldown = 0.2,
	}),
	PowerUpHitYou = cue({
		assetId = P,
		category = "SFX",
		volume = 0.9,
		looped = false,
		spatial = false,
		priority = 90,
		cooldown = 0.25,
		duck = { level = 0.55, attack = 0.02, hold = 0.25, release = 0.4 },
	}),
	Qualified = cue({
		assetId = P,
		category = "SFX",
		volume = 1,
		looped = false,
		spatial = false,
		priority = 95,
		cooldown = 2,
		duck = { level = 0.25, attack = 0.05, hold = 1.2, release = 0.8 },
	}),
	NotQualified = cue({
		assetId = P,
		category = "SFX",
		volume = 0.7,
		looped = false,
		spatial = false,
		priority = 90,
		cooldown = 2,
		duck = { level = 0.4, attack = 0.1, hold = 0.8, release = 0.8 },
	}),

	-- Decision Studio.
	LockIn = cue({
		assetId = P,
		category = "SFX",
		volume = 0.9,
		looped = false,
		spatial = false,
		priority = 95,
		cooldown = 0.5,
		duck = { level = 0.5, attack = 0.02, hold = 0.3, release = 0.5 },
	}),
	-- Someone else locked in: quieter, so your own lock stays the loud one.
	OtherLockIn = cue({
		assetId = P,
		category = "SFX",
		volume = 0.5,
		looped = false,
		spatial = false,
		priority = 60,
		cooldown = 0.1,
	}),
	-- The reveal. Every one of these ducks hard: the brief says the reveal
	-- is never buried under music, and the bed is ducked for the whole
	-- sequence on top of that (revealDuck).
	RevealRiser = cue({
		assetId = P,
		category = "SFX",
		volume = 0.8,
		looped = false,
		spatial = false,
		priority = 100,
		cooldown = 0,
		duck = { level = 0.3, attack = 0.2, hold = 0.8, release = 0.2 },
	}),
	RevealCard = cue({
		assetId = P,
		category = "SFX",
		volume = 1,
		looped = false,
		spatial = false,
		priority = 100,
		cooldown = 0,
		duck = { level = 0.2, attack = 0.02, hold = 0.5, release = 0.3 },
	}),
	RevealOutcome = cue({
		assetId = P,
		category = "SFX",
		volume = 1,
		looped = false,
		spatial = false,
		priority = 100,
		cooldown = 0,
		duck = { level = 0.1, attack = 0.02, hold = 1.0, release = 0.5 },
	}),
	Win = cue({
		assetId = P,
		category = "SFX",
		volume = 1,
		looped = false,
		spatial = false,
		priority = 100,
		cooldown = 0,
		duck = { level = 0.15, attack = 0.05, hold = 2.5, release = 1.5 },
	}),
	Loss = cue({
		assetId = P,
		category = "SFX",
		volume = 0.9,
		looped = false,
		spatial = false,
		priority = 100,
		cooldown = 0,
		duck = { level = 0.15, attack = 0.1, hold = 2.5, release = 1.5 },
	}),
})

function AudioLogic.isPlaceholder(assetId: string?): boolean
	return assetId == nil or assetId == "" or assetId == AudioLogic.PLACEHOLDER_ASSET
end

-- The map's own track when it has a real one, else the shared fallback.
function AudioLogic.resolveRaceBed(mapMusicId: string?): string
	if mapMusicId ~= nil and not AudioLogic.isPlaceholder(mapMusicId) then
		return mapMusicId
	end
	return AudioLogic.CUES.RaceBed.assetId
end

-- BEDS ---------------------------------------------------------------

-- Which bed a round state plays. nil (no RoundState seen yet) is the hub:
-- the hub place never runs a round. Results and Cleanup play no bed -
-- the win/loss resolution owns the air, then silence before the next
-- round's bed fades in.
local BED_FOR_STATE: { [string]: Bed } = {
	WaitingForPlayers = "Hub",
	Loading = "Race",
	Intro = "Race",
	Race = "Race",
	Qualified = "Race",
	DecisionStudio = "Studio",
	Results = "None",
	Cleanup = "None",
}

function AudioLogic.bedFor(state: string?): Bed
	if state == nil then
		return "Hub"
	end
	return BED_FOR_STATE[state] or "None"
end

-- DUCKING ------------------------------------------------------------

-- The music multiplier one duck contributes at `now`: 1 before it
-- starts and after it ends, `level` while held, linear ramps between.
function AudioLogic.duckEnvelope(duck: DuckDef, startedAt: number, now: number): number
	local t = now - startedAt
	if t < 0 then
		return 1
	end
	if t < duck.attack then
		return 1 - (1 - duck.level) * (t / duck.attack)
	end
	t -= duck.attack
	if t < duck.hold then
		return duck.level
	end
	t -= duck.hold
	if t < duck.release then
		return duck.level + (1 - duck.level) * (t / duck.release)
	end
	return 1
end

function AudioLogic.duckLength(duck: DuckDef): number
	return duck.attack + duck.hold + duck.release
end

export type ActiveDuck = { duck: DuckDef, startedAt: number }

-- Overlapping ducks don't multiply (two cues at 0.5 would bury the music
-- at 0.25); the deepest one wins.
function AudioLogic.duckLevel(active: { ActiveDuck }, now: number): number
	local level = 1
	for _, entry in active do
		level = math.min(level, AudioLogic.duckEnvelope(entry.duck, entry.startedAt, now))
	end
	return level
end

-- Drops ducks that have fully released. Returns a new list.
function AudioLogic.pruneDucks(active: { ActiveDuck }, now: number): { ActiveDuck }
	local kept = {}
	for _, entry in active do
		if now - entry.startedAt < AudioLogic.duckLength(entry.duck) then
			table.insert(kept, entry)
		end
	end
	return kept
end

-- The reveal's own blanket duck, covering the whole card sequence from
-- revealAt to the result panel. `length` is DecisionLogic.revealLength.
function AudioLogic.revealDuck(length: number): DuckDef
	return { level = 0.35, attack = 0.5, hold = math.max(0, length - 0.5), release = 1.5 }
end

-- VOICE BUDGET -------------------------------------------------------

export type Voice = { priority: number, startedAt: number }
export type Admit = "play" | "steal" | "drop"

-- Can a new SFX of `priority` start, given the voices already sounding?
-- Under budget: play. Full: steal the weakest voice (lowest priority,
-- oldest first) if the newcomer outranks it, else drop the newcomer.
-- Equal priority never steals - a burst of the same cue shouldn't keep
-- cutting itself off mid-sound. Returns the index to steal alongside.
function AudioLogic.admit(voices: { Voice }, priority: number, max: number): (Admit, number?)
	if #voices < max then
		return "play", nil
	end
	local weakest: number? = nil
	for i, v in voices do
		local w = if weakest ~= nil then voices[weakest] else nil
		if w == nil or v.priority < w.priority or (v.priority == w.priority and v.startedAt < w.startedAt) then
			weakest = i
		end
	end
	if weakest ~= nil and voices[weakest].priority < priority then
		return "steal", weakest
	end
	return "drop", nil
end

function AudioLogic.offCooldown(lastPlayedAt: number?, def: CueDef, now: number): boolean
	return lastPlayedAt == nil or now - lastPlayedAt >= def.cooldown
end

-- RACE INTENSITY -----------------------------------------------------

-- The tension stem fades in across TENSION_START..TENSION_FULL seconds
-- left, and the bed's pitch lifts a touch over the last SPEED_WINDOW.
-- The final TICK_WINDOW seconds get a tick per whole second.
AudioLogic.TENSION_START = 60
AudioLogic.TENSION_FULL = 20
AudioLogic.SPEED_WINDOW = 20
AudioLogic.MAX_SPEED = 1.05
AudioLogic.TICK_WINDOW = 10

export type Intensity = { tier: number, tension: number, playbackSpeed: number }

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

function AudioLogic.raceIntensity(secondsLeft: number): Intensity
	local tension =
		clamp01((AudioLogic.TENSION_START - secondsLeft) / (AudioLogic.TENSION_START - AudioLogic.TENSION_FULL))
	local speedT = clamp01((AudioLogic.SPEED_WINDOW - secondsLeft) / AudioLogic.SPEED_WINDOW)
	local tier = if secondsLeft <= AudioLogic.TICK_WINDOW
		then 3
		elseif secondsLeft <= AudioLogic.TENSION_FULL then 2
		elseif secondsLeft <= AudioLogic.TENSION_START then 1
		else 0
	return {
		tier = tier,
		tension = tension,
		playbackSpeed = 1 + (AudioLogic.MAX_SPEED - 1) * speedT,
	}
end

-- The whole second to tick on, or nil. `lastTicked` is the last second
-- already ticked, so a slow frame never ticks twice and a skipped frame
-- ticks the second it lands on rather than replaying the ones it missed.
function AudioLogic.tickDue(secondsLeft: number, lastTicked: number?): number?
	if secondsLeft <= 0 or secondsLeft > AudioLogic.TICK_WINDOW then
		return nil
	end
	local second = math.ceil(secondsLeft)
	if lastTicked ~= nil and second >= lastTicked then
		return nil
	end
	return second
end

-- REVEAL TIMELINE ----------------------------------------------------

export type RevealTiming = { lead: number, cardGap: number, outcomeAfter: number, resultAfter: number }
export type ScheduledCue = { at: number, cue: string }

-- Seconds after revealAt for each reveal sound, lined up with
-- DecisionLogic.revealStep so a card's sound lands on the frame it turns.
-- Win/Loss are NOT here: they depend on who you are, so the controller
-- plays resolutionCue's answer at `resultAt`.
function AudioLogic.revealSchedule(seats: number, timing: RevealTiming): ({ ScheduledCue }, number)
	local out: { ScheduledCue } = { { at = 0, cue = "RevealRiser" } }
	for i = 0, math.max(0, seats - 1) do
		table.insert(out, { at = timing.lead + i * timing.cardGap, cue = "RevealCard" })
	end
	local outcomeAt = timing.lead + math.max(0, seats - 1) * timing.cardGap + timing.outcomeAfter
	table.insert(out, { at = outcomeAt, cue = "RevealOutcome" })
	return out, outcomeAt + timing.resultAfter
end

-- The resolution for this client: Win or Loss for a finalist, nothing for
-- a spectator (the room-wide RevealOutcome already told them). The
-- server's personal result wins over the reveal's id lists when both
-- arrived; either is enough on its own.
function AudioLogic.resolutionCue(
	selfId: number,
	winnerIds: { number }?,
	loserIds: { number }?,
	personalWon: boolean?
): string?
	if personalWon ~= nil then
		return if personalWon then "Win" else "Loss"
	end
	if winnerIds ~= nil and table.find(winnerIds, selfId) ~= nil then
		return "Win"
	end
	if loserIds ~= nil and table.find(loserIds, selfId) ~= nil then
		return "Loss"
	end
	return nil
end

-- QUALIFICATION ------------------------------------------------------

-- Qualified or NotQualified for a racer, nothing for someone who wasn't
-- in the race (a late joiner watching). `rankedIds` is every racer's id
-- from TaskQualificationResult.ranked.
function AudioLogic.qualificationCue(selfId: number, rankedIds: { number }, qualifiers: { number }): string?
	if table.find(qualifiers, selfId) ~= nil then
		return "Qualified"
	end
	if table.find(rankedIds, selfId) ~= nil then
		return "NotQualified"
	end
	return nil
end

-- POWER-UPS ON YOU ---------------------------------------------------

export type EffectEntry = { id: string, kind: string?, expiresAt: number? }

-- A debuff counts as "new" when its id+expiry pair wasn't in the last
-- StatusEffectsChanged: a re-applied Slow Field has a later expiry, so it
-- hits again. Buffs are skipped - your own Sprint Boost is already heard
-- as PowerUpUsedByYou. Returns the new key set and whether anything hit.
function AudioLogic.newDebuffs(
	previous: { [string]: boolean },
	effects: { EffectEntry }
): ({ [string]: boolean }, boolean)
	local keys: { [string]: boolean } = {}
	local hit = false
	for _, e in effects do
		if e.kind == "Buff" then
			continue
		end
		local key = e.id .. "@" .. tostring(e.expiresAt or 0)
		keys[key] = true
		if not previous[key] then
			hit = true
		end
	end
	return keys, hit
end

return AudioLogic
