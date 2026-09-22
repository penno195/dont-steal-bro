--!strict
-- The NPC brain's decisions, as arithmetic (P3-6): the utility score
-- that decides whether to use a held power-up now, and the Decision
-- Studio behaviour - which personality a bot draws, whether it steals,
-- when it locks in, and which line it says when.
-- NPCBrain.luau is the Roblox-touching wrapper that supplies real
-- positions, real inventories and a real clock and acts on the results.
--
-- Same split, and the same reason, as NPCLogic.luau's own header:
-- behaviour that can be argued about should be checkable by a test.
-- "A Greedy bot steals roughly 70% of the time" and "a bot never locks
-- in after the Choose deadline" are both claims this file makes and
-- tests/NPCBrainLogic.spec.luau checks directly.
--
-- WHAT THIS FILE DELIBERATELY CANNOT DO: use a power-up, post a
-- message, or record a choice. It returns decisions; NPCBrain routes
-- every one of them through the same validated server path a human's
-- input takes (PowerUpService.useForRacer, DecisionService.
-- submitChoiceFor). That separation is what makes "never a shortcut"
-- (P3-6's own requirement) structurally true rather than a promise.

local NPCBrainLogic = {}

-- ===== power-up use: the utility score ======================================

export type UtilityWeights = {
	baseScore: number,
	deficitWeight: number,
	proximityWeight: number,
	travelWeight: number,
	deficitSaturation: number,
	travelSaturationStuds: number,
	useThreshold: number,
}

export type Situation = {
	kind: "Buff" | "Debuff",
	onCooldown: boolean,
	-- How many tasks the leading racer has completed beyond this one.
	-- 0 when the bot IS the leader; never negative.
	progressDeficit: number,
	-- How far this bot still has to walk to its next station. nil when
	-- it has no station left (its route is done).
	distanceToNextStationStuds: number?,
	-- Distance to the nearest racer AHEAD of this bot on task count.
	-- nil when nobody is ahead, or nobody ahead has a measurable
	-- position right now.
	--
	-- DELIBERATELY NOT "nearest HUMAN ahead", which is how P3-6's brief
	-- phrases it. A bot that preferentially hunts humans is a bot that
	-- feels personally hostile, and it would quietly make a
	-- human-heavy lobby harder than an NPC-heavy one for reasons no
	-- player could see - the opposite of what threat-model.md §8 is
	-- trying to keep honest. In a 6-seat race the racers ahead are
	-- mostly human anyway, so the behaviour this produces is what the
	-- brief describes; what it avoids is the targeting RULE being
	-- species-aware. Flagged in docs/npc-notes.md as a knowing
	-- deviation.
	nearestAheadDistanceStuds: number?,
	-- The server's own max use range, so "close" is measured against
	-- the same number the validator will enforce.
	useRangeStuds: number,
}

local function clamp01(value: number): number
	return math.clamp(value, 0, 1)
end

-- Returns a score in roughly [0, 1+], comparable against
-- `weights.useThreshold`. A score of 0 means "cannot or should not be
-- used at all right now," and is returned rather than nil so a caller
-- can log or compare scores without special-casing.
--
-- The shape, in one sentence each:
--   * On cooldown -> 0. Not a low score, a hard zero: the server would
--     reject the use anyway, and a bot that "wants" something the
--     validator forbids is a bot that wastes its tick arguing.
--   * Debuff -> needs someone ahead, inside range. Scores higher the
--     closer they are (a target at the edge of the cone is one that
--     walks out of it while the effect is resolving) and the further
--     behind the bot is.
--   * Buff -> needs a walk worth buffing. Scores higher the longer the
--     remaining leg and the further behind the bot is. A self-buff with
--     nowhere left to walk scores 0 rather than being burned for
--     nothing.
function NPCBrainLogic.scoreAction(situation: Situation, weights: UtilityWeights): number
	if situation.onCooldown then
		return 0
	end

	local deficitComponent = weights.deficitWeight
		* clamp01(situation.progressDeficit / math.max(weights.deficitSaturation, 1e-6))

	if situation.kind == "Debuff" then
		local distance = situation.nearestAheadDistanceStuds
		if distance == nil or distance > situation.useRangeStuds then
			return 0
		end
		local proximity = 1 - clamp01(distance / math.max(situation.useRangeStuds, 1e-6))
		return weights.baseScore + deficitComponent + weights.proximityWeight * proximity
	end

	local travel = situation.distanceToNextStationStuds
	if travel == nil or travel <= 0 then
		return 0
	end
	local travelFactor = clamp01(travel / math.max(weights.travelSaturationStuds, 1e-6))
	return weights.baseScore + deficitComponent + weights.travelWeight * travelFactor
end

function NPCBrainLogic.shouldUse(score: number, weights: UtilityWeights): boolean
	return score >= weights.useThreshold
end

-- ===== Decision Studio: personality =========================================

export type PersonalityLines = {
	promises: { string },
	pressure: { string },
	accusations: { string },
	wobbles: { string },
}

export type Personality = {
	id: string,
	displayName: string,
	stealProbability: number,
	weight: number,
	lines: PersonalityLines,
}

-- Weighted draw, identical in shape to NPCLogic.pickSkillProfile - kept
-- as its own function rather than shared because the two lists are
-- different types and unifying them would mean a generic over a field
-- name, which is more indirection than either case is worth.
function NPCBrainLogic.pickPersonality(personalities: { Personality }, roll: number): Personality
	assert(#personalities > 0, "NPCBrainLogic.pickPersonality: no personalities configured")

	local total = 0
	for _, personality in personalities do
		total += personality.weight
	end
	assert(total > 0, "NPCBrainLogic.pickPersonality: personality weights sum to zero")

	local target = math.clamp(roll, 0, 0.999999) * total
	local cumulative = 0
	for _, personality in personalities do
		cumulative += personality.weight
		if target < cumulative then
			return personality
		end
	end
	return personalities[#personalities]
end

-- The hidden choice. `roll < stealProbability` and nothing else - the
-- bot's own chat lines have no input into it, which is the entire point
-- of the mechanic: what it said and what it does are independent, so a
-- human reading the lines is reading a bluff, not a tell.
function NPCBrainLogic.rollChoice(personality: Personality, roll: number): "Steal" | "Share"
	return if roll < personality.stealProbability then "Steal" else "Share"
end

-- ===== Decision Studio: timing ==============================================

-- Where inside the Choose window this bot commits, in seconds from the
-- phase starting. Always strictly inside [earliest, latest] fractions of
-- the window, and `latest` is validated below 1, so the returned offset
-- can never land on or after the deadline - a lock-in racing the phase
-- timer would be a coin flip between the bot's own choice and the
-- configured default.
function NPCBrainLogic.lockInOffsetSeconds(
	windowSeconds: number,
	roll: number,
	earliestFraction: number,
	latestFraction: number
): number
	local earliest = math.clamp(earliestFraction, 0, 1)
	local latest = math.clamp(latestFraction, earliest, 1)
	local fraction = earliest + math.clamp(roll, 0, 0.999999) * (latest - earliest)
	return math.max(windowSeconds, 0) * fraction
end

-- When each negotiation line goes out, in seconds from Negotiate
-- starting. Spread evenly across the window with a per-slot jitter, then
-- forced at least `minGapSeconds` apart, so a bot reads as someone
-- typing at a human pace rather than pasting a script.
--
-- The count is reduced (not the gap) when the window is too short to
-- fit them all: a bot saying two things at a believable pace beats
-- three on top of each other.
function NPCBrainLogic.lineScheduleSeconds(
	windowSeconds: number,
	lineCount: number,
	minGapSeconds: number,
	nextRandom: () -> number
): { number }
	local schedule: { number } = {}
	if lineCount <= 0 or windowSeconds <= 0 then
		return schedule
	end

	-- Leave the last stretch of the window quiet: a line landing as the
	-- phase ends is one nobody gets to answer.
	local usable = windowSeconds * 0.85
	local slot = usable / lineCount

	local previous = -math.huge
	for index = 1, lineCount do
		local jitter = (nextRandom() - 0.5) * slot * 0.5
		local at = (index - 1) * slot + slot * 0.5 + jitter
		at = math.clamp(at, 0, usable)

		if at - previous < minGapSeconds then
			at = previous + minGapSeconds
		end
		if at > usable then
			break -- no room left at a believable pace; stop early
		end

		table.insert(schedule, at)
		previous = at
	end

	return schedule
end

-- ===== Decision Studio: what to say =========================================

export type LineCategory = "promises" | "pressure" | "accusations" | "wobbles"

-- The negotiation has a shape, and the bots follow it: open by claiming
-- to share, push in the middle, start pointing fingers as it tightens,
-- and waver right at the end. Picking by progress rather than at random
-- is most of what makes a bot read as participating in a conversation
-- rather than emitting strings.
--
-- `progress` is 0 at the start of Negotiate and 1 at its end.
function NPCBrainLogic.categoryForProgress(progress: number): LineCategory
	local clamped = clamp01(progress)
	if clamped < 0.34 then
		return "promises"
	elseif clamped < 0.62 then
		return "pressure"
	elseif clamped < 0.85 then
		return "accusations"
	end
	return "wobbles"
end

-- Picks a line from the category `progress` selects, avoiding anything
-- in `alreadySaid` where it can - a bot repeating itself inside one
-- 45-second window is the single most obvious tell that it isn't a
-- person. Falls back to the category's own pool when every line in it
-- has been used.
function NPCBrainLogic.selectLine(
	personality: Personality,
	progress: number,
	roll: number,
	alreadySaid: { [string]: boolean }
): string?
	local category = NPCBrainLogic.categoryForProgress(progress)
	local pool = (personality.lines :: any)[category] :: { string }?
	if pool == nil or #pool == 0 then
		return nil
	end

	local fresh: { string } = {}
	for _, line in pool do
		if not alreadySaid[line] then
			table.insert(fresh, line)
		end
	end

	local candidates = if #fresh > 0 then fresh else pool
	local index = math.floor(math.clamp(roll, 0, 0.999999) * #candidates) + 1
	return candidates[index]
end

return NPCBrainLogic
