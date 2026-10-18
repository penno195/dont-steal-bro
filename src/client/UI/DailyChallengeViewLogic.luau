--!strict
-- The pure half of the Hub's daily challenges panel (payoff-loop step
-- 8c; design-decisions.md Q1's "a payoff for every round" applied
-- case): reading DailyChallengeState and what the panel says. No Roblox
-- API, no requires; tested under Lune (tests/DailyChallengeViewLogic.spec).
--
-- The list is the player's own and names no streak, so the server sends
-- it everywhere; the panel is Hub-only because the reroll is
-- (DailyChallengeService refuses it on a match server).

local DailyChallengeViewLogic = {}

export type Slot = {
	id: string,
	label: string,
	progress: number,
	target: number,
	done: boolean,
	coins: number,
	xp: number,
}

export type State = {
	day: string,
	slots: { Slot },
	rerollsLeft: number,
	allDone: { coins: number, xp: number, paid: boolean },
	resetsIn: number, -- seconds to the UTC midnight, when it was sent
}

local function isCount(value: any): boolean
	return type(value) == "number" and value == value and value >= 0
end

local function parseSlot(value: any): Slot?
	if
		type(value) ~= "table"
		or type(value.id) ~= "string"
		or type(value.label) ~= "string"
		or not isCount(value.progress)
		or not isCount(value.target)
		or type(value.done) ~= "boolean"
		or not isCount(value.coins)
		or not isCount(value.xp)
	then
		return nil
	end
	return {
		id = value.id,
		label = value.label,
		progress = value.progress,
		target = value.target,
		done = value.done,
		coins = value.coins,
		xp = value.xp,
	}
end

-- A DailyChallengeState payload, checked for shape. One bad slot drops
-- the whole list: a reroll names its slot by index, so the rows must
-- line up with the server's.
function DailyChallengeViewLogic.parse(value: any): State?
	if
		type(value) ~= "table"
		or type(value.day) ~= "string"
		or type(value.slots) ~= "table"
		or not isCount(value.rerollsLeft)
		or type(value.allDone) ~= "table"
		or not isCount(value.allDone.coins)
		or not isCount(value.allDone.xp)
		or type(value.allDone.paid) ~= "boolean"
		or not isCount(value.resetsIn)
	then
		return nil
	end
	local slots: { Slot } = {}
	for _, raw in value.slots do
		local slot = parseSlot(raw)
		if slot == nil then
			return nil
		end
		table.insert(slots, slot)
	end
	return {
		day = value.day,
		slots = slots,
		rerollsLeft = value.rerollsLeft,
		allDone = { coins = value.allDone.coins, xp = value.allDone.xp, paid = value.allDone.paid },
		resetsIn = value.resetsIn,
	}
end

DailyChallengeViewLogic.TITLE = "Daily challenges"
DailyChallengeViewLogic.BUTTON_LABEL = "Challenges"
DailyChallengeViewLogic.REROLL_LABEL = "Swap"

-- "+50 coins  +40 XP", either half dropped when it's zero.
function DailyChallengeViewLogic.rewardText(coins: number, xp: number): string
	local parts = {}
	if coins > 0 then
		table.insert(parts, string.format("+%d coins", coins))
	end
	if xp > 0 then
		table.insert(parts, string.format("+%d XP", xp))
	end
	return table.concat(parts, "  ")
end

-- The bar's right-hand text: "3/5", or "Done" once finished.
function DailyChallengeViewLogic.progressText(slot: Slot): string
	if slot.done then
		return "Done"
	end
	return string.format("%d/%d", math.min(slot.progress, slot.target), slot.target)
end

-- The level pill's caption in the Hub (Hub menu pass): how many of
-- today's challenges are done, "LEVEL · 1/2 TODAY". Plain "LEVEL"
-- without a list.
function DailyChallengeViewLogic.levelCaption(state: State?): string
	if state == nil or #state.slots == 0 then
		return "LEVEL"
	end
	local done = 0
	for _, slot in state.slots do
		if slot.done then
			done += 1
		end
	end
	return string.format("LEVEL · %d/%d TODAY", done, #state.slots)
end

-- Whether the row's Swap button works: a reroll left and the slot not
-- finished (the server's own AlreadyDone / NoRerolls checks).
function DailyChallengeViewLogic.canReroll(state: State, slot: Slot): boolean
	return state.rerollsLeft > 0 and not slot.done
end

-- The line under the rows: the all-done bonus, or that it's been paid.
function DailyChallengeViewLogic.bonusLine(state: State): string
	if state.allDone.paid then
		return "All done for today. Bonus paid!"
	end
	local reward = DailyChallengeViewLogic.rewardText(state.allDone.coins, state.allDone.xp)
	if reward == "" then
		return "Finish them all before the reset."
	end
	return "Finish all of them: " .. reward
end

function DailyChallengeViewLogic.rerollLine(state: State): string
	if state.rerollsLeft <= 0 then
		return "No swaps left today."
	elseif state.rerollsLeft == 1 then
		return "1 free swap left today."
	end
	return string.format("%d free swaps left today.", state.rerollsLeft)
end

-- Seconds left to the reset, `elapsed` seconds after the state arrived.
function DailyChallengeViewLogic.secondsLeft(state: State, elapsed: number): number
	return math.max(0, state.resetsIn - math.max(0, elapsed))
end

-- "New challenges in 5h 12m" / "in 12m" / "in under a minute".
function DailyChallengeViewLogic.resetText(seconds: number): string
	local minutes = math.floor(seconds / 60)
	if minutes < 1 then
		return "New challenges in under a minute"
	end
	local hours = math.floor(minutes / 60)
	if hours < 1 then
		return string.format("New challenges in %dm", minutes)
	end
	return string.format("New challenges in %dh %dm", hours, minutes % 60)
end

local REFUSALS: { [string]: string } = {
	NoRerolls = "No swaps left today.",
	AlreadyDone = "That one's already done.",
	NoCandidate = "Nothing left to swap in today.",
	NotHub = "Swaps are only in the lobby.",
}

-- A DailyChallengeRerollResult refusal, as a toast.
function DailyChallengeViewLogic.refusalText(reason: any): string
	return (if type(reason) == "string" then REFUSALS[reason] else nil) or "Couldn't swap that. Try again."
end

return DailyChallengeViewLogic
