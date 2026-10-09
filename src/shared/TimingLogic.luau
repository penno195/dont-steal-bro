--!strict
-- The Timing verb's shared sweep maths (tasks-catalogue.md #11 Reactor
-- Sync, #13 Airlock Cycle: "the same TaskHandlers timing-window helper
-- with a different speed/tolerance profile"). Pure, so the server
-- handler and the client view run the IDENTICAL function - the needle a
-- player sees is this function of time, not a separate animation - and
-- so it's unit-tested headlessly (Ground Rule 4).
--
-- Time is the attempt's own clock: seconds since its challenge went out
-- (the server's ctx.elapsedSeconds(); the client's time since the
-- challenge landed). A sweep is described by when it started on that
-- clock and how long one pass across the track (0 -> 1) takes; it then
-- bounces back and forth.
--
-- WHY THE STOP CARRIES A TIME (and what that does and doesn't allow):
-- the stop tap reaches the server one network trip after the player saw
-- the needle, and on a phone that trip is a big share of a sweep. So the
-- client says WHEN on the attempt clock it tapped, and the server
-- `clampStop`s that claim into the only window it could honestly be in:
-- no later than now, no earlier than MAX_LAG_SECONDS ago, and after the
-- previous stop. An exploiter can therefore pick their moment from the
-- last MAX_LAG_SECONDS, which a perfect-reaction bot reading the screen
-- could do anyway - no timing task can stop that, since the needle has
-- to be drawn. What it can't do is skip the sweep, stop in the future,
-- or replay a stop: the attempt still runs in real server time, behind
-- the shared plausible-time floor.

local TimingLogic = {}

-- The longest a stop claim may trail the server's clock: a slow mobile
-- round trip. A claim older than this is pulled forward to it.
TimingLogic.MAX_LAG_SECONDS = 0.5

-- Position on the track (0..1) at `at`, for a sweep that started at
-- `sweepStart` and takes `period` seconds per pass. Before the sweep
-- starts it rests at 0.
function TimingLogic.position(at: number, sweepStart: number, period: number): number
	if at <= sweepStart or period <= 0 then
		return 0
	end
	local x = ((at - sweepStart) / period) % 2
	return if x <= 1 then x else 2 - x
end

-- Whether `pos` is inside the band centred on `center`, `halfWidth` either side.
function TimingLogic.within(pos: number, center: number, halfWidth: number): boolean
	return math.abs(pos - center) <= halfWidth
end

-- The claimed stop time, forced into [now - MAX_LAG, now] and after the
-- previous accepted stop. Returns nil when no honest time is left (the
-- previous stop was already at or after `now`), so the stop is dropped.
function TimingLogic.clampStop(claimedAt: number, now: number, lastStopAt: number?): number?
	local at = math.clamp(claimedAt, now - TimingLogic.MAX_LAG_SECONDS, now)
	if lastStopAt ~= nil and at <= lastStopAt then
		if now <= lastStopAt then
			return nil
		end
		at = now
	end
	return at
end

return TimingLogic
