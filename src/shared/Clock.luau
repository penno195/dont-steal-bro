--!strict
-- Synchronised countdown helper (P2-2). RoundService (P2-1) replicates one
-- small payload per state - `{state, endsAt}`, `endsAt` an absolute time
-- from workspace:GetServerTimeNow() - specifically so the client never
-- needs a per-second tick from the server: it renders its own countdown
-- locally from that single number. This module is that client-side half.
--
-- WHY EVERY FUNCTION HERE TAKES `now`, RATHER THAN READING A CLOCK ITSELF:
-- testing-conventions.md rule 3 ("take a clock, don't read one" - see
-- Net.tryConsume, ProfileLogic, Validate for the same shape). secondsRemaining
-- and both formatters take `now`/`secondsRemaining` as plain numbers, so
-- they're callable from a Lune test (tests/Clock.spec.luau) with no real
-- Roblox engine and no waiting on a real clock. Clock.now() and Clock.
-- subscribe() below are the only two functions that touch a live Roblox
-- API, and they're kept separate and thin for exactly that reason -
-- nothing above them in this file ever calls `game` or `workspace` at
-- module scope, so requiring this module still works cleanly under Lune.
--
-- WHY workspace:GetServerTimeNow(), NEVER tick() OR os.time():
-- GetServerTimeNow() is the one client-side read that's already
-- synchronised to the server's clock (Roblox maintains the offset for
-- you under the hood). tick() is wall-clock-since-this-client-booted and
-- os.time() is this device's own local clock - a countdown built from
-- either drifts by however far this player's client happens to be off
-- from the server, and stutters or jumps for a player who alt-tabs and
-- gets throttled. Every number this module ever renders must trace back
-- to a workspace:GetServerTimeNow() read on THIS client, taken against
-- the server's absolute `endsAt` - never a duration counted down locally.
--
-- WHY A LATE JOINER NEEDS NO SPECIAL-CASE CODE HERE:
-- RoundService fires the current `{state, endsAt}` straight at a player
-- on PlayerAdded (see its own header comment). By the time this module
-- ever sees an `endsAt`, "joined on time" and "joined 40 seconds late"
-- already look identical: just a smaller (or already-negative)
-- `secondsRemaining`. secondsRemaining/formatMMSS/formatFinalCountdown
-- all handle a past deadline as a plain input value, not a special case.

local Clock = {}

-- The only place a REAL clock is read. A one-line wrapper, never called
-- from anywhere else in this module, so a caller (a controller) has one
-- obvious function to reach for "now" and every pure function below stays
-- free of Roblox API calls (testing-conventions.md rule 1).
function Clock.now(): number
	return workspace:GetServerTimeNow()
end

-- Pure: seconds remaining until `endsAt`, given `now`. Deliberately NOT
-- clamped to 0 - negative means "past the deadline," and how far past is
-- sometimes useful to a caller (e.g. deciding whether a state's timer
-- should already have elapsed). formatMMSS/formatFinalCountdown below are
-- what clamp, since clamping is a display concern, not a math one.
function Clock.secondsRemaining(endsAt: number, now: number): number
	return endsAt - now
end

-- Pure: "mm:ss" for a HUD countdown. Clamped to 0 for a past or exactly-hit
-- deadline - "correct behaviour when the end time is in the past" (P2-2's
-- own requirement) means a steady "00:00," never a negative or blank
-- string. Rounds to the nearest second rather than flooring, so a display
-- doesn't visibly sit on "0:59" for the first sub-second sliver of a
-- fresh 60-second timer.
function Clock.formatMMSS(secondsRemaining: number): string
	local wholeSeconds = math.max(0, math.floor(secondsRemaining + 0.5))
	local minutes = math.floor(wholeSeconds / 60)
	local seconds = wholeSeconds % 60
	return string.format("%d:%02d", minutes, seconds)
end

-- Pure: the short "3"/"2"/"1" style final countdown for the last few
-- seconds before a state ends (Intro -> Race is the main use). Returns
-- nil outside the window - past the deadline, or still further out than
-- `thresholdSeconds` (default 3) - so a caller can tell "show nothing"
-- apart from "show 0." Rounds UP (2.4s left still reads "3"), the same
-- way a real analogue countdown ticks over on the way down, not the way
-- up.
function Clock.formatFinalCountdown(secondsRemaining: number, thresholdSeconds: number?): string?
	local threshold = thresholdSeconds or 3
	if secondsRemaining <= 0 then
		return nil
	end
	local wholeSeconds = math.ceil(secondsRemaining)
	if wholeSeconds > threshold then
		return nil
	end
	return tostring(wholeSeconds)
end

-- Roblox-touching: calls `callback(secondsRemaining)` against `endsAt`
-- either every frame ("frame") or once per whole second ("second," the
-- default - the common case for a HUD label, to avoid re-rendering text
-- 60 times a second for a number that only visibly changes once a
-- second). Fetches RunService inside the function, never at module
-- scope, so this module still requires cleanly under Lune (testing-
-- conventions.md rule 1) - nothing above this point in the file touches
-- `game` at all. Returns an unsubscribe function; does not stop itself
-- once `endsAt` is passed, since a caller may still want callbacks for a
-- state with no fixed end (RoundService's `duration == nil` states) or
-- may want to keep observing "how far past deadline" - call the returned
-- function to stop.
function Clock.subscribe(
	endsAt: number,
	callback: (secondsRemaining: number) -> (),
	mode: ("frame" | "second")?
): () -> ()
	local RunService = game:GetService("RunService")
	local resolvedMode = mode or "second"
	local lastWholeSecond: number? = nil

	local connection = RunService.Heartbeat:Connect(function()
		local remaining = Clock.secondsRemaining(endsAt, Clock.now())
		if resolvedMode == "frame" then
			callback(remaining)
			return
		end
		local whole = math.ceil(remaining)
		if whole ~= lastWholeSecond then
			lastWholeSecond = whole
			callback(remaining)
		end
	end)

	return function()
		connection:Disconnect()
	end
end

return Clock
