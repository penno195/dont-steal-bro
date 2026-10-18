--!strict
-- Daily challenges (payoff-loop step 8; design-decisions.md Q1's "a
-- payoff for every round" case): which three a player has today, what a
-- ranked round adds to them, what finishing one pays, and the free
-- reroll. Pure; DailyChallengeService (step 8b) supplies the profile
-- state, the UTC day key, the registry and the round's tally.
--
-- WHICH THREE: every enabled challenge is ranked by a hash of
-- "<userId>|<dayKey>|<id>", and the day's picks are taken from the top
-- of that ranking, skipping any that would put more than `maxWinPicks`
-- challenges needing a round win on the list. So the draw is the same
-- on every server and every rejoin that day, friends get different
-- ones, and adding a challenge file only moves the players it outranks.
--
-- THE REROLL swaps one unfinished challenge for the next one in the same
-- ranking that hasn't been drawn today, still under the win cap.
-- Progress on the swapped-out one is lost (Claude's call: the reroll is
-- for a challenge you don't want, not a way to bank progress).
-- `drawn` keeps every id handed out today, so a rerolled-away challenge
-- never comes back the same day.
--
-- WHAT COUNTS is decided by the caller: only ranked rounds reach
-- applyRound (owner, 2026-10-18: practice never counts, the way it
-- records no steals or shares).
--
-- Self-contained: no requires, no Roblox API calls, so it runs under
-- Lune (tests/DailyChallengeLogic.spec). The def and config types
-- restate the slices of Validate's types this module reads.

local DailyChallengeLogic = {}

export type Metric =
	"RoundsPlayed"
	| "TasksDone"
	| "StudioVisits"
	| "FirstPlaces"
	| "Hits"
	| "Wins"
	| "SharedAndWon"
	| "StoleAndWon"

export type Def = {
	id: string,
	enabled: boolean,
	displayName: string, -- may hold one "%d", filled with `target`
	metric: Metric,
	target: number,
	powerUpId: string?, -- Hits only: count only this power-up's hits
	coins: number,
	xp: number,
}

export type Config = {
	picksPerDay: number,
	maxWinPicks: number,
	rerollsPerDay: number,
	allDoneCoins: number,
	allDoneXp: number,
}

export type Slot = {
	id: string,
	progress: number, -- never past the def's target
	done: boolean, -- reached the target and paid
}

export type State = {
	day: string, -- PeriodKeys.dayKey's UTC day this list belongs to
	slots: { Slot },
	drawn: { string }, -- every id handed out today, picks and rerolls
	rerollsUsed: number,
	allDonePaid: boolean,
}

-- What one ranked round did, filled by the server from its own records
-- (TaskService, PowerUpService, the finale result). Nothing here comes
-- from a client.
export type RoundTally = {
	tasksDone: number,
	place: number?, -- race finish order, 1 = first
	reachedStudio: boolean,
	won: boolean, -- progressed from the Studio
	choice: ("Steal" | "Share")?, -- the locked Studio choice; nil if not a finalist
	hitsByPowerUp: { [string]: number }, -- power-ups landed on a rival, by power-up id
}

export type Payout = {
	completed: { string }, -- challenge ids finished by this round, slot order
	coins: number,
	xp: number,
	allDone: boolean, -- this round finished the whole list (bonus included above)
}

export type RerollRefusal = "NoRerolls" | "BadSlot" | "AlreadyDone" | "NoCandidate"

local WIN_METRICS: { [string]: boolean } = {
	Wins = true,
	SharedAndWon = true,
	StoleAndWon = true,
}

-- Whether a challenge can only be finished by winning a round. At most
-- `maxWinPicks` of these go on one day's list, so most of it is doable
-- by everyone (the roadmap's "most doable without winning").
function DailyChallengeLogic.needsWin(metric: Metric): boolean
	return WIN_METRICS[metric] == true
end

-- DailyHuntLogic.hash's 31-bit polynomial string hash, restated to stay
-- require-free. Same answer in Studio, on a live server and under Lune.
function DailyChallengeLogic.hash(text: string): number
	local h = 0
	for i = 1, #text do
		h = (h * 31 + string.byte(text, i)) % 2147483647
	end
	return h
end

-- The line a player reads: "Freeze %d players" -> "Freeze 5 players".
function DailyChallengeLogic.label(def: Def): string
	if string.find(def.displayName, "%d", 1, true) ~= nil then
		return (string.gsub(def.displayName, "%%d", tostring(def.target)))
	end
	return def.displayName
end

local function byId(defs: { Def }): { [string]: Def }
	local map: { [string]: Def } = {}
	for _, def in defs do
		map[def.id] = def
	end
	return map
end

-- Today's order for this player: every enabled challenge, best-ranked
-- first. Ties (vanishingly rare) break by id, so it's still total.
function DailyChallengeLogic.ranking(defs: { Def }, userId: number, dayKey: string): { Def }
	local ranked: { Def } = {}
	local score: { [string]: number } = {}
	for _, def in defs do
		if def.enabled then
			table.insert(ranked, def)
			score[def.id] = DailyChallengeLogic.hash(string.format("%d|%s|%s", userId, dayKey, def.id))
		end
	end
	table.sort(ranked, function(a: Def, b: Def): boolean
		if score[a.id] ~= score[b.id] then
			return score[a.id] < score[b.id]
		end
		return a.id < b.id
	end)
	return ranked
end

local function winCount(slots: { Slot }, map: { [string]: Def }, skip: number?): number
	local n = 0
	for i, slot in slots do
		local def = map[slot.id]
		if i ~= skip and def ~= nil and DailyChallengeLogic.needsWin(def.metric) then
			n += 1
		end
	end
	return n
end

local function copyState(state: State): State
	local slots: { Slot } = {}
	for i, slot in state.slots do
		slots[i] = { id = slot.id, progress = slot.progress, done = slot.done }
	end
	return {
		day = state.day,
		slots = slots,
		drawn = table.clone(state.drawn),
		rerollsUsed = state.rerollsUsed,
		allDonePaid = state.allDonePaid,
	}
end

-- The player's list for `dayKey`: `state` unchanged when it's already
-- today's, otherwise a fresh draw (the lazy daily reset, so nothing has
-- to run at midnight). Fewer than picksPerDay slots only if the registry
-- is short, which Validate refuses.
function DailyChallengeLogic.forDay(state: State?, defs: { Def }, config: Config, userId: number, dayKey: string): State
	if state ~= nil and state.day == dayKey then
		return state
	end

	local slots: { Slot } = {}
	local drawn: { string } = {}
	local wins = 0
	for _, def in DailyChallengeLogic.ranking(defs, userId, dayKey) do
		if #slots >= config.picksPerDay then
			break
		end
		local isWin = DailyChallengeLogic.needsWin(def.metric)
		if not isWin or wins < config.maxWinPicks then
			table.insert(slots, { id = def.id, progress = 0, done = false })
			table.insert(drawn, def.id)
			if isWin then
				wins += 1
			end
		end
	end

	return { day = dayKey, slots = slots, drawn = drawn, rerollsUsed = 0, allDonePaid = false }
end

-- Swaps slot `slotIndex` for the next undrawn challenge in today's
-- ranking. Returns the new state, or nil and why it was refused. The
-- caller has already brought `state` to today with forDay.
function DailyChallengeLogic.reroll(
	state: State,
	slotIndex: number,
	defs: { Def },
	config: Config,
	userId: number
): (State?, RerollRefusal?)
	if state.rerollsUsed >= config.rerollsPerDay then
		return nil, "NoRerolls"
	end
	local slot = state.slots[slotIndex]
	if slot == nil then
		return nil, "BadSlot"
	end
	if slot.done then
		return nil, "AlreadyDone"
	end

	local map = byId(defs)
	local winsElsewhere = winCount(state.slots, map, slotIndex)
	local used: { [string]: boolean } = {}
	for _, id in state.drawn do
		used[id] = true
	end

	for _, def in DailyChallengeLogic.ranking(defs, userId, state.day) do
		if used[def.id] then
			continue
		end
		if DailyChallengeLogic.needsWin(def.metric) and winsElsewhere >= config.maxWinPicks then
			continue
		end
		local after = copyState(state)
		after.slots[slotIndex] = { id = def.id, progress = 0, done = false }
		table.insert(after.drawn, def.id)
		after.rerollsUsed += 1
		return after, nil
	end
	return nil, "NoCandidate"
end

local function whole(value: number?): number
	if value == nil or value ~= value then
		return 0
	end
	return math.max(0, math.floor(value))
end

-- What one round adds to a challenge's count.
function DailyChallengeLogic.countFor(def: Def, tally: RoundTally): number
	local metric = def.metric
	if metric == "RoundsPlayed" then
		return 1
	elseif metric == "TasksDone" then
		return whole(tally.tasksDone)
	elseif metric == "StudioVisits" then
		return if tally.reachedStudio then 1 else 0
	elseif metric == "FirstPlaces" then
		return if tally.place == 1 then 1 else 0
	elseif metric == "Hits" then
		if def.powerUpId ~= nil then
			return whole(tally.hitsByPowerUp[def.powerUpId])
		end
		local total = 0
		for _, n in tally.hitsByPowerUp do
			total += whole(n)
		end
		return total
	elseif metric == "Wins" then
		return if tally.won then 1 else 0
	elseif metric == "SharedAndWon" then
		return if tally.won and tally.choice == "Share" then 1 else 0
	elseif metric == "StoleAndWon" then
		return if tally.won and tally.choice == "Steal" then 1 else 0
	end
	return 0
end

-- Adds one ranked round to today's list and says what it pays: each
-- challenge it finished, plus the all-done bonus the first time every
-- slot is finished. A challenge whose file was removed or disabled
-- mid-day counts nothing (it can still be rerolled). The caller has
-- already brought `state` to today with forDay.
function DailyChallengeLogic.applyRound(state: State, defs: { Def }, config: Config, tally: RoundTally): (State, Payout)
	local map = byId(defs)
	local after = copyState(state)
	local payout: Payout = { completed = {}, coins = 0, xp = 0, allDone = false }

	for _, slot in after.slots do
		local def = map[slot.id]
		if slot.done or def == nil or not def.enabled then
			continue
		end
		slot.progress = math.min(def.target, slot.progress + DailyChallengeLogic.countFor(def, tally))
		if slot.progress >= def.target then
			slot.done = true
			table.insert(payout.completed, def.id)
			payout.coins += def.coins
			payout.xp += def.xp
		end
	end

	if not after.allDonePaid and #after.slots > 0 then
		local all = true
		for _, slot in after.slots do
			if not slot.done then
				all = false
				break
			end
		end
		if all then
			after.allDonePaid = true
			payout.allDone = true
			payout.coins += config.allDoneCoins
			payout.xp += config.allDoneXp
		end
	end

	return after, payout
end

return DailyChallengeLogic
