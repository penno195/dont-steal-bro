--!strict
-- The player's own preferences (P6-6's settings screen): the one shape,
-- its defaults, its bounds, and the one function that turns anything -
-- a stored profile table, a client intent - into a valid value.
--
-- Shared because both halves need the SAME answer: the server sanitises
-- what it stores (a client can send anything - Ground Rule 1), and the
-- client sanitises what it renders before the server's copy arrives.
-- Pure and require-free, so it runs under Lune (tests/MenuScreens.spec).
--
-- None of these settings is secret or competitive. They're still
-- stored server-side, in the profile, for one reason: Roblox gives a
-- client no persistent local storage, so a preference that lived only
-- on the client would reset on every join. The server's only job is to
-- keep the stored value in bounds.

local SettingsLogic = {}

export type PlayerSettings = {
	reducedMotion: boolean, -- ORs with the OS toggle (Env.reducedMotion); can't turn the OS one off
	musicVolume: number, -- 0..1
	sfxVolume: number, -- 0..1
	voiceEnabled: boolean, -- the player's own mic in the Studio; hearing others is Roblox's setting, not ours
	hudScale: number, -- multiplier on UIScaleController's computed scale
	colorBlindMode: boolean,
	-- First-round tips (P6-8, docs/onboarding.md). On for a new player;
	-- OnboardingController switches it off after the first full round,
	-- and the Settings toggle switches it back on to replay them. A
	-- stored profile from before this field gets the default, so every
	-- existing player sees the tips once.
	tips: boolean,
}

-- HUD scale only goes UP from the computed scale. The computed scale is
-- what P6-1 sizes every touch target against (44pt after scaling), so a
-- multiplier below 1 would let a player shrink a button under the
-- minimum P6-7 audits for. A player who wants a smaller HUD is asking
-- for something that breaks thumbs; a player who wants a bigger one
-- (low vision, a large phone held far away) loses nothing.
SettingsLogic.HUD_SCALE_MIN = 1
SettingsLogic.HUD_SCALE_MAX = 1.3
SettingsLogic.HUD_SCALE_STEP = 0.05
SettingsLogic.VOLUME_STEP = 0.05

-- TEXT SCALING (P6-8). Roblox's own accessibility setting
-- (GuiService.PreferredTextSize) raises the HUD scale the same way
-- Roblox's reduced-motion toggle raises ours: it can only add to the
-- player's choice, never lower it. It goes through the HUD scale rather
-- than the type sizes because every label is TextScaled inside a fixed
-- box - a bigger MaxTextSize does nothing to text that already fills its
-- box, and a bigger MinTextSize just clips it. Scaling the whole UI
-- grows the boxes with the text, so nothing overflows. Capped at
-- HUD_SCALE_MAX, the largest scale every screen was laid out for.
-- Keyed by Enum.PreferredTextSize names; unknown names (a future
-- enum item) count as Medium.
SettingsLogic.SYSTEM_TEXT_SCALE = table.freeze({
	Medium = 1,
	Large = 1.1,
	Larger = 1.2,
	Largest = 1.3,
} :: { [string]: number })

-- The multiplier UIScaleController applies: the larger of the player's
-- HUD size and Roblox's text size, within the HUD scale bounds.
function SettingsLogic.effectiveHudScale(playerScale: number, systemTextSize: string): number
	local system = SettingsLogic.SYSTEM_TEXT_SCALE[systemTextSize] or 1
	return math.clamp(math.max(playerScale, system), SettingsLogic.HUD_SCALE_MIN, SettingsLogic.HUD_SCALE_MAX)
end

function SettingsLogic.defaults(): PlayerSettings
	return {
		reducedMotion = false,
		musicVolume = 0.6,
		sfxVolume = 0.8,
		voiceEnabled = true,
		hudScale = 1,
		colorBlindMode = false,
		tips = true,
	}
end

-- Snap to a step and clamp, so a slider dragged to 0.6180339 stores 0.6
-- and two devices agree on what "the same setting" is. NaN (x ~= x)
-- falls back rather than surviving a clamp, which it would.
local function stepped(value: any, lo: number, hi: number, step: number, fallback: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	local snapped = math.floor(value / step + 0.5) * step
	-- Round off the float noise the multiply leaves (0.15000000000000002).
	snapped = math.floor(snapped * 1000 + 0.5) / 1000
	return math.clamp(snapped, lo, hi)
end

local function bool(value: any, fallback: boolean): boolean
	return if type(value) == "boolean" then value else fallback
end

-- `raw` read field by field, with every missing or malformed field
-- taking `d`'s value instead.
local function sanitizeOver(raw: any, d: PlayerSettings): PlayerSettings
	if type(raw) ~= "table" then
		return table.clone(d)
	end
	return {
		reducedMotion = bool(raw.reducedMotion, d.reducedMotion),
		musicVolume = stepped(raw.musicVolume, 0, 1, SettingsLogic.VOLUME_STEP, d.musicVolume),
		sfxVolume = stepped(raw.sfxVolume, 0, 1, SettingsLogic.VOLUME_STEP, d.sfxVolume),
		voiceEnabled = bool(raw.voiceEnabled, d.voiceEnabled),
		hudScale = stepped(
			raw.hudScale,
			SettingsLogic.HUD_SCALE_MIN,
			SettingsLogic.HUD_SCALE_MAX,
			SettingsLogic.HUD_SCALE_STEP,
			d.hudScale
		),
		colorBlindMode = bool(raw.colorBlindMode, d.colorBlindMode),
		tips = bool(raw.tips, d.tips),
	}
end

-- Anything -> a complete, in-bounds PlayerSettings. Unknown keys are
-- dropped, missing or malformed ones take the default. Never errors: a
-- corrupted stored table should cost a player their preferences, not
-- their session.
function SettingsLogic.sanitize(raw: any): PlayerSettings
	return sanitizeOver(raw, SettingsLogic.defaults())
end

-- Applies a partial change on top of `current`. A malformed patch field
-- keeps the CURRENT value, not the default - a bad slider packet
-- shouldn't silently reset a volume the player set yesterday. `current`
-- is trusted to be sanitised already (it came from this module).
function SettingsLogic.apply(current: PlayerSettings, patch: any): PlayerSettings
	local merged: { [string]: any } = table.clone(current :: any)
	if type(patch) == "table" then
		for key, value in patch do
			if merged[key] ~= nil then
				merged[key] = value
			end
		end
	end
	return sanitizeOver(merged, current)
end

function SettingsLogic.equal(a: PlayerSettings, b: PlayerSettings): boolean
	for key, value in a :: any do
		if (b :: any)[key] ~= value then
			return false
		end
	end
	return true
end

return SettingsLogic
