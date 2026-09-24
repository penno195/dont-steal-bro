--!strict
-- Game feel's pure half (P8-3): the four moments that get a physical
-- punch, their concrete numbers, the reduced-motion variant of each, and
-- the curves FeelController samples every frame. No Roblox API and no
-- requires - FeelController does the camera, animation and particle
-- work. The brief behind each number is docs/audio-and-feel.md §3.
--
-- The four moments (the task's own list): finishing a task, qualifying,
-- locking in a choice, and the reveal. Reveal has two beats: a small one
-- per card and the big one on the outcome. Nothing else gets a punch - if
-- everything shakes, nothing does.

local FeelLogic = {}

export type Moment = "TaskComplete" | "Qualified" | "LockIn" | "RevealCard" | "RevealOutcome"

-- Camera shake through Humanoid.CameraOffset, in studs. `frequency` is
-- Hz; the shake decays quadratically to zero over `duration`.
export type Shake = { amplitude: number, frequency: number, duration: number }
-- A UI element scales to `peak` over `attack` seconds, then settles back
-- to 1 over `release`. `channel` picks which element (Feel.attach).
export type Punch = { peak: number, attack: number, release: number }
-- A one-shot particle burst at the player's character. `count` particles;
-- `speed` is studs/second outward; `colorToken` names a Theme.color key.
export type Burst = { count: number, speed: number, lifetime: number, colorToken: string }
-- An opacity-only flash: the reduced-motion stand-in for shake and punch,
-- so the moment still lands without anything moving.
export type Flash = { transparency: number, duration: number, colorToken: string }

export type Spec = {
	shake: Shake?,
	-- Seconds the player's own character animations freeze. Local only:
	-- the server's simulation never stops, so this is presentation, never
	-- a gameplay pause (Ground Rule 1 - it gives no one an advantage).
	hitStop: number,
	punch: Punch?,
	burst: Burst?,
	flash: Flash?,
}

local FULL: { [Moment]: Spec } = {
	TaskComplete = {
		shake = { amplitude = 0.12, frequency = 18, duration = 0.18 },
		hitStop = 0.06,
		punch = { peak = 1.12, attack = 0.06, release = 0.22 },
		burst = { count = 18, speed = 14, lifetime = 0.5, colorToken = "success" },
	},
	Qualified = {
		shake = { amplitude = 0.3, frequency = 14, duration = 0.45 },
		hitStop = 0.12,
		punch = { peak = 1.2, attack = 0.08, release = 0.4 },
		burst = { count = 60, speed = 22, lifetime = 1.0, colorToken = "brand" },
	},
	LockIn = {
		shake = { amplitude = 0.08, frequency = 22, duration = 0.12 },
		hitStop = 0.05,
		punch = { peak = 1.08, attack = 0.05, release = 0.2 },
	},
	RevealCard = {
		shake = { amplitude = 0.1, frequency = 16, duration = 0.15 },
		hitStop = 0,
		punch = { peak = 1.06, attack = 0.05, release = 0.18 },
	},
	RevealOutcome = {
		shake = { amplitude = 0.35, frequency = 12, duration = 0.6 },
		hitStop = 0.15,
		punch = { peak = 1.15, attack = 0.08, release = 0.45 },
		burst = { count = 40, speed = 18, lifetime = 1.2, colorToken = "brand" },
	},
}

-- Reduced motion: no shake, no scale, no hit-stop (a frozen character is
-- itself a jolt). Each moment keeps a flash, and the big two keep a
-- quarter of their particles with no outward speed - a glow that fades
-- in place rather than a spray.
local REDUCED: { [Moment]: Spec } = {
	TaskComplete = { hitStop = 0, flash = { transparency = 0.75, duration = 0.25, colorToken = "success" } },
	Qualified = {
		hitStop = 0,
		flash = { transparency = 0.6, duration = 0.5, colorToken = "brand" },
		burst = { count = 15, speed = 0, lifetime = 1.0, colorToken = "brand" },
	},
	LockIn = { hitStop = 0, flash = { transparency = 0.8, duration = 0.2, colorToken = "success" } },
	RevealCard = { hitStop = 0, flash = { transparency = 0.85, duration = 0.15, colorToken = "ink" } },
	RevealOutcome = {
		hitStop = 0,
		flash = { transparency = 0.6, duration = 0.6, colorToken = "brand" },
		burst = { count = 10, speed = 0, lifetime = 1.2, colorToken = "brand" },
	},
}

for _, t in { FULL, REDUCED } do
	for _, spec in t do
		table.freeze(spec)
	end
	table.freeze(t)
end

FeelLogic.MOMENTS = table.freeze({ "TaskComplete", "Qualified", "LockIn", "RevealCard", "RevealOutcome" } :: { Moment })

function FeelLogic.spec(moment: Moment, reducedMotion: boolean): Spec
	return (if reducedMotion then REDUCED else FULL)[moment]
end

-- Which UI channel each moment punches (Feel.attach binds an element to a
-- channel): the HUD task bar, the placement card, the locked card, and
-- the reveal banner.
FeelLogic.CHANNEL = table.freeze({
	TaskComplete = "Tasks",
	Qualified = "Placement",
	LockIn = "Locked",
	RevealCard = "Reveal",
	RevealOutcome = "Reveal",
} :: { [Moment]: string })

-- CURVES -------------------------------------------------------------

-- Camera offset (x, y) in studs at `t` seconds into a shake. Two sines at
-- non-integer ratio so it doesn't read as a clean wobble, under a
-- quadratic decay so the first frame is the hardest. Deterministic: the
-- same t gives the same offset, which is what makes it testable.
function FeelLogic.shakeOffset(shake: Shake, t: number): (number, number)
	if t < 0 or t >= shake.duration then
		return 0, 0
	end
	local decay = (1 - t / shake.duration) ^ 2
	local w = 2 * math.pi * shake.frequency
	local x = math.sin(w * t) * shake.amplitude * decay
	local y = math.sin(w * 1.37 * t + 1.1) * shake.amplitude * 0.7 * decay
	return x, y
end

-- Scale multiplier at `t` seconds into a punch: ease-out up to the peak,
-- ease-in-out back to 1.
function FeelLogic.punchScale(punch: Punch, t: number): number
	if t <= 0 then
		return 1
	end
	local over = punch.peak - 1
	if t < punch.attack then
		local u = t / punch.attack
		return 1 + over * (1 - (1 - u) ^ 2)
	end
	t -= punch.attack
	if t < punch.release then
		local u = t / punch.release
		local eased = if u < 0.5 then 2 * u * u else 1 - ((-2 * u + 2) ^ 2) / 2
		return punch.peak - over * eased
	end
	return 1
end

-- Flash overlay transparency at `t`: jumps to `transparency`, fades to 1.
function FeelLogic.flashTransparency(flash: Flash, t: number): number
	if t < 0 or t >= flash.duration then
		return 1
	end
	return flash.transparency + (1 - flash.transparency) * (t / flash.duration)
end

-- Stacking. A second shake while one is running takes whichever is
-- stronger right now rather than adding - two task completions in a
-- row shouldn't sum into a camera quake.
function FeelLogic.stronger(ax: number, ay: number, bx: number, by: number): (number, number)
	if bx * bx + by * by > ax * ax + ay * ay then
		return bx, by
	end
	return ax, ay
end

return FeelLogic
