--!strict
-- The tutorial reward's "spin and win" reveal in the Hub (owner,
-- 2026-10-15), its pure half: when each tick of the spin lands and how
-- loud. No Roblox API, so it runs headlessly under Lune. PrizeReveal
-- draws it and MenuController plays the sounds on this timeline.
--
-- A prize wheel slowing down: ticks start fast and spread out, each
-- a little louder, and the prize shows on the beat where the next tick
-- would have been. Under them the RevealRiser builds to its hard stop,
-- which lands on that same beat.

local PrizeRevealLogic = {}

-- Seconds from the first tick to the reveal. RevealRiser's hard stop
-- is 3.0 s after it starts (4.1 s, played from its startAt 1.1 s), so
-- the riser started with the first tick stops dead on the reveal.
PrizeRevealLogic.SPIN = 3.0

-- The wheel's first and last gaps between ticks, in seconds.
PrizeRevealLogic.FIRST_GAP = 0.05
PrizeRevealLogic.LAST_GAP = 0.42

-- Tick volume, as a multiple of the cue's, from the first tick to the last.
PrizeRevealLogic.QUIET = 0.45
PrizeRevealLogic.LOUD = 1

export type Tick = { at: number, volume: number }

-- The spin's ticks, first at 0. `count` gaps grow geometrically from
-- FIRST_GAP to LAST_GAP and are then scaled so they add up to exactly
-- `spin`: the reveal is the beat after the last tick. Reduced motion
-- has no say here; a sound isn't motion.
function PrizeRevealLogic.ticks(spin: number?, count: number?): { Tick }
	local total = spin or PrizeRevealLogic.SPIN
	local n = count or 20
	assert(n >= 2, "a spin needs at least two gaps")
	local ratio = (PrizeRevealLogic.LAST_GAP / PrizeRevealLogic.FIRST_GAP) ^ (1 / (n - 1))
	local gaps: { number } = {}
	local sum = 0
	for i = 1, n do
		local gap = PrizeRevealLogic.FIRST_GAP * ratio ^ (i - 1)
		gaps[i] = gap
		sum += gap
	end
	local ticks: { Tick } = {}
	local at = 0
	for i = 1, n do
		local progress = (i - 1) / (n - 1)
		table.insert(ticks, {
			at = at,
			volume = PrizeRevealLogic.QUIET + (PrizeRevealLogic.LOUD - PrizeRevealLogic.QUIET) * progress,
		})
		at += gaps[i] * total / sum
	end
	return ticks
end

return PrizeRevealLogic
